#!/usr/bin/env bash
# Phase 1 — install the gateway egress firewall and create the gateway network.
# Run on the VM from the repo root:  sudo ./firewall/install.sh
# Safe to re-run; edit firewall/firewall.conf and re-run to change the allowlist.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing config, script and systemd unit"
install -d -m 0755 /etc/openclaw
install -m 0644 "$HERE/firewall.conf" /etc/openclaw/firewall.conf
install -m 0755 "$HERE/oc-firewall.sh" /usr/local/sbin/oc-firewall.sh
install -m 0644 "$HERE/openclaw-firewall.service" /etc/systemd/system/openclaw-firewall.service
systemctl daemon-reload
systemctl enable openclaw-firewall.service
systemctl restart openclaw-firewall.service

# shellcheck source=/dev/null
source /etc/openclaw/firewall.conf

echo "==> Creating Docker network ${OC_GW_NETWORK} (${OC_GW_SUBNET}, bridge ${OC_GW_BRIDGE})"
if docker network inspect "$OC_GW_NETWORK" >/dev/null 2>&1; then
  current="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$OC_GW_NETWORK")"
  [[ "$current" == "$OC_GW_SUBNET" ]] || { echo "${OC_GW_NETWORK} exists with subnet ${current}; remove it first."; exit 1; }
  echo "    already exists"
else
  docker network create --driver bridge --subnet "$OC_GW_SUBNET" \
    -o com.docker.network.bridge.name="$OC_GW_BRIDGE" "$OC_GW_NETWORK"
fi

echo
iptables -n -v -L OC-GW
echo
echo "Phase 1 installed. Run ./tests/phase1-check.sh to verify."
