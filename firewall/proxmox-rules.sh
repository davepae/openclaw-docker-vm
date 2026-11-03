#!/usr/bin/env bash
# Prints the Proxmox VM firewall file for this VM, built from site.env.
# Run on the VM:  ./firewall/proxmox-rules.sh
# Then paste the output on the Proxmox host as /etc/pve/firewall/<vmid>.fw
# (see firewall/proxmox-vm-rules.md for the steps and the lockout warnings).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f site.env ]] || { echo "site.env missing. Run ./configure.sh first."; exit 1; }
python3 scripts/site_settings.py proxmox-rules
