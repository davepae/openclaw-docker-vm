#!/usr/bin/env bash
# Phase 2 exit check. Run on the VM as ocadmin:  ./tests/phase2-check.sh
set -uo pipefail
cd "$(dirname "$0")/../compose" || exit 1

GW=openclaw-gateway
MODEL="qwen3.8-flash-next-iq2_xs"
pass=0; fail=0
ok()  { echo "PASS  $1"; ((pass++)); }
bad() { echo "FAIL  $1"; ((fail++)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
check_not() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi; }
gwnode() { docker exec "$GW" node -e "$1"; }
# OpenClaw CLI commands run inside the gateway container, which holds the state lock.

echo "-- exposure"
listeners="$(ss -Htln 'sport = :18789' | awk '{print $4}' | sort -u | tr '\n' ' ')"
if [[ "$listeners" == "127.0.0.1:18789 " ]]; then ok "18789 listens on 127.0.0.1 only"; else bad "18789 listeners: ${listeners:-none}"; fi
check "/healthz answers"  curl -fsS -m5 http://127.0.0.1:18789/healthz
check "/startupz answers" curl -fsS -m5 http://127.0.0.1:18789/startupz

echo "-- container"
check "runs as UID 1000 (not root)" test "$(docker exec "$GW" id -u)" = "1000"
check "Docker CLI reaches the daemon (for Phase 3 sandboxes)" docker exec "$GW" docker version --format '{{.Server.Version}}'
check_not "no internet from the gateway" gwnode "fetch('https://example.com',{signal:AbortSignal.timeout(6000)}).then(()=>process.exit(0),()=>process.exit(1))"
check "Strata serves ${MODEL} to the gateway" gwnode "fetch('http://llm.paelab.com:8080/v1/models',{headers:{Authorization:'Bearer '+process.env.STRATA_API_KEY},signal:AbortSignal.timeout(10000)}).then(r=>r.text()).then(t=>process.exit(t.includes('${MODEL}')?0:1),()=>process.exit(1))"

echo "-- policy"
check "config is read-only (write refused)" bash -c "docker exec $GW openclaw config set gateway.port 1 2>&1 | grep -qi 'external deployment source'"
check "default model is strata/${MODEL}" bash -c "docker exec $GW openclaw config get agents.defaults.model.primary 2>&1 | grep -q 'strata/${MODEL}'"
check "host exec mode is deny" bash -c "docker exec $GW openclaw config get tools.exec.mode 2>&1 | grep -q deny"
check "elevated is disabled"   bash -c "docker exec $GW openclaw config get tools.elevated.enabled 2>&1 | grep -q false"
check "approvals: security=deny, askFallback=deny" bash -c "docker exec $GW openclaw approvals get 2>&1 | grep -q 'security=deny, ask=always, askFallback=deny'"

echo
echo "${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
