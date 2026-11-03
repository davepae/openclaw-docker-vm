#!/usr/bin/env bash
# Phase 6 exit check: read-only gateway root, plugin allowlist, backups.
# Run on the VM as the admin user:  ./tests/phase6-check.sh
set -uo pipefail
cd "$(dirname "$0")/../compose" || exit 1

# Wait for a healthy gateway first: CLI checks fail while it is restarting.
for _ in $(seq 1 40); do
  [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' openclaw-gateway 2>/dev/null)" == healthy ]] && break
  sleep 3
done

GW=openclaw-gateway
pass=0; fail=0
ok()  { echo "PASS  $1"; ((pass++)); }
bad() { echo "FAIL  $1"; ((fail++)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

echo "-- read-only gateway root"
check "gateway root filesystem is read-only"   test "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' $GW)" = "true"
check "image files cannot be modified"         bash -c "! docker exec $GW touch /app/.rw-test 2>/dev/null"
check "state volume is writable"               docker exec $GW sh -c 'touch /srv/openclaw/state/.rw-test && rm /srv/openclaw/state/.rw-test'
check "gateway healthy"                        test "$(docker inspect -f '{{.State.Health.Status}}' $GW)" = "healthy"
started="$(docker inspect -f '{{.State.StartedAt}}' $GW)"
errs="$(docker logs --since "$started" $GW 2>&1 | grep -i -E 'EROFS|read-only file system' | head -3)"
if [[ -z "$errs" ]]; then ok "no read-only filesystem errors since start"; else bad "read-only filesystem errors in logs:"; echo "$errs" | sed 's/^/        /'; fi

echo "-- plugins"
# The gateway logs the plugins it actually loaded at startup. (`plugins list`
# shows the plugin registry, which marks bundled plugins enabled by default
# whether or not the gateway loads them.)
loaded="$(docker logs --since "$started" $GW 2>&1 | grep -o 'http server listening ([0-9]* plugins: [^;]*' | tail -1 | sed 's/.*plugins: //')"
if [[ "$loaded" == "device-pair, firecrawl, memory-core, searxng" ]]; then ok "gateway loaded only the 4 allowlisted plugins"; else bad "gateway loaded: ${loaded:-unknown}"; fi
check "plugins doctor passes"                   docker exec $GW openclaw plugins doctor

echo "-- backups"
check "backup timer enabled and active"        systemctl is-active --quiet openclaw-backup.timer
latest="$(ls -1t /srv/openclaw/backups/*-openclaw-backup.tar.gz 2>/dev/null | head -1)"
if [[ -n "$latest" ]] && [[ -n "$(find "$latest" -mmin -1560)" ]]; then ok "a backup from the last 26 hours exists"; else bad "no backup from the last 26 hours in /srv/openclaw/backups"; fi
check "latest backup archive is readable"      tar -tzf "${latest:-/nonexistent}"
check "backups are private (mode 600)"         test "$(stat -c %a "${latest:-/nonexistent}" 2>/dev/null)" = "600"

echo
echo "${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
