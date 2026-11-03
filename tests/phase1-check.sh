#!/usr/bin/env bash
# Phase 1 exit check: from a throwaway container on oc-gw, the allowlisted
# LAN services answer and everything else is unreachable.
# Run on the VM as ocadmin:  ./tests/phase1-check.sh
set -uo pipefail

NET="oc-gw"
IMG="curlimages/curl:latest"
pass=0; fail=0

probe() {  # prints the HTTP status, or 000 if no connection was made (-k: a cert error must not look like a block)
  docker run --rm --network "$NET" "$IMG" -k -s -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null || true
}
expect_open()    { local c; c="$(probe "$2")"; if [[ "$c" != "000" ]]; then echo "PASS  $1 reachable (HTTP $c)"; ((pass++)); else echo "FAIL  $1 not reachable: $2"; ((fail++)); fi; }
expect_blocked() { local c; c="$(probe "$2")"; if [[ "$c" == "000" ]]; then echo "PASS  $1 blocked"; ((pass++)); else echo "FAIL  $1 reachable (HTTP $c): $2"; ((fail++)); fi; }

docker pull -q "$IMG" >/dev/null

echo "-- allowed"
expect_open "Strata by name (DNS + path)" "http://llm.paelab.com:8080/"
expect_open "SearXNG"                     "http://172.16.3.100:8080/"
expect_open "Firecrawl"                   "http://172.16.3.100:3002/"
echo "-- blocked"
expect_blocked "Internet (example.com)"   "https://example.com/"
expect_blocked "Internet by IP (1.1.1.1)" "https://1.1.1.1/"
expect_blocked "pfSense web UI on LAN"    "https://172.16.1.2/"

echo "-- persistence"
if sudo iptables -C DOCKER-USER -i br-oc-gw -j OC-GW 2>/dev/null; then
  echo "PASS  DOCKER-USER jump present"; ((pass++))
else
  echo "FAIL  DOCKER-USER jump missing (is openclaw-firewall.service enabled?)"; ((fail++))
fi

echo
echo "${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
