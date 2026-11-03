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
| 2 | Gateway stack (`compose/`, `config/`) | ready |
| 3 | Sandbox image and policy (`sandbox/`, `config/`) | |
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
- Exec: sandbox only, host exec denied in config and in the approvals policy;
  elevated off. Sandboxing itself arrives in Phase 3, so until then the agent
  can chat but cannot run commands.

To change the config: edit `config/openclaw.json5`, commit, `git pull` on the
VM, then `cd compose && docker compose up -d --force-recreate openclaw-gateway`.

To upgrade OpenClaw: snapshot the VM, change `OPENCLAW_VERSION` in
`compose/.env`, re-run `./compose/install.sh`.

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
