#!/usr/bin/env bash
# Nightly OpenClaw backup. Uses `openclaw backup create`, which is safe while
# the gateway runs (never copy live .sqlite files). The archive covers state,
# config, credentials and the workspace; plugin packages are skipped as
# regenerable (sandbox/install.sh reinstalls them).
# Run by openclaw-backup.timer, or by hand:  sudo systemctl start openclaw-backup
set -euo pipefail
DEST=/srv/openclaw/backups
KEEP_DAYS="${KEEP_DAYS:-14}"

docker exec openclaw-gateway openclaw backup create --output "$DEST" --verify
find "$DEST" -maxdepth 1 -type f -name '*-openclaw-backup.tar.gz' -mtime +"$KEEP_DAYS" -print -delete
echo "Latest: $(ls -1t "$DEST"/*-openclaw-backup.tar.gz | head -1)"
