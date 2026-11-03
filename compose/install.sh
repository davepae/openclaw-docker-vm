#!/usr/bin/env bash
# Phase 2 — build and start the OpenClaw gateway container.
# Run on the VM as the admin user, from anywhere in the repo:  ./compose/install.sh
# Safe to re-run (it keeps the existing token in compose/.env). Site values
# (model server, web tools) come from site.env; see ./configure.sh.
set -Eeuo pipefail  # -E: the ERR trap also fires inside functions
cd "$(dirname "$0")"

[[ $EUID -ne 0 ]] || { echo "Run as your admin user, not with sudo."; exit 1; }
docker info >/dev/null 2>&1 || { echo "Can't reach Docker. Log out and back in after harden.sh."; exit 1; }
docker network inspect oc-gw >/dev/null 2>&1 || { echo "Network oc-gw missing. Run: sudo ./firewall/install.sh"; exit 1; }
[[ -f ../site.env ]] || { echo "site.env missing. Run ./configure.sh first."; exit 1; }
python3 ../scripts/site_settings.py check >/dev/null

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
setvar DOCKER_GID "$(stat -c %g /var/run/docker.sock)"
# Self-hosted Firecrawl ignores the key, but OpenClaw's Firecrawl tools require one.
[[ -n "$(getvar FIRECRAWL_API_KEY)" ]] || setvar FIRECRAWL_API_KEY "selfhosted"
# Before v0.4 the model server's key lived here; it is in site.env now.
if grep -q '^STRATA_API_KEY=' .env; then
  tmp="$(mktemp)"; grep -v '^STRATA_API_KEY=' .env > "$tmp" || true
  cat "$tmp" > .env && rm -f "$tmp"
  echo "    removed the old STRATA_API_KEY from compose/.env (now in site.env)"
fi

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

# Render the config from the template and site.env into a staging file first,
# so a bad setting stops here without touching the running gateway. The
# rendered file holds no secrets (they stay ${VAR} references) and is mode 600:
# OpenClaw's startup self-check otherwise tries to chmod it, which fails on the
# read-only mount.
GEN=../config/generated
log "Rendering the config from the template and site.env"
install -d -m 0700 "$GEN"
python3 ../scripts/site_settings.py render-config > "$GEN/.openclaw.json5.new"
chmod 600 "$GEN/.openclaw.json5.new" ../config/exec-approvals.json

# One-shot commands need the state lock, so a running gateway is stopped first
# (OpenClaw's recommended upgrade order: stop the old one, then start the new).
WAS_RUNNING=no
if [[ "$(docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null)" == "true" ]]; then
  WAS_RUNNING=yes
  log "Stopping the running gateway"
  docker compose stop openclaw-gateway
fi

# Keep the current rendered config. If anything below fails, put it back and,
# if the gateway was running, start it again so it is never left down. With no
# earlier rendered config (the first run of this layout) there is nothing to
# go back to: the failed config is moved aside and the rollback is explained.
rm -f "$GEN/.openclaw.json5.prev"
[[ -f "$GEN/openclaw.json5" ]] && cp -p "$GEN/openclaw.json5" "$GEN/.openclaw.json5.prev"
on_fail() {
  if [[ -f "$GEN/.openclaw.json5.prev" ]]; then
    echo "!! Failed; restoring the previous config"
    mv -f "$GEN/.openclaw.json5.prev" "$GEN/openclaw.json5"
    if [[ "$WAS_RUNNING" == yes ]]; then
      echo "!! Starting the previous gateway"; docker compose start openclaw-gateway || true
    fi
  else
    mv -f "$GEN/openclaw.json5" "$GEN/openclaw.json5.failed" 2>/dev/null || true
    echo "!! Failed, and there is no earlier rendered config to restore (kept as"
    echo "   config/generated/openclaw.json5.failed). The gateway is stopped. Fix the"
    echo "   setting and re-run, or roll back: a Proxmox snapshot, or for a v0.3"
    echo "   install: git checkout v0.3 && ./compose/install.sh"
  fi
}
trap on_fail ERR

mv -f "$GEN/.openclaw.json5.new" "$GEN/openclaw.json5"

log "Validating the rendered config"
oneshot config validate

log "Writing the exec approvals policy (host exec: deny)"
oneshot approvals set --stdin < ../config/exec-approvals.json >/dev/null

# Recreating sandboxes needs exclusive state ownership, so it runs here while
# the gateway is stopped. OpenClaw starts fresh ones (current image + config)
# on next use; the workspace is a host directory and is unaffected.
if [[ -n "$(docker ps -aq --filter 'name=^openclaw-sbx-')" ]]; then
  log "Recreating sandboxes so they pick up the current image and config"
  oneshot sandbox recreate --all --force
fi

trap - ERR
rm -f "$GEN/.openclaw.json5.prev" "$GEN/openclaw.json5.failed"
log "Starting the gateway"
docker compose up -d --force-recreate openclaw-gateway

printf '    waiting for health'
for _ in $(seq 1 40); do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' openclaw-gateway 2>/dev/null || true)"
  [[ "$status" == "healthy" ]] && break
  printf '.'; sleep 3
done
echo " ${status:-unknown}"
[[ "$status" == "healthy" ]] || { echo "Gateway not healthy. Check: docker compose logs openclaw-gateway"; exit 1; }

VM_ADDR="$(hostname -I | awk '{print $1}')"
cat <<EOF

OpenClaw gateway is running.

1. From your admin machine, open the tunnel (leave it running):
     ssh -N -L 18789:127.0.0.1:18789 ${USER}@${VM_ADDR}
2. Browse to http://127.0.0.1:18789/ and paste the gateway token, shown by:
     grep OPENCLAW_GATEWAY_TOKEN $(cd .. && pwd)/compose/.env
3. If the UI says "pairing required", approve the browser on the VM:
     docker exec -it openclaw-gateway openclaw devices list
     docker exec -it openclaw-gateway openclaw devices approve <requestId>
4. Then run the check for the phase you are on, e.g. ./tests/phase3-check.sh
EOF
