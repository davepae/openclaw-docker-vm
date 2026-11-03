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
| 1 | Network policy (`firewall/`) | ready |
| 2 | Gateway stack (`compose/`) | next |
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

## Reaching the Control UI (from Phase 2)

```bash
ssh -N -L 18789:127.0.0.1:18789 ocadmin@openclaw.paelab.com
# then open http://127.0.0.1:18789/
```
