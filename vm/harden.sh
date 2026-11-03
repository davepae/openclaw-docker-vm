#!/usr/bin/env bash
# Phase 0 — base hardening and Docker Engine for the OpenClaw VM.
# Run on the VM as the admin user:  sudo ./vm/harden.sh
# Safe to re-run.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }

# The admin user is whoever ran sudo. SSH is restricted to that account, so
# refuse to guess (a root shell would lock everyone else out).
ADMIN_USER="${SUDO_USER:-}"
[[ -n "$ADMIN_USER" && "$ADMIN_USER" != root ]] || { echo "Run from your admin account with sudo, not from a root shell."; exit 1; }
OC_ROOT="/srv/openclaw"
OC_UID=1000   # matches the 'node' user inside the OpenClaw image
OC_GID=1000

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!!  %s\n' "$*"; }

# --- Pre-flight -------------------------------------------------------------
log "Pre-flight checks"
AUTH="/home/${ADMIN_USER}/.ssh/authorized_keys"
if [[ ! -s "$AUTH" ]]; then
  echo "No SSH keys in ${AUTH}. Refusing to disable password login."
  echo "Add your public key first (from your admin machine: ssh-copy-id ${ADMIN_USER}@<this VM>),"
  echo "then re-run."
  exit 1
fi
if [[ "$(id -u "$ADMIN_USER")" != "$OC_UID" ]]; then
  warn "${ADMIN_USER} is UID $(id -u "$ADMIN_USER"), not ${OC_UID}. Files under ${OC_ROOT} will be owned by UID ${OC_UID} regardless."
fi
if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
  echo "The Docker snap is installed. Remove it first: sudo snap remove docker"
  exit 1
fi

# --- Base packages and automatic security updates ---------------------------
log "Updating packages"
export DEBIAN_FRONTEND=noninteractive
# Keep existing config files on upgrade instead of stopping to ask.
APT_KEEP_CONF=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt-get update
apt-get -y "${APT_KEEP_CONF[@]}" upgrade
apt-get -y "${APT_KEEP_CONF[@]}" install ca-certificates curl unattended-upgrades qemu-guest-agent

log "Enabling unattended security upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

log "Starting the QEMU guest agent"
systemctl start qemu-guest-agent || warn "Guest agent did not start; enable 'QEMU Guest Agent' in the Proxmox VM Options, then reboot."

# --- SSH: keys only ---------------------------------------------------------
# A 10- file sorts before Ubuntu's 50-cloud-init.conf, and sshd uses the first value it reads.
log "Hardening SSH (key-only login for ${ADMIN_USER})"
cat > /etc/ssh/sshd_config.d/10-openclaw-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
X11Forwarding no
AllowUsers ${ADMIN_USER}
# TCP forwarding stays enabled: the Control UI is reached through an SSH tunnel.
EOF
sshd -t
systemctl restart ssh

# --- Docker Engine from Docker's apt repository -----------------------------
log "Removing conflicting Docker packages, if any"
for p in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
  if dpkg -s "$p" >/dev/null 2>&1; then apt-get -y remove "$p"; fi
done

log "Adding Docker's apt repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update

log "Installing Docker Engine and Compose"
apt-get -y "${APT_KEEP_CONF[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Configuring the Docker daemon (log rotation, live restore)"
if [[ -f /etc/docker/daemon.json ]] && ! grep -q '"live-restore"' /etc/docker/daemon.json; then
  cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
fi
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
systemctl enable --now docker
systemctl restart docker

log "Adding ${ADMIN_USER} to the docker group"
usermod -aG docker "$ADMIN_USER"

# --- OpenClaw host paths ----------------------------------------------------
log "Creating ${OC_ROOT}"
install -d -m 0750 -o "$OC_UID" -g "$OC_GID" \
  "$OC_ROOT" "$OC_ROOT/workspace" "$OC_ROOT/state" "$OC_ROOT/config"

# --- Exit check --------------------------------------------------------------
log "Exit check: docker run hello-world"
docker run --rm hello-world | grep -q "Hello from Docker" && echo "Docker works."
docker --version
docker compose version

cat <<EOF

Phase 0 complete.
  1. Log out and back in so '${ADMIN_USER}' picks up the docker group.
  2. Open a NEW terminal and confirm SSH by key still works before closing this one.
  3. In Proxmox: VM > Options > QEMU Guest Agent = Enabled (if not already), then reboot.
  4. Take a Proxmox snapshot named 'base'.
EOF
