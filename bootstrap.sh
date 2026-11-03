#!/usr/bin/env bash
# One-command build of the OpenClaw VM from this repo.
#
#   git clone https://github.com/davepae/openclaw-docker-vm.git
#   cd openclaw-docker-vm && ./bootstrap.sh
#
# Runs as ocadmin (sudo is used where needed). Every step is idempotent, so it
# is also safe to re-run on a built VM. Resume from a step with --from N.
#
#   1  VM hardening + Docker Engine     vm/harden.sh
#   2  Network policy, Docker networks  firewall/install.sh
#   3  Gateway container                compose/install.sh
#   4  Sandbox image + web plugins      sandbox/install.sh
#   5  Sandbox egress proxy             sandbox/egress-install.sh
#   6  Nightly backups                  backup/install.sh
#   7  Checks                           tests/phase1..6
set -euo pipefail
cd "$(dirname "$0")"

FROM=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:?--from needs a step number}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
  esac
done

step() { printf '\n\033[1m######## Step %s: %s ########\033[0m\n' "$1" "$2"; }
want() { [[ "$1" -ge "$FROM" ]]; }

[[ $EUID -ne 0 ]] || { echo "Run as your admin user (ocadmin), not root."; exit 1; }
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || echo "Warning: built and tested on Ubuntu; this is ${PRETTY_NAME:-unknown}."
sudo -v   # ask for the sudo password once, up front

if want 1; then
  step 1 "VM hardening and Docker Engine"
  sudo ./vm/harden.sh
fi

# harden.sh adds this user to the docker group, but this shell predates it.
# Re-run the rest under the new group rather than requiring a fresh login.
if ! docker info >/dev/null 2>&1; then
  if id -nG | grep -qw docker || getent group docker | grep -qw "$USER"; then
    echo; echo "==> Continuing under the docker group (no re-login needed)"
    exec sg docker -c "$(printf '%q ' "$0" --from "$(( FROM > 2 ? FROM : 2 ))")"
  fi
  echo "Can't reach Docker and $USER is not in the docker group. Run step 1 first."; exit 1
fi

if want 2; then
  step 2 "Network policy and Docker networks"
  sudo ./firewall/install.sh
fi

if want 3; then
  step 3 "Gateway container"
  ./compose/install.sh
fi

if want 4; then
  step 4 "Sandbox image and web plugins (first build takes several minutes)"
  ./sandbox/install.sh
fi

if want 5; then
  step 5 "Sandbox egress proxy"
  ./sandbox/egress-install.sh
fi

if want 6; then
  step 6 "Nightly backups"
  sudo ./backup/install.sh
fi

if want 7; then
  step 7 "Checks"
  ./tests/phase1-check.sh
  ./tests/phase2-check.sh
  ./tests/phase3-check.sh
  ./tests/phase3b-check.sh
  ./tests/phase6-check.sh
fi

cat <<'EOF'

######## Build complete ########

Manual steps that live outside the VM:
  - Proxmox VM firewall: firewall/proxmox-vm-rules.md (first build only)
  - Proxmox snapshot of the finished VM, and a scheduled Proxmox backup job
    for it to storage off this host (see README, Phase 6)
  - From the MacBook: ssh -N -L 18789:127.0.0.1:18789 ocadmin@openclaw.paelab.com
    then open http://127.0.0.1:18789/ with the token from compose/.env
  - In a new chat, ask the agent to run a command; then re-run
    ./tests/phase3-check.sh and ./tests/phase3b-check.sh for the live-sandbox checks
EOF
