#!/usr/bin/env bash
# Applies the OpenClaw gateway egress allowlist in Docker's DOCKER-USER chain.
# Run by openclaw-firewall.service after every Docker start. Idempotent.
#
# Traffic leaving the gateway bridge goes through the OC-GW chain:
# allowlisted destinations RETURN (Docker's normal handling continues),
# everything else is logged (rate-limited) and dropped.
set -euo pipefail

CONF="${1:-/etc/openclaw/firewall.conf}"
# shellcheck source=/dev/null
source "$CONF"

if ! iptables -n -L DOCKER-USER >/dev/null 2>&1; then
  echo "DOCKER-USER chain not found. Is Docker running with its iptables backend?" >&2
  exit 1
fi

iptables -N OC-GW 2>/dev/null || true
iptables -F OC-GW

iptables -A OC-GW -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
for proto in udp tcp; do
  iptables -A OC-GW -d "$DNS_IP" -p "$proto" --dport 53 -j RETURN
done
for pair in $ALLOW_TCP; do
  iptables -A OC-GW -d "${pair%:*}" -p tcp --dport "${pair##*:}" -j RETURN
done
iptables -A OC-GW -m limit --limit 6/min -j LOG --log-prefix "OC-GW-DROP: "
iptables -A OC-GW -j DROP

# Jump from DOCKER-USER for anything coming in from the gateway bridge (once).
iptables -C DOCKER-USER -i "$OC_GW_BRIDGE" -j OC-GW 2>/dev/null \
  || iptables -I DOCKER-USER 1 -i "$OC_GW_BRIDGE" -j OC-GW

echo "OC-GW rules applied for ${OC_GW_BRIDGE} (${OC_GW_SUBNET})."

# --- Phase 3b: the egress proxy's outbound network ------------------------------
if [[ -n "${OC_EGRESS_BRIDGE:-}" ]]; then
  iptables -N OC-EGRESS 2>/dev/null || true
  iptables -F OC-EGRESS
  iptables -A OC-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  for proto in udp tcp; do
    iptables -A OC-EGRESS -d "$DNS_IP" -p "$proto" --dport 53 -j RETURN
  done
  for net in $PRIVATE_RANGES; do
    iptables -A OC-EGRESS -d "$net" -m limit --limit 6/min -j LOG --log-prefix "OC-EGRESS-DROP: "
    iptables -A OC-EGRESS -d "$net" -j DROP
  done
  iptables -A OC-EGRESS -p tcp -m multiport --dports 80,443 -j RETURN
  iptables -A OC-EGRESS -m limit --limit 6/min -j LOG --log-prefix "OC-EGRESS-DROP: "
  iptables -A OC-EGRESS -j DROP
  iptables -C DOCKER-USER -i "$OC_EGRESS_BRIDGE" -j OC-EGRESS 2>/dev/null \
    || iptables -I DOCKER-USER 1 -i "$OC_EGRESS_BRIDGE" -j OC-EGRESS
  echo "OC-EGRESS rules applied for ${OC_EGRESS_BRIDGE} (${OC_EGRESS_SUBNET})."
fi
