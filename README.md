# openclaw-docker-vm

Scripted build of a single-purpose Ubuntu VM on Proxmox that runs the OpenClaw
gateway in Docker, with every agent session in a Docker sandbox. Local-only for
the proof of concept: models from `llm.paelab.com`, web search and fetch from
`intelnuc6`, no direct internet from the OpenClaw stack.

The VM is the trust boundary: the gateway holds the Docker socket, so anything
that runs on the gateway is effectively root on the VM.

## Quick start

On a fresh Ubuntu Server VM, logged in as the admin user with your SSH key
installed (`ssh-copy-id`), run:

```bash
git clone https://github.com/davepae/openclaw-docker-vm.git
cd openclaw-docker-vm && ./bootstrap.sh
```

It runs phases 0 to 3b in order, prompts once for the sudo password and once
for the Strata API key, then runs the checks. Every step is idempotent, so it
is safe to re-run; `./bootstrap.sh --from N` resumes at a step. The Proxmox VM
firewall (`firewall/proxmox-vm-rules.md`) and snapshots are done by hand.

## Status

| Phase | What | Status |
| --- | --- | --- |
| 0 | VM base hardening and Docker Engine (`vm/harden.sh`) | done |
| 1 | Network policy (`firewall/`) | done |
| 2 | Gateway stack (`compose/`, `config/`) | done |
| 3 | Sandbox image, policy, web tools (`sandbox/`, `config/`) | done |
| 3b | Sandbox egress proxy (`compose/proxy/`) | done |
| 4 | Access via SSH tunnel | |
| 5 | Validation (`tests/validate.sh`) | |
| 6 | Hardening: read-only root, plugin allowlist, backups (`backup/`) | ready |

## Phase 0

```bash
git clone https://github.com/davepae/openclaw-docker-vm.git
cd openclaw-docker-vm
sudo ./vm/harden.sh
```

The script refuses to run if `~/.ssh/authorized_keys` is empty, because it turns
off password login. Before closing your session, confirm key login works from a
second terminal. Then log out and back in, enable the QEMU guest agent in
Proxmox, and take a snapshot named `base`.

## Phase 1

```bash
cd ~/openclaw-docker-vm && git pull
sudo ./firewall/install.sh      # DOCKER-USER allowlist + oc-gw network
./tests/phase1-check.sh         # must end "0 failed"
```

Then apply the Proxmox VM firewall in `firewall/proxmox-vm-rules.md`, run the
check again, and take a snapshot named `phase1`.

The allowlist lives in `firewall/firewall.conf`. To change it, edit that file
and re-run `install.sh`.

## Phase 2

```bash
cd ~/openclaw-docker-vm && git pull
./compose/install.sh            # asks for the Strata API key once
./tests/phase2-check.sh         # must end "0 failed"
```

`install.sh` creates `compose/.env` (mode 600, git-ignored) with a generated
gateway token, your Strata key and the Docker group ID. It pulls the release
named in `OPENCLAW_VERSION`, pins its digest in `OPENCLAW_IMAGE`, and builds a
local image that adds the Docker CLI (needed for Phase 3 sandboxes). It
validates `config/openclaw.json5`, writes the exec approvals policy, and
starts the gateway. Re-running it stops the gateway first, then restarts it.

Run OpenClaw CLI commands inside the gateway container, which holds the state
lock: `docker exec -it openclaw-gateway openclaw <command>`.

What Phase 2 runs:

- Gateway as UID 1000, all capabilities dropped, 4 GB / 2 CPU limit, on
  `oc-gw` (Strata, SearXNG, Firecrawl and DNS only).
- Config mounted read-only from the repo (`OPENCLAW_CONFIG_READONLY=1`).
- Model: `strata/qwen3.8-flash-next-iq2_xs`.
- Exec: sandbox only (`tools.exec.host: sandbox`); gateway exec denied by the
  approvals policy; elevated off.

To change the config: edit `config/openclaw.json5`, commit, `git pull` on the
VM, then `cd compose && docker compose up -d --force-recreate openclaw-gateway`.

To upgrade OpenClaw: snapshot the VM, change `OPENCLAW_VERSION` in
`compose/.env`, re-run `./compose/install.sh`.

## Phase 3

```bash
cd ~/openclaw-docker-vm && git pull
./sandbox/install.sh            # builds the sandbox image (several minutes), installs web plugins, restarts
./tests/phase3-check.sh         # static checks
# ask the agent in the Control UI to run:  python3 --version && go version && pwd
./tests/phase3-check.sh         # now also inspects the live sandbox
```

Every session runs its tools in `openclaw-sandbox-local:1`: one container per
agent, no network, read-only root, UID 1000, all capabilities dropped, 6 GB /
2 CPUs, with `/srv/openclaw/workspace` mounted read-write at `/workspace`.

Baked into the image (there is no network to install anything later):
Python 3.13 with PDF libraries (pypdf, pdfplumber, PyMuPDF, pikepdf,
reportlab) and common ones (numpy, pandas, scipy, matplotlib, openpyxl,
python-docx, python-pptx, requests, bs4, lxml, pydantic, pytest, ruff, ...;
full list in `sandbox/requirements.txt`), Go 1.24, Rust 1.85, Node 24 with
pnpm, gcc, git, ripgrep, jq, poppler-utils and qpdf. Caches live in
`/workspace/.cache`.

Web tools: `web_search` through SearXNG and `web_fetch` through Firecrawl, both
on intelnuc6. Their plugins are installed into `/srv/openclaw/state` by a
one-shot container with internet access, because the gateway has none.

To add a tool: edit `sandbox/Dockerfile` or `sandbox/requirements.txt`, bump
the image tag in both `sandbox/install.sh` and `config/openclaw.json5`
(`openclaw-sandbox-local:2`), commit, pull, and re-run `./sandbox/install.sh`.

**Do not set `tools.exec.mode`.** In 2026.10.10, `mode: "deny"` also blocks
exec inside the sandbox. Gateway exec is blocked by the approvals policy.

## Phase 3b

```bash
cd ~/openclaw-docker-vm && git pull
./sandbox/egress-install.sh     # firewall + networks (sudo), proxy, gateway restart
# in a NEW chat, ask the agent to run:  pip download --no-deps -d /tmp/t six && ls /tmp/t
./tests/phase3b-check.sh
./tests/phase3-check.sh         # still passes; sandbox network is now oc-sbx
```

Sandboxes move from no network to `oc-sbx`, a Docker internal network whose
only other member is the Squid proxy (`oc-proxy`, 172.30.20.2:3128). Squid
allows HTTPS to the domains in `compose/proxy/allowlist.txt` and nothing else:
no plain HTTP, no private addresses, no TLS interception. Its outbound side,
`oc-egress`, is limited by the `OC-EGRESS` firewall chain to DNS plus 80/443 on
public addresses.

Default allowlist: PyPI, npm, the Go module proxy and crates.io. GitHub is
off: access to clone is also access to push, an easy way to send data out.

- **Change the allowlist:** edit `compose/proxy/allowlist.txt`, commit, pull,
  then `cd compose && docker compose restart oc-proxy`.
- **Watch decisions:** `docker logs -f oc-proxy` (`TCP_TUNNEL/200` allowed,
  `TCP_DENIED/403` denied).
- **Installing packages in the sandbox:** `/opt/venv` is read-only, so use a
  per-project venv in the workspace, e.g.
  `python3 -m venv --system-site-packages /workspace/proj/.venv`.
- **Cut sandboxes off again:** set `network: "none"` in `config/openclaw.json5`
  and re-run `./compose/install.sh`.

## Phase 6

```bash
cd ~/openclaw-docker-vm && git pull
./compose/install.sh            # read-only gateway root + plugin allowlist
sudo ./backup/install.sh        # nightly backups, plus one taken now
./tests/phase6-check.sh
```

- **Read-only gateway root.** Only `/srv/openclaw` (state, workspace, update
  captures, caches), the auth-secrets bind and tmpfs mounts (`/tmp`, and
  `.cache`, `.npm`, `.docker` under `/home/node`) are writable. If a future
  release writes somewhere new, the logs show `EROFS`; add a tmpfs for that
  path in `compose/docker-compose.yml`.
- **Plugin allowlist.** `plugins.allow` in `config/openclaw.json5` loads only
  `searxng`, `firecrawl`, `memory-core` and `device-pair` (Control UI
  pairing). Without it, 2026.10.10 enables about 40 bundled plugins,
  including browser control, computer use, file transfer and cloud model
  providers.
- **Backups.** `openclaw-backup.timer` runs `openclaw backup create --verify`
  nightly at about 03:15 into `/srv/openclaw/backups` (mode 600, 14 days
  kept). It is safe while the gateway runs; never copy live `.sqlite` files.
  Run one now with `sudo systemctl start openclaw-backup`.
- **Off-host copies.** Those archives live on the VM's own disk. In Proxmox,
  add a backup job for this VM (Datacenter → Backup → Add, mode Snapshot) to
  storage on another machine (a NAS or Proxmox Backup Server). `compose/.env`
  is not in the OpenClaw archive but is in the VM backup; its only secret you
  can't regenerate is the Strata key.

**Restore OpenClaw state** from an archive: `openclaw backup restore`
extracts into a fresh directory, never over live state.

```bash
docker exec openclaw-gateway openclaw backup restore \
  /srv/openclaw/backups/<archive>.tar.gz --target /srv/openclaw/restore-<date>
# inspect it, then with the gateway stopped (cd compose && docker compose stop
# openclaw-gateway), move the restored state and workspace into place and run
# ./compose/install.sh. For a full disaster, restore the Proxmox VM backup.
```

**Upgrading OpenClaw:**
1. Proxmox snapshot, then `sudo systemctl start openclaw-backup`.
2. Set the new `OPENCLAW_VERSION` in `compose/.env`.
3. `./compose/install.sh`, then `./sandbox/install.sh` (upgrades the plugins
   to the matching version).
4. `docker exec openclaw-gateway openclaw plugins doctor`. The Firecrawl plugin
   currently reports an `[info]` notice that it uses APIs retiring
   2026-10-01; if a release removes them, this is where it shows.
5. Run all the checks.

## Reaching the Control UI

From the MacBook:

```bash
ssh -N -L 18789:127.0.0.1:18789 ocadmin@openclaw.paelab.com
# then open http://127.0.0.1:18789/ and paste the token from compose/.env
```

If the UI says pairing is required, approve the browser on the VM:

```bash
docker exec -it openclaw-gateway openclaw devices list
docker exec -it openclaw-gateway openclaw devices approve <requestId>
```
