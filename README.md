# openclaw-docker-vm

A scripted, hardened build of an [OpenClaw](https://github.com/openclaw/openclaw)
agent on a single-purpose Ubuntu VM on Proxmox. The OpenClaw gateway runs in
Docker, every agent session runs its tools in a locked-down Docker sandbox, and
the whole stack uses local services only: models from a local inference server,
web search and page fetching from self-hosted SearXNG and Firecrawl.

One command builds the VM, and 72 automated checks verify it.

## Security model

The VM is the trust boundary. The gateway holds the host's Docker socket so it
can start sandbox containers, which makes anything running *on* the gateway
effectively root on the VM. Everything below is arranged around keeping
untrusted work off the gateway and keeping the VM from reaching anything it
does not need.

| Layer | What it enforces |
| --- | --- |
| Proxmox VM firewall | SSH in from the admin machine only. Out: the LAN services below, DNS, NTP, and HTTP/HTTPS to the internet for host updates. Rest of the LAN and DMZ blocked. |
| Gateway container | UID 1000, all capabilities dropped, read-only root, 4 GB / 2 CPU limit. Published on `127.0.0.1:18789` only; reached through an SSH tunnel. |
| Gateway network (`oc-gw`) | `DOCKER-USER` allowlist: the model server, SearXNG, Firecrawl and LAN DNS. No internet. |
| OpenClaw policy | Config mounted read-only from this repo (the agent cannot change its own policy). Exec runs only in sandboxes; gateway exec denied by the approvals policy; elevated mode off. Only 4 plugins load. |
| Agent sandboxes | One container per agent: non-root, read-only root, no capabilities, no Docker socket, 6 GB / 2 CPU limit. The workspace is the only writable host path. |
| Sandbox network (`oc-sbx`) | Docker internal network; its only exit is a Squid proxy allowing HTTPS to an allowlist of package registries (PyPI, npm, Go modules, crates.io). No LAN, no TLS interception. |
| Proxy egress (`oc-egress`) | `OC-EGRESS` chain: DNS plus 80/443 to public addresses only. |
| Backups | Nightly verified `openclaw backup create` archives (mode 600, 14 days), plus a Proxmox backup job off the host. |

## Threat model and residual risks

**Bottom line:** this build is strong against classic container attacks
(breakout, privilege escalation, pivoting into the LAN) and weaker against
AI-native ones: instructions hidden in web content, data leaving through the
agent's own tools, and a poisoned workspace steering later sessions.

**Treat as root on the VM:** the gateway container (it holds the Docker
socket), the gateway token, and anyone who can SSH to the VM.

| Risk | How it would happen | What limits it | What remains |
| --- | --- | --- | --- |
| Gateway takeover | Hostile content (a web page, model output) triggers a bug in OpenClaw | Gateway exec denied, elevated off, read-only root, 4 plugins, no internet | Critical if it happens: the socket is VM root. Patch promptly. |
| Exfiltration via web tools | Injected instructions make the agent `web_fetch` a URL that carries data | Nothing technical; it is inherent to web access | Open by design |
| Exfiltration via package registries | `npm publish`, or a Go module path naming an attacker's host | Proxy allows only 4 registries, HTTPS only | Reduced, not closed: the proxy cannot see inside TLS |
| Workspace and session poisoning | The agent rewrites code, or its own instruction and identity files, which load into every session | The sandbox can write only the workspace; the OpenClaw config is read-only | Review agent-written code before running it elsewhere |
| Secrets in the workspace | Keys or tokens copied into `/srv/openclaw/workspace` | Nothing; the agent reads all of it | Never put secrets there |
| Sandbox escape | A kernel or container runtime exploit | Non-root, no capabilities, no-new-privileges, read-only root, patched host | Low likelihood, critical impact |
| Stolen gateway token | Read from the VM or its backups | Loopback only, SSH tunnel; `.env` and backups are mode 600 | The token is equivalent to VM root |
| Poisoned search or fetch results | intelnuc6 is compromised | The same limits as prompt injection | Treat web content as hostile |

The agent has all three ingredients of the classic AI data-leak pattern:
access to private data (the workspace), exposure to untrusted content (the
web), and a way to send data out (the web tools). That is deliberate; the
controls above limit the damage rather than remove the pattern.

Verified closed by the checks: direct internet and LAN access from the
sandbox and the gateway, DNS from the sandbox, the sandbox reaching the
gateway, and the proxy reaching the LAN or DMZ.

**Using it safely**

- Keep SSH keys, passwords and tokens out of the workspace.
- Review code the agent wrote before running it outside the sandbox.
- For sensitive work, cut sandbox egress (`network: "none"`) and remove
  `web_fetch` and `web_search` from `tools.sandbox.tools.alsoAllow`.
- Upgrade OpenClaw regularly. Pinning by digest means security fixes only
  arrive when you upgrade.
- If you suspect compromise, roll back to a Proxmox snapshot and rotate the
  gateway token and the model server's API key.

**Known gaps:** a Docker socket proxy was considered and rejected, because the
API calls needed to create sandboxes are the same ones that can start a
privileged container. Rootless Docker would genuinely shrink the socket risk,
but needs the network controls reworked. The egress proxy cannot see inside
HTTPS.

## What the agent gets

- **Model:** a local OpenAI-compatible server (here Strata serving
  `qwen3.8-flash-next-iq2_xs` on `llm.paelab.com`).
- **Web:** `web_search` through SearXNG and `web_fetch` through Firecrawl. Both
  run on the gateway, so the sandbox itself stays without internet.
- **Sandbox toolchains:** Python 3.13 with PDF libraries (pypdf, pdfplumber,
  PyMuPDF, pikepdf, reportlab) and common ones (numpy, pandas, scipy,
  matplotlib, openpyxl, python-docx, python-pptx, requests, bs4, lxml,
  pydantic, pytest, ruff, ...; see `sandbox/requirements.txt`), Go 1.24,
  Rust 1.85, Node 24 with pnpm, gcc, git, ripgrep, jq, poppler-utils, qpdf.
- **Packages at runtime:** `pip`, `npm`, `go` and `cargo` installs through the
  proxy allowlist. `/opt/venv` is read-only, so use a per-project venv:
  `python3 -m venv --system-site-packages /workspace/proj/.venv`.

## Requirements

- Proxmox VE host. Tested VM: Ubuntu Server LTS, q35 + OVMF (UEFI), 1 socket /
  4 cores (CPU type `host`), 16 GB RAM (ballooning minimum = 16 GB), 80 GB disk
  (VirtIO SCSI single, discard on), VirtIO NIC with the Proxmox firewall
  enabled. Install OpenSSH and import your SSH key; do not install the Docker
  snap.
- An admin account (here `ocadmin`) that is the first user, so it is UID 1000
  like the `node` user in the OpenClaw image.
- An OpenAI-compatible model server, and SearXNG and Firecrawl instances,
  reachable from the VM.

## Quick start

On the fresh VM, logged in as the admin user with your SSH key installed:

```bash
git clone https://github.com/davepae/openclaw-docker-vm.git
cd openclaw-docker-vm && ./bootstrap.sh
```

It prompts once for the sudo password and once for the model server's API key,
then runs every phase and all the checks. Every step is idempotent, so it is
safe to re-run on a built VM; `./bootstrap.sh --from N` resumes at a step.

| Step | What | Script |
| --- | --- | --- |
| 1 | Base hardening, Docker Engine | `vm/harden.sh` |
| 2 | Firewall rules and Docker networks | `firewall/install.sh` |
| 3 | Gateway container | `compose/install.sh` |
| 4 | Sandbox image, web plugins | `sandbox/install.sh` |
| 5 | Sandbox egress proxy | `sandbox/egress-install.sh` |
| 6 | Nightly backups | `backup/install.sh` |
| 7 | Checks | `tests/phase*-check.sh` |

Done by hand, outside the VM:

1. Proxmox VM firewall, from `firewall/proxmox-vm-rules.md` (first build only).
2. A Proxmox backup job for the VM to storage on another machine
   (Datacenter → Backup → Add, mode Snapshot).
3. A Proxmox snapshot of the finished VM.

## Adapting it to your network

The values specific to this lab live in four places:

| File | Holds |
| --- | --- |
| `firewall/firewall.conf` | IPs and ports the gateway may reach, LAN DNS, Docker subnets |
| `firewall/proxmox-vm-rules.md` | VM firewall rules: admin machine, LAN services |
| `config/openclaw.json5` | Model server URL and model, SearXNG and Firecrawl URLs, sandbox limits |
| `compose/.env` (created on the VM, git-ignored) | OpenClaw version and image digest, gateway token, API keys |

## Using it

From the admin machine, open a tunnel and browse to the Control UI:

```bash
ssh -N -L 18789:127.0.0.1:18789 ocadmin@openclaw.paelab.com
# then open http://127.0.0.1:18789/ and paste the token:
#   grep OPENCLAW_GATEWAY_TOKEN ~/openclaw-docker-vm/compose/.env
```

If the UI asks for pairing, approve the browser on the VM:

```bash
docker exec -it openclaw-gateway openclaw devices list
docker exec -it openclaw-gateway openclaw devices approve <requestId>
```

Run OpenClaw CLI commands inside the gateway container, which holds the state
lock: `docker exec -it openclaw-gateway openclaw <command>`.

## Day-to-day changes

| Change | How |
| --- | --- |
| OpenClaw config | Edit `config/openclaw.json5`, commit, `git pull` on the VM, `./compose/install.sh` |
| Gateway LAN allowlist | Edit `firewall/firewall.conf`, `sudo ./firewall/install.sh` |
| Sandbox package allowlist | Edit `compose/proxy/allowlist.txt`, then `cd compose && docker compose restart oc-proxy` |
| Sandbox tools | Edit `sandbox/Dockerfile` or `sandbox/requirements.txt`, bump the image tag (`openclaw-sandbox-local:N`) in `sandbox/install.sh`, `config/openclaw.json5` and `tests/phase3-check.sh`, then `./sandbox/install.sh` |
| Cut sandboxes off the network | Set sandbox `network: "none"` in `config/openclaw.json5`, `./compose/install.sh` |
| Watch proxy decisions | `docker logs -f oc-proxy` (`TCP_TUNNEL/200` allowed, `TCP_DENIED/403` denied) |
| Back up now | `sudo systemctl start openclaw-backup` |

`compose/install.sh` stops the gateway, validates the config, writes the exec
approvals policy, recreates sandboxes so they pick up changes, and starts the
gateway again. If a step fails, it starts the previous gateway.

## Upgrading OpenClaw

1. Proxmox snapshot, then `sudo systemctl start openclaw-backup`.
2. Set the new `OPENCLAW_VERSION` in `compose/.env`.
3. `./compose/install.sh`, then `./sandbox/install.sh` (upgrades the plugins to
   the matching version).
4. `docker exec openclaw-gateway openclaw plugins doctor`. The Firecrawl plugin
   currently reports an `[info]` notice that it uses OpenClaw APIs retiring
   2026-10-01; if a release removes them, this is where it shows.
5. Run all the checks.

## Backups and restore

`openclaw-backup.timer` runs `openclaw backup create --verify` nightly at about
03:15 into `/srv/openclaw/backups`, keeping 14 days. It is safe while the
gateway runs; never copy live `.sqlite` files. The archives sit on the VM's own
disk, so pair them with the Proxmox backup job. `compose/.env` is in the VM
backup but not the OpenClaw archive; its only secret you cannot regenerate is
the model server's API key.

`openclaw backup restore` extracts into a fresh directory, never over live
state:

```bash
docker exec openclaw-gateway openclaw backup restore \
  /srv/openclaw/backups/<archive>.tar.gz --target /srv/openclaw/restore-<date>
# Inspect it. Then stop the gateway (cd compose && docker compose stop
# openclaw-gateway), move the restored state and workspace into place, and run
# ./compose/install.sh. For a full disaster, restore the Proxmox VM backup.
```

## Checks

| Script | Checks | Covers |
| --- | --- | --- |
| `tests/phase1-check.sh` | 7 | Gateway network reaches only its allowlist; firewall survives restarts |
| `tests/phase2-check.sh` | 12 | Exposure, container identity, read-only config, exec policy |
| `tests/phase3-check.sh` | 24 | Sandbox config, plugins, and the live sandbox's isolation, DNS and tools |
| `tests/phase3b-check.sh` | 18 | Proxy isolation and the allow/deny behavior seen from the sandbox |
| `tests/phase6-check.sh` | 11 | Read-only gateway root, loaded plugins, backups |

The live-sandbox sections need a running sandbox: ask the agent to run any
command in a new chat, then re-run the check.

## Things worth knowing

- **Do not set `tools.exec.mode`.** In 2026.10.10, `mode: "deny"` also blocks
  exec inside the sandbox. Gateway exec is blocked by the approvals policy.
- **The gateway image adds the Docker CLI.** The published OpenClaw image does
  not include it, and the gateway needs it to start sandboxes
  (`compose/Dockerfile.gateway`).
- **Paths are identical on host and gateway.** Sandboxes are created by the
  host's Docker daemon, so `/srv/openclaw` is mounted at the same path inside
  the gateway.
- **The config directory is mounted, not the file.** A `git pull` replaces the
  file, and a single-file mount would keep showing the old one.
- **`plugins list` is not what loads.** It shows the plugin registry. The
  gateway's startup line (`http server listening (4 plugins: ...)`) is the
  real set.
- **Sandbox `/tmp` is `noexec`.** Go's temporary build directory is therefore
  in the workspace (`GOTMPDIR`).

## Layout

```
bootstrap.sh            one-command build (steps 1-7)
vm/harden.sh            base hardening and Docker Engine
firewall/               DOCKER-USER chains, networks, Proxmox VM rules
compose/                gateway and proxy stack, .env template, gateway image
compose/proxy/          Squid config and package allowlist
config/                 OpenClaw config (read-only in the gateway), approvals policy
sandbox/                sandbox image, install scripts
backup/                 nightly backup script and systemd units
tests/                  check scripts, one per phase
```

## License

[MIT](LICENSE)
