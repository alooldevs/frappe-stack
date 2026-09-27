#!/usr/bin/env bash
# host-prep.sh — one-time host setup for frappe-stack (Ubuntu 24.04).
# Run once:  sudo bash ~/stack/bootstrap/host-prep.sh
# Idempotent: safe to re-run.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
TARGET_USER="${SUDO_USER:-}"   # the user who will run the stack
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ] ||
  { echo "run it with sudo from the user that will run the stack, not as root"; exit 1; }
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "==> 1/5 system updates + base tools"
apt-get update -y
apt-get -y -o Dpkg::Options::=--force-confold upgrade
apt-get install -y ca-certificates curl gnupg git jq

echo "==> 2/5 Docker Engine (official repo) + compose/buildx plugins"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Container logs rotate (small disk); containers survive a dockerd restart.
mkdir -p /etc/docker
want='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "live-restore": true
}'
if [ "$(cat /etc/docker/daemon.json 2>/dev/null)" != "$want" ]; then
  printf '%s\n' "$want" > /etc/docker/daemon.json
  systemctl restart docker
fi
systemctl enable --now docker
usermod -aG docker "$TARGET_USER"

echo "==> 3/5 4G swap + kernel settings (Redis wants overcommit)"
if ! swapon --show | grep -q '^/swapfile'; then
  [ -f /swapfile ] || fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
cat > /etc/sysctl.d/99-frappe-stack.conf <<'EOF'
vm.swappiness = 10
vm.overcommit_memory = 1
EOF
sysctl --system >/dev/null

echo "==> 4/5 SSH: keys only (01- sorts before 50-cloudimg-settings.conf; in sshd the first value wins)"
if [ -s "$TARGET_HOME/.ssh/authorized_keys" ]; then
  cat > /etc/ssh/sshd_config.d/01-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  sshd -t
  systemctl reload ssh || systemctl restart ssh
else
  echo "SKIPPED: $TARGET_USER has no ~/.ssh/authorized_keys, so password login stays on (turning it off would lock you out)."
  echo "         Put your key on the server first (keyup server ...), then re-run this script."
fi

echo "==> 5/5 readback"
docker --version
docker compose version
docker buildx version
swapon --show
sysctl vm.swappiness vm.overcommit_memory
sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '
id "$TARGET_USER"

echo "DONE — host prep complete."
if [ -f /var/run/reboot-required ]; then
  echo "REBOOT NEEDED (updated: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)) — run: sudo reboot"
else
  echo "Log out and back in so $TARGET_USER can use docker."
fi
