#!/usr/bin/env bash
# Phase 2 — build and start the OpenClaw gateway container.
# Run on the VM as ocadmin, from anywhere in the repo:  ./compose/install.sh
# Safe to re-run (it keeps the existing token and key in compose/.env).
set -euo pipefail
cd "$(dirname "$0")"

[[ $EUID -ne 0 ]] || { echo "Run as ocadmin, not with sudo."; exit 1; }
docker info >/dev/null 2>&1 || { echo "Can't reach Docker. Log out and back in after harden.sh."; exit 1; }
docker network inspect oc-gw >/dev/null 2>&1 || { echo "Network oc-gw missing. Run: sudo ./firewall/install.sh"; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

# --- Host directories (owned by UID 1000 = node in the image) -----------------
log "Checking /srv/openclaw"
for d in /srv/openclaw/state /srv/openclaw/workspace /srv/openclaw/auth-secrets; do
  [[ -d "$d" ]] || sudo install -d -m 0750 -o 1000 -g 1000 "$d"
done

# --- compose/.env --------------------------------------------------------------
# Values are written single-quoted so Compose never interpolates a '$' in a key.
getvar() { sed -n "s/^$1=//p" .env | tail -1 | sed "s/^'\(.*\)'$/\1/"; }
setvar() {
  local tmp; tmp="$(mktemp)"
  K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; line = k "='\''" v "'\''" }
    index($0, k "=") == 1 { print line; done = 1; next } { print }
    END { if (!done) print line }' .env > "$tmp"
  cat "$tmp" > .env && rm -f "$tmp"
}

if [[ ! -f .env ]]; then
  log "Creating compose/.env"
  install -m 0600 .env.example .env
fi
chmod 600 .env

[[ -n "$(getvar OPENCLAW_GATEWAY_TOKEN)" ]] || setvar OPENCLAW_GATEWAY_TOKEN "$(openssl rand -hex 32)"
if [[ -z "$(getvar STRATA_API_KEY)" ]]; then
  read -rsp "Strata API key (input hidden): " key; echo
  [[ -n "$key" && "$key" != *"'"* ]] || { echo "Empty key, or it contains a single quote."; exit 1; }
  setvar STRATA_API_KEY "$key"
fi
setvar DOCKER_GID "$(stat -c %g /var/run/docker.sock)"

# --- Pin the release by digest ---------------------------------------------------
VERSION="$(getvar OPENCLAW_VERSION)"
log "Pulling ghcr.io/openclaw/openclaw:${VERSION}"
docker pull -q "ghcr.io/openclaw/openclaw:${VERSION}"
DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "ghcr.io/openclaw/openclaw:${VERSION}" | grep '^ghcr.io/openclaw/openclaw@' | head -1)"
[[ -n "$DIGEST" ]] || { echo "Could not resolve a digest for ${VERSION}."; exit 1; }
setvar OPENCLAW_IMAGE "$DIGEST"
echo "    pinned ${DIGEST}"

# --- Build, validate, set approvals, start ---------------------------------------
log "Building the gateway image (official image + Docker CLI)"
docker compose build -q openclaw-gateway

oneshot() { docker compose run --rm --no-deps -T --entrypoint node openclaw-gateway dist/index.js "$@"; }

log "Validating config/openclaw.json5"
oneshot config validate

log "Writing the exec approvals policy (host exec: deny)"
oneshot approvals set --stdin < ../config/exec-approvals.json >/dev/null

log "Starting the gateway"
docker compose up -d openclaw-gateway

printf '    waiting for health'
for _ in $(seq 1 60); do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' openclaw-gateway 2>/dev/null || true)"
  [[ "$status" == "healthy" ]] && break
  printf '.'; sleep 3
done
echo " ${status:-unknown}"
[[ "$status" == "healthy" ]] || { echo "Gateway not healthy. Check: docker compose logs openclaw-gateway"; exit 1; }

cat <<'EOF'

Phase 2 gateway is running.

1. From the MacBook, open the tunnel (leave it running):
     ssh -N -L 18789:127.0.0.1:18789 ocadmin@openclaw.paelab.com
2. Browse to http://127.0.0.1:18789/ and paste the gateway token, shown by:
     grep OPENCLAW_GATEWAY_TOKEN ~/openclaw-docker-vm/compose/.env
3. If the UI says "pairing required", approve the browser on the VM:
     cd ~/openclaw-docker-vm/compose
     docker compose run --rm openclaw-cli devices list
     docker compose run --rm openclaw-cli devices approve <requestId>
4. Then run ./tests/phase2-check.sh
EOF
