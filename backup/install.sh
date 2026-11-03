#!/usr/bin/env bash
# Phase 6 — nightly OpenClaw backups to /srv/openclaw/backups (14 days kept).
# Run on the VM from the repo:  sudo ./backup/install.sh
# These backups live on the VM's own disk. Also schedule a Proxmox backup job
# for this VM to storage elsewhere (see README).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ADMIN_USER="${SUDO_USER:?run with sudo from the admin account}"

install -d -m 0700 -o 1000 -g 1000 /srv/openclaw/backups
install -m 0755 "$HERE/oc-backup.sh" /usr/local/sbin/oc-backup.sh
sed "s/__ADMIN_USER__/${ADMIN_USER}/" "$HERE/openclaw-backup.service" > /etc/systemd/system/openclaw-backup.service
install -m 0644 "$HERE/openclaw-backup.timer" /etc/systemd/system/openclaw-backup.timer
systemctl daemon-reload
systemctl enable --now openclaw-backup.timer

echo "==> Taking a first backup now"
systemctl start openclaw-backup.service
journalctl -u openclaw-backup.service -n 5 --no-pager -o cat
systemctl list-timers openclaw-backup.timer --no-pager | head -2
