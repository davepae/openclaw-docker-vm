# Porting this build

This repo is the build of one lab: a Proxmox VM, a Strata model server, and
SearXNG and Firecrawl on a LAN host. The values specific to that lab are
written into a few files. To run it somewhere else, change those files before
`./bootstrap.sh`. This guide lists every one of them.

The security design does not change: the gateway's `DOCKER-USER` allowlist,
the sandbox's proxy-only network and the read-only OpenClaw config all work on
any Ubuntu host with Docker Engine. What changes is where the services are and
what forms the outer firewall.

## 1. Your own model server

Any server with an OpenAI-compatible API works: Strata, Ollama, LM Studio,
vLLM, llama.cpp and the like. You need three things from it: the **base URL**
(usually ending in `/v1`), the **model id** exactly as `GET <base URL>/models`
lists it, and the **API key**.

The provider is called `strata` and its key `STRATA_API_KEY` throughout.
These are only labels: keep them, and you only change values. If you rename
them, rename them everywhere in the table below.

### Files to change

| File | Line(s) | Change |
| --- | --- | --- |
| `config/openclaw.json5` | `models.providers.strata` | `baseUrl`; the model's `id` and `name`; `input` (`["text"]` if the model doesn't take images); `contextWindow`; `maxTokens` |
| `config/openclaw.json5` | `agents.defaults.model.primary` | `"strata/<your model id>"` |
| `config/openclaw.json5` | `plugins.entries` | SearXNG `baseUrl`; Firecrawl `baseUrl` (twice: `webSearch` and `webFetch`) |
| `config/openclaw.json5` | `tools.toolSearch` | Keep `false` with a context of 64k or more; set `true` below that (see below) |
| `firewall/firewall.conf` | `DNS_IP` | Your DNS server: one address |
| `firewall/firewall.conf` | `ALLOW_TCP` | `ip:port` of the model server, SearXNG and Firecrawl, space-separated |
| `firewall/proxmox-vm-rules.md` | rules | Admin machine, server addresses, DNS (or your platform's equivalent; see section 2) |
| `tests/phase1-check.sh` | `expect_open`, `expect_blocked` | Your three service URLs; the blocked LAN example (any LAN address with a web page that should be unreachable) |
| `tests/phase2-check.sh` | `MODEL=`, the model-list check | Your model id and model server URL |
| `tests/phase3-check.sh` | "LAN unreachable from sandbox" | Your model server's `ip:port` |
| `tests/phase3b-check.sh` | "proxy cannot reach ..." and "LAN ... denied by proxy" | Your model server's and web host's addresses |
| `bootstrap.sh`, `compose/install.sh` | closing message | Your admin user and VM address in the `ssh -N -L` line |

`compose/install.sh` asks for the API key on the first run and stores it in
`compose/.env` (mode 600, git-ignored). It refuses an empty key or one with a
single quote in it. If your server needs no key, enter any placeholder such as
`none`: OpenClaw sends no request to a provider without a key.

`ALLOW_TCP` takes IP addresses, not names. If a URL uses a host name, the
config keeps the name (the gateway resolves it through `DNS_IP`) and
`ALLOW_TCP` gets its address. Use names your DNS server answers: the VM's
`/etc/hosts` is not visible inside the gateway container.

Never use `localhost` or `127.0.0.1` for a server: inside the gateway
container that is the container itself. A model server on the VM itself is
not supported, because traffic to the host bypasses the gateway firewall.

### Context window and Tool Search

`contextWindow` must be the context size the server actually runs the model
with. These were measured with OpenClaw 2026.10.10:

| Setting | First request | Works with a context of |
| --- | --- | --- |
| `toolSearch: false` (all tool schemas in the prompt) | about 35k tokens | 64k (65536) or more; overflows at 32k |
| `toolSearch: true` (schemas fetched on demand) | about 15k tokens | 32k (32768) or more |

Subtract `maxTokens` too: the prompt and the reply have to fit together.
`toolSearch: false` worked better with the reference build's heavily
quantized model, which handled the extra search step poorly; use it whenever
the context allows. A context below 32k is too small for OpenClaw.

### Server notes

| Server | Base URL | API key | Before you start |
| --- | --- | --- | --- |
| Strata | `http://<host>:8080/v1` | the server's key | A server that splits its context across parallel slots gives each request only its share; set `contextWindow` to the per-slot size. |
| Ollama | `http://<host>:11434/v1` | `none` (ignored) | Ollama listens on 127.0.0.1 only: set `OLLAMA_HOST=0.0.0.0` on the server. Its default context is 4096: set `OLLAMA_CONTEXT_LENGTH=65536` (at least 32768) and use the same number for `contextWindow`. |
| LM Studio | `http://<host>:1234/v1` | `none`, or the token if you turned on authentication | Turn on serving on the local network in the Developer tab; load the model with a context length of at least 32768. Model ids look like `author/model`. |

The model must support tool calling.

### Firecrawl and SearXNG

OpenClaw accepts a plain `http://` Firecrawl URL only on a private address;
on a public address it must be `https://`. Self-hosted Firecrawl ignores the
API key, so `compose/install.sh` sets it to `selfhosted`.

### Check your edits

1. `sudo ./firewall/install.sh` and `./tests/phase1-check.sh`. This checks the
   allowlist before anything else is installed.
2. After `./compose/install.sh`:
   `docker exec openclaw-gateway openclaw config validate`, then
   `./tests/phase2-check.sh`.
3. Send one message in the Control UI and check the reply comes from your
   model.

## 2. Another hypervisor or bare metal

Only two things are Proxmox-specific:

- **The outer firewall** (`firewall/proxmox-vm-rules.md`). Recreate the same
  rules on your platform: ESXi with NSX, Hyper-V with port ACLs, a firewall
  in front of the VM, or the host's own firewall for bare metal. The rules, in
  order:

  | Dir | Action | Destination / source | Port |
  | --- | --- | --- | --- |
  | IN | Accept | your admin machine | tcp 22 |
  | IN | Drop | everything else | |
  | OUT | Accept | the model server | its port |
  | OUT | Accept | the SearXNG and Firecrawl host(s) | their ports |
  | OUT | Accept | your DNS server | udp/tcp 53 |
  | OUT | Accept | any | udp 123 (NTP) |
  | OUT | Drop | 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 | |
  | OUT | Accept | any | tcp 80, 443 |
  | OUT | Drop | everything else | |

  The accepts for your servers must come before the private-range drops.
  Without this layer the build still isolates the gateway and the sandboxes,
  but the VM itself can reach your whole LAN.
- **The QEMU guest agent.** `vm/harden.sh` installs `qemu-guest-agent`. It is
  harmless elsewhere; remove it from the `apt-get install` line in
  `vm/harden.sh` if you prefer. For VMware or Hyper-V, Ubuntu's
  `open-vm-tools` or `linux-cloud-tools-virtual` packages are the equivalents.

Everything else assumes only Ubuntu Server LTS (amd64) with:

- 4 cores, 16 GB RAM and 80 GB of disk, as tested
- the admin account as the first user, so it has UID 1000 like the `node` user
  in the OpenClaw image
- an SSH key installed, because `vm/harden.sh` turns off password login

## 3. Cloud (AWS, Azure, GCP)

> This section is reasoned from how the build works. It has not been tested
> on any cloud.

The VM-level design carries over: Docker Engine, the `DOCKER-USER` chains,
the sandbox proxy and the read-only config are all inside the VM. The
differences:

- **Outer firewall.** Proxmox's rules become security groups (AWS), a
  network security group (Azure) or VPC firewall rules (GCP). Use the table
  in section 2. Allow SSH only from your address, or use the provider's
  bastion or session service and allow no SSH from the internet at all.
- **DNS.** `DNS_IP` is the cloud's internal resolver, not a LAN server:

  | Cloud | Resolver |
  | --- | --- |
  | AWS | `169.254.169.253`, or the VPC base address plus two (for example `10.0.0.2`) |
  | Azure | `168.63.129.16` |
  | GCP | `169.254.169.254` |

  Check what the VM actually uses with `resolvectl status`. The gateway may
  only use `DNS_IP` on port 53, so the metadata service on the same address
  stays unreachable to it.
- **The metadata service.** The containers can't reach it: the gateway's
  allowlist and the proxy's private-range drops both block it. The VM itself
  can. On AWS, require IMDSv2 and set the hop limit to 1.
- **A hosted model endpoint.** If the model server is a public HTTPS
  endpoint rather than a VM on your network, `ALLOW_TCP` becomes a problem:
  it allows fixed IP addresses, and hosted endpoints usually sit behind
  addresses that change. A model server on a private address in the same
  network (a GPU VM running vLLM or Ollama, say) keeps the design as it is.
- **SearXNG and Firecrawl.** Run them on a private address in the same
  network, for the same reason; Firecrawl over plain `http://` also needs a
  private address (section 1).
- **Backups.** The nightly OpenClaw archives still land on the VM's disk.
  Use the cloud's disk snapshots or backup service in place of the Proxmox
  backup job, and the snapshot before upgrades.
- **Image.** Use the provider's Ubuntu Server LTS image. Its default user
  (`ubuntu` on AWS and GCP) is normally UID 1000; check with `id -u`.
