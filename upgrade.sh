#!/usr/bin/env bash
# Upgrade (or roll back) OpenClaw to another release.
# Run on the VM as the admin user, from the repo:
#
#   ./upgrade.sh                 show the running version and the published ones
#   ./upgrade.sh <version>       e.g. 2026.11.5; or: latest, stable (extended-stable)
#
# Steps: check that the image and both web plugins exist for <version>, take an
# OpenClaw backup, set OPENCLAW_VERSION in compose/.env, run ./compose/install.sh
# (pulls and pins the image, validates the config, restarts the gateway), run
# ./sandbox/install.sh (plugins at the matching version), show plugins doctor,
# and run all the checks. If an install step fails, it puts the previous version
# back the same way and says so.
#
# Options:
#   --yes          don't ask whether a Proxmox snapshot was taken
#   --skip-checks  don't run the tests/ checks at the end
#
# A newer release may migrate OpenClaw's state, which the previous release may
# not read. The automatic rollback covers the image, plugins and config; the
# Proxmox snapshot (or the backup this script takes) covers the state.
set -Eeuo pipefail
cd "$(dirname "$0")"

PLUGINS=(@openclaw/searxng-plugin @openclaw/firecrawl-plugin)  # as in sandbox/install.sh
REGISTRY=https://registry.npmjs.org

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log() { printf '\n==> %s\n' "$*"; }

WANT="" YES=no CHECKS=yes
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)         YES=yes; shift ;;
    --skip-checks) CHECKS=no; shift ;;
    -h|--help)     usage 0 ;;
    -*)            echo "Unknown option: $1"; usage 1 ;;
    *)             [[ -z "$WANT" ]] || { echo "Only one version, please."; exit 1; }; WANT="$1"; shift ;;
  esac
done

[[ $EUID -ne 0 ]] || { echo "Run as your admin user, not with sudo."; exit 1; }
[[ -f compose/.env ]] || { echo "compose/.env missing. Build the VM first (./bootstrap.sh)."; exit 1; }
docker info >/dev/null 2>&1 || { echo "Can't reach Docker."; exit 1; }

getvar() { sed -n "s/^$1=//p" compose/.env | tail -1 | sed "s/^'\(.*\)'$/\1/"; }
setvar() {  # same format as compose/install.sh: single-quoted
  local tmp; tmp="$(mktemp)"
  K="$1" V="$2" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; line = k "='\''" v "'\''" }
    index($0, k "=") == 1 { print line; done = 1; next } { print }
    END { if (!done) print line }' compose/.env > "$tmp"
  cat "$tmp" > compose/.env && rm -f "$tmp"
}

CUR="$(getvar OPENCLAW_VERSION)"
RUNNING="$(docker exec openclaw-gateway openclaw --version 2>/dev/null | grep -Eo '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1 || true)"
TAGS="$(curl -fsS -m 15 "$REGISTRY/-/package/openclaw/dist-tags" 2>/dev/null || true)"
tag() { python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$TAGS" "$1" 2>/dev/null || true; }
LATEST="$(tag latest)"; STABLE="$(tag extended-stable)"

echo "Configured:       ${CUR:-?}  (compose/.env)"
echo "Running:          ${RUNNING:-not running}"
if [[ -n "$TAGS" ]]; then
  echo "Latest:           ${LATEST:-?}"
  echo "Extended-stable:  ${STABLE:-?}"
else
  echo "Published:        (could not reach $REGISTRY)"
fi
if [[ -z "$WANT" ]]; then
  echo; echo "To upgrade: $0 <version>   (or: latest, stable)"; exit 0
fi

case "$WANT" in
  latest) NEW="$LATEST" ;;
  stable) NEW="$STABLE" ;;
  *)      NEW="$WANT" ;;
esac
[[ -n "$NEW" ]] || { echo "Could not look up '$WANT'; give the version number instead."; exit 1; }
[[ "$NEW" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || { echo "'$NEW' is not an OpenClaw version (like 2026.11.5)."; exit 1; }
if [[ "$NEW" == "$CUR" ]]; then
  echo; echo "Already configured for ${NEW}. To reinstall it, run ./compose/install.sh and ./sandbox/install.sh."; exit 0
fi
[[ "$NEW" != *-* ]] || echo "Note: ${NEW} is a pre-release."
DOWNGRADE=no
[[ "$(printf '%s\n%s\n' "$CUR" "$NEW" | sort -V | tail -1)" == "$CUR" ]] && DOWNGRADE=yes

# --- Pre-flight: everything the upgrade needs must exist before anything changes -
log "Checking that ${NEW} is published"
docker manifest inspect "ghcr.io/openclaw/openclaw:${NEW}" >/dev/null 2>&1 \
  || { echo "No image ghcr.io/openclaw/openclaw:${NEW}. Nothing was changed."; exit 1; }
echo "    image ghcr.io/openclaw/openclaw:${NEW}"
for pkg in "${PLUGINS[@]}"; do
  curl -fsS -m 15 -o /dev/null "$REGISTRY/${pkg/\//%2f}/${NEW}" \
    || { echo "No ${pkg}@${NEW} on npm. Nothing was changed."; exit 1; }
  echo "    ${pkg}@${NEW}"
done

echo
if [[ "$DOWNGRADE" == yes ]]; then
  echo "This goes BACK from ${CUR} to ${NEW}. If ${CUR} migrated OpenClaw's state,"
  echo "${NEW} may not read it; restoring the Proxmox snapshot is the safe way back."
fi
if [[ "$YES" != yes ]]; then
  read -rp "Proxmox snapshot of this VM taken, and ready to go from ${CUR} to ${NEW}? [y/N] " a
  [[ "$a" == [yY]* ]] || { echo "Nothing was changed."; exit 1; }
fi

# --- Backup --------------------------------------------------------------------
log "OpenClaw backup (sudo)"
if docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null | grep -qx true; then
  sudo systemctl start openclaw-backup
  echo "    newest in /srv/openclaw/backups: $(find /srv/openclaw/backups -maxdepth 1 -type f -printf '%T@ %f\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
else
  echo "    gateway not running; skipped (the Proxmox snapshot covers it)"
fi

# --- Upgrade, with the way back ready ---------------------------------------------
SAVED="$(mktemp)"; cp -p compose/.env "$SAVED"
rollback() {
  echo
  echo "!! The upgrade to ${NEW} failed. Going back to ${CUR}."
  cp -p "$SAVED" compose/.env
  if ./compose/install.sh && ./sandbox/install.sh; then
    echo "!! Back on ${CUR}. The output above shows why ${NEW} failed."
  else
    echo "!! Could not put ${CUR} back automatically. Restore the Proxmox snapshot."
  fi
  rm -f "$SAVED"; exit 1
}

log "Setting OPENCLAW_VERSION=${NEW} in compose/.env"
setvar OPENCLAW_VERSION "$NEW"

log "Gateway (compose/install.sh)"
./compose/install.sh || rollback
log "Plugins at ${NEW} (sandbox/install.sh)"
./sandbox/install.sh || rollback
rm -f "$SAVED"

log "Plugin health"
docker exec openclaw-gateway openclaw plugins doctor || true

FAILED=()
if [[ "$CHECKS" == yes ]]; then
  for t in phase1 phase2 phase3 phase3b phase6; do
    log "Check: ${t}"
    ./tests/${t}-check.sh || FAILED+=("$t")
  done
fi

echo
echo "######## OpenClaw ${CUR} -> ${NEW} done ########"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Checks with failures: ${FAILED[*]}. The gateway is running ${NEW}; look at the"
  echo "failures above, and roll back with: ./upgrade.sh ${CUR}  (or the Proxmox snapshot)"
  exit 1
fi
cat <<EOF
Start a new chat in the Control UI to try it. Once you're happy, free the disk
space the old release uses:
  docker image rm openclaw-gateway-local:${CUR} ghcr.io/openclaw/openclaw:${CUR}
EOF
