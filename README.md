# openclaw-docker-vm

Scripted build of a single-purpose Ubuntu VM on Proxmox that runs the OpenClaw
gateway in Docker, with every agent session in a Docker sandbox. Local-only for
the proof of concept: models from `llm.paelab.com`, web search and fetch from
`intelnuc6`, no direct internet from the OpenClaw stack.

The VM is the trust boundary: the gateway holds the Docker socket, so anything
that runs on the gateway is effectively root on the VM.

## Status

| Phase | What | Status |
| --- | --- | --- |
| 0 | VM base hardening and Docker Engine (`vm/harden.sh`) | done |
| 1 | Network policy (`firewall/`) | done |
| 2 | Gateway stack (`compose/`, `config/`) | done |
| 3 | Sandbox image, policy, web tools (`sandbox/`, `config/`) | ready |
| 3b | Sandbox egress proxy | after PoC |
| 4 | Access via SSH tunnel | |
| 5 | Validation (`tests/validate.sh`) | |
| 6 | Operate; read-only gateway root | |

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
