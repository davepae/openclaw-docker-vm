#!/usr/bin/env bash
# Phase 3b — give sandboxes HTTPS access to package registries through the
# Squid proxy, and nothing else. Run on the VM as the admin user:
#   ./sandbox/egress-install.sh
# Safe to re-run. To revert: set sandbox docker.network back to "none" in
# config/openclaw.template.json5, then re-run ./compose/install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
log() { printf '\n==> %s\n' "$*"; }
[[ $EUID -ne 0 ]] || { echo "Run as your admin user, not with sudo."; exit 1; }

log "Firewall: OC-EGRESS chain and the oc-sbx (internal) / oc-egress networks"
sudo ./firewall/install.sh

log "Building and starting the proxy"
(cd compose && docker compose up -d --build oc-proxy)
printf '    waiting for Squid'
for _ in $(seq 1 20); do
  docker exec oc-proxy bash -c '</dev/tcp/127.0.0.1/3128' 2>/dev/null && break
  printf '.'; sleep 1
done
docker exec oc-proxy bash -c '</dev/tcp/127.0.0.1/3128' 2>/dev/null \
  || { echo " not listening. Check: docker logs oc-proxy"; exit 1; }
echo " listening"

log "Restarting the gateway with sandboxes on oc-sbx"
./compose/install.sh


cat <<'MSG'

Phase 3b installed. Next:
  1. In a NEW chat, ask the agent to run:  pip download --no-deps -d /tmp/t six && ls /tmp/t
     That starts a sandbox on oc-sbx.
  2. ./tests/phase3b-check.sh
MSG
