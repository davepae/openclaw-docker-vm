#!/usr/bin/env bash
# Site settings: asks for your model server, web tools, DNS and admin machine,
# checks each answer, and saves them to site.env (git-ignored, mode 600).
# Re-run any time to change a value, then apply with:
#   ./compose/install.sh          (OpenClaw config)
#   sudo ./firewall/install.sh    (firewall allowlist)
# bootstrap.sh runs this automatically when site.env does not exist yet.
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -ne 0 ]] || { echo "Run as your admin user, not with sudo."; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required (it ships with Ubuntu Server)."; exit 1; }
exec python3 scripts/site_settings.py configure
