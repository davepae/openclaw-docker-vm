#!/usr/bin/env bash
# Phase 3 exit check. Run on the VM as ocadmin:  ./tests/phase3-check.sh
# Part 1 runs any time. Part 2 needs a live sandbox: ask the agent in the
# Control UI to run a command first, then run this again.
set -uo pipefail
cd "$(dirname "$0")/../compose" || exit 1

GW=openclaw-gateway
IMG="openclaw-sandbox-local:1"
pass=0; fail=0; skip=0
ok()  { echo "PASS  $1"; ((pass++)); }
bad() { echo "FAIL  $1"; ((fail++)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
oc() { docker exec "$GW" openclaw "$@" 2>&1; }   # CLI inside the gateway (state lock)

echo "-- configuration"
explain="$(oc sandbox explain)"
check "sandbox image ${IMG} exists"           docker image inspect "$IMG"
check "sandbox mode all, scope agent"         grep -q 'mode: all scope: agent' <<<"$explain"
check "workspace mounted rw at /workspace"    grep -q '/srv/openclaw/workspace -> /workspace rw' <<<"$explain"
check "web_search + web_fetch allowed for sandboxed sessions" grep -Eq "^  allow .*web_search, web_fetch" <<<"$explain"
check "elevated disabled"                     grep -q 'enabled: false' <<<"$(sed -n '/^Elevated:/,/^$/p' <<<"$explain")"
check "exec host is sandbox-only"             bash -c "docker exec $GW openclaw config get tools.exec.host 2>&1 | grep -qx sandbox"
check "gateway exec denied by approvals"      bash -c "docker exec $GW openclaw approvals get 2>&1 | grep -q 'security=deny, ask=always, askFallback=deny'"
plugins="$(oc plugins list)"
check "searxng plugin enabled"                grep -Eq 'searxng +│ openclaw +│ enabled' <<<"$plugins"
check "firecrawl plugin enabled"              grep -Eq 'firecrawl +│ openclaw +│ enabled' <<<"$plugins"

echo "-- live sandbox"
sbx="$(docker ps --filter "ancestor=${IMG}" --format '{{.Names}}' | head -1)"
if [[ -z "$sbx" ]]; then
  echo "SKIP  no running sandbox yet: ask the agent to run 'python3 --version' in the Control UI, then rerun"
  ((skip++))
else
  echo "      inspecting ${sbx}"
  insp() { docker inspect -f "$1" "$sbx"; }
  check "no network"                 test "$(insp '{{.HostConfig.NetworkMode}}')" = "none"
  check "read-only root filesystem"  test "$(insp '{{.HostConfig.ReadonlyRootfs}}')" = "true"
  check "runs as 1000:1000"          test "$(insp '{{.Config.User}}')" = "1000:1000"
  check "all capabilities dropped"   grep -qi all <<<"$(insp '{{.HostConfig.CapDrop}}')"
  check "not privileged"             test "$(insp '{{.HostConfig.Privileged}}')" = "false"
  check "Docker socket not mounted"  bash -c "! docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' $sbx | grep -q docker.sock"
  check "workspace is /srv/openclaw/workspace" bash -c "docker inspect -f '{{range .Mounts}}{{.Source}}={{.Destination}} {{end}}' $sbx | grep -q '/srv/openclaw/workspace=/workspace'"
  check "internet unreachable from sandbox"    bash -c "! docker exec $sbx sh -lc 'curl -s -m 4 https://example.com' >/dev/null 2>&1"
  check "LAN unreachable from sandbox"         bash -c "! docker exec $sbx sh -lc 'curl -s -m 4 http://172.16.1.67:8080/' >/dev/null 2>&1"
  check "Python PDF libs import"               docker exec "$sbx" sh -lc 'python3 -c "import pypdf, fitz, pdfplumber, reportlab"'
  check "Go, Rust and Node present"            docker exec "$sbx" sh -lc 'go version && cargo --version && node --version'
  check "workspace writable by the sandbox"    docker exec "$sbx" sh -lc 'touch /workspace/.phase3-write-test && rm /workspace/.phase3-write-test'
fi

echo
echo "${pass} passed, ${fail} failed, ${skip} skipped"
[[ $fail -eq 0 ]]
