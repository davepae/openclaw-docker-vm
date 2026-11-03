#!/usr/bin/env bash
# Phase 3b exit check: sandboxes reach allowlisted registries through the
# proxy, and nothing else. Run on the VM as ocadmin:  ./tests/phase3b-check.sh
set -uo pipefail
cd "$(dirname "$0")/../compose" || exit 1

PROXY=oc-proxy
IMG="openclaw-sandbox-local:1"
pass=0; fail=0; skip=0
ok()  { echo "PASS  $1"; ((pass++)); }
bad() { echo "FAIL  $1"; ((fail++)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

echo "-- networks and firewall"
check "oc-sbx is an internal network"       test "$(docker network inspect -f '{{.Internal}}' oc-sbx 2>/dev/null)" = "true"
check "oc-egress exists"                    docker network inspect oc-egress
check "OC-EGRESS chain hooked into DOCKER-USER" sudo iptables -C DOCKER-USER -i br-oc-egress -j OC-EGRESS

echo "-- proxy"
check "proxy running"                       test "$(docker inspect -f '{{.State.Running}}' $PROXY 2>/dev/null)" = "true"
check "proxy runs as non-root"              test "$(docker exec $PROXY id -u)" != "0"
check "proxy has a read-only root"          test "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' $PROXY)" = "true"
check "proxy listens on 3128"               docker exec $PROXY bash -c '</dev/tcp/127.0.0.1/3128'
check "proxy cannot reach the LAN (Strata)" bash -c "! docker exec $PROXY timeout 4 bash -c '</dev/tcp/172.16.1.67/8080' 2>/dev/null"
check "proxy cannot reach the DMZ (intelnuc6)" bash -c "! docker exec $PROXY timeout 4 bash -c '</dev/tcp/172.16.3.100/8080' 2>/dev/null"

echo "-- live sandbox"
# OpenClaw names its sandbox containers openclaw-sbx-*; match by name, not image,
# so a container from an earlier build of the image is still found.
sbx="$(docker ps --filter "name=^openclaw-sbx-" --format '{{.Names}}' | head -1)"
if [[ -z "$sbx" ]]; then
  echo "SKIP  no running sandbox: ask the agent to run a command in a new chat, then rerun"
  ((skip++))
else
  echo "      inspecting ${sbx}"
  run() { docker exec "$sbx" sh -lc "$1"; }
  # curl prints the proxy's CONNECT status: 200 = tunnel allowed, 403 = denied.
  via_proxy() { run "curl -s -o /dev/null -m 15 -w '%{http_connect}' $1"; }
  check "sandbox is on oc-sbx"               test "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$sbx")" = "oc-sbx"
  check "pypi.org allowed via proxy"         test "$(via_proxy https://pypi.org/simple/six/)" = "200"
  check "registry.npmjs.org allowed via proxy" test "$(via_proxy https://registry.npmjs.org/)" = "200"
  check "example.com denied by proxy"        test "$(via_proxy https://example.com/)" = "403"
  check "api.github.com denied by proxy"     test "$(via_proxy https://api.github.com/)" = "403"
  check "LAN (Strata) denied by proxy"       test "$(via_proxy https://172.16.1.67/)" = "403"
  check "no direct internet (proxy bypassed)" bash -c "! docker exec -e HTTPS_PROXY= -e https_proxy= -e HTTP_PROXY= -e http_proxy= $sbx sh -lc 'curl -s -m 4 https://pypi.org/' >/dev/null 2>&1"
  check "pip can download a package"         run 'pip download --no-deps --no-cache-dir -q -d /tmp/pipcheck six && ls /tmp/pipcheck | grep -q six'
  check "npm can query the registry"         run 'npm view left-pad version'
fi

echo
echo "${pass} passed, ${fail} failed, ${skip} skipped"
[[ $fail -eq 0 ]]
