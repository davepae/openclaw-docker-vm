#!/usr/bin/env bash
# Phase 1 — install the gateway egress firewall and create the gateway network.
# Run on the VM from the repo root:  sudo ./firewall/install.sh
# Safe to re-run. The allowlist comes from site.env (./configure.sh); after
# changing a server address there, re-run this script.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
[[ -f "$REPO/site.env" ]] || { echo "site.env missing. Run ./configure.sh first."; exit 1; }

# Resolve the site's servers to ip:port pairs now; nothing is changed if this fails.
echo "==> Deriving the gateway allowlist from site.env"
SITE_VARS="$(python3 "$REPO/scripts/site_settings.py" firewall-vars)"
printf '%s\n' "$SITE_VARS" | sed 's/^/    /'

echo "==> Installing config, script and systemd unit"
install -d -m 0755 /etc/openclaw
{ cat "$HERE/firewall.conf"; echo; echo "# --- From site.env, written by firewall/install.sh ---"; printf '%s\n' "$SITE_VARS"; } \
  > /etc/openclaw/firewall.conf.new
chmod 0644 /etc/openclaw/firewall.conf.new
mv -f /etc/openclaw/firewall.conf.new /etc/openclaw/firewall.conf
install -m 0755 "$HERE/oc-firewall.sh" /usr/local/sbin/oc-firewall.sh
install -m 0644 "$HERE/openclaw-firewall.service" /etc/systemd/system/openclaw-firewall.service
systemctl daemon-reload
systemctl enable openclaw-firewall.service
systemctl restart openclaw-firewall.service

# shellcheck source=/dev/null
source /etc/openclaw/firewall.conf

# Create a bridge network with a fixed subnet and bridge name (idempotent).
make_net() {  # name subnet bridge [extra docker network create args...]
  local name="$1" subnet="$2" bridge="$3"; shift 3
  echo "==> Docker network ${name} (${subnet}, bridge ${bridge}${*:+, $*})"
  if docker network inspect "$name" >/dev/null 2>&1; then
    local current; current="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$name")"
    [[ "$current" == "$subnet" ]] || { echo "${name} exists with subnet ${current}; remove it first."; exit 1; }
    echo "    already exists"
  else
    docker network create --driver bridge --subnet "$subnet" \
      -o com.docker.network.bridge.name="$bridge" "$@" "$name"
  fi
}

make_net "$OC_GW_NETWORK" "$OC_GW_SUBNET" "$OC_GW_BRIDGE"
if [[ -n "${OC_SBX_NETWORK:-}" ]]; then
  make_net "$OC_SBX_NETWORK" "$OC_SBX_SUBNET" "$OC_SBX_BRIDGE" --internal
  make_net "$OC_EGRESS_NETWORK" "$OC_EGRESS_SUBNET" "$OC_EGRESS_BRIDGE"
fi

echo
iptables -n -v -L OC-GW
[[ -z "${OC_EGRESS_BRIDGE:-}" ]] || { echo; iptables -n -v -L OC-EGRESS; }
echo
echo "Phase 1 installed. Run ./tests/phase1-check.sh to verify."
