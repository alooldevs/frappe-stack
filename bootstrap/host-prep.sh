#!/usr/bin/env bash
# host-prep.sh — one-time host setup for frappe-stack (Ubuntu 24.04).
#
#   sudo bash ~/stack/bootstrap/host-prep.sh docker    engine for bin/stack
#   sudo bash ~/stack/bootstrap/host-prep.sh native    engine for bin/native
#
# Both: system updates, 4G swap, sysctl, SSH keys-only. One mode per server (both want ports 80/443);
# the mode is recorded in /etc/frappe-stack-mode and a different one is refused. Idempotent: safe to re-run.
# Nothing here runs a downloaded script: packages come from signed apt repos (keys checked against their
# fingerprints) or from downloads checked against a pinned sha256.
set -euo pipefail

MODE="${1:-}"
case "$MODE" in docker | native) ;; *) sed -n '4,5p' "$0" | sed 's/^# *//'; exit 1 ;; esac
export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
TARGET_USER="${SUDO_USER:-}" # the user who will run the stack
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != root ] ||
  { echo "run it with sudo from the user that will run the stack, not as root"; exit 1; }
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
as_user() { sudo -u "$TARGET_USER" -H env "PATH=$TARGET_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }

# --- pins (native) ------------------------------------------------------------------------------
MARIADB_SERIES=11.8 # Frappe v16/develop CI tests 11.8 and warns above it
MARIADB_KEY_FPR=177F4010FE56CA3336300305F1656F24C74CD1D8
NODE_MAJOR=24
NODESOURCE_KEY_FPR=6F71F525282841EEDAF851B42F59B5F99B1BE0B4
UV_VERSION=0.11.33 # frappe-bench 5.31.0 declares uv~=0.11.6 and runs the uv on PATH
UV_SHA256=aa9fca823c03289fb6e3460b3dc864f3ea895cafaf9b99247701a67b17d1b018
WKHTMLTOX_VERSION=0.12.6.1-3 # no noble build exists; the jammy one is what works
WKHTMLTOX_SHA256=4f723b2691ad8638a9df960e0421d346d7315083e3583a334f33362280ddba15
BENCH_VERSION=5.31.0
PYTHON_VERSION=3.14

# --- one mode per server ------------------------------------------------------------------------
recorded="$(cat /etc/frappe-stack-mode 2>/dev/null || true)"
[ -z "$recorded" ] || [ "$recorded" = "$MODE" ] ||
  { echo "this server is set up for '$recorded'; refusing '$MODE' (both need ports 80/443)"; exit 1; }
p80="$(ss -Hltnp 'sport = :80' 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2 || true)"
case "$MODE:$p80" in
  docker:nginx | native:docker-proxy) echo "port 80 is held by $p80; refusing '$MODE' on the same server"; exit 1 ;;
esac

apt_get() { # waits out Ubuntu's own apt runs (unattended-upgrades starts in a new VM's first hour) instead of failing on the lock
  local i
  for i in $(seq 120); do
    fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1 || break
    [ "$i" = 1 ] && echo "waiting for another apt run to finish (unattended-upgrades?)…"
    sleep 5
  done
  command apt-get -o DPkg::Lock::Timeout=600 "$@"
}
apt_key() { # apt_key <name> <url> <fingerprint> — fetch a repo key and check it before trusting it
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$2" -o "$tmp"
  gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr/{print $10}' | grep -qx "$3" ||
    { echo "key for $1 does not match fingerprint $3"; rm -f "$tmp"; exit 1; }
  gpg --dearmor < "$tmp" > "/etc/apt/keyrings/$1.gpg.tmp"; mv "/etc/apt/keyrings/$1.gpg.tmp" "/etc/apt/keyrings/$1.gpg"
  chmod a+r "/etc/apt/keyrings/$1.gpg"; rm -f "$tmp"
}
fetch_checked() { # fetch_checked <url> <sha256> <dest>
  curl -fsSL "$1" -o "$3"
  echo "$2  $3" | sha256sum -c --quiet - || { echo "checksum mismatch for $1"; rm -f "$3"; exit 1; }
}

# --- common ---------------------------------------------------------------------------------------
echo "==> system updates + base tools"
apt_get update -y
apt_get -y -o Dpkg::Options::=--force-confold upgrade
apt_get install -y ca-certificates curl gnupg git jq
install -m 0755 -d /etc/apt/keyrings

echo "==> 4G swap + kernel settings (Redis wants overcommit)"
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

echo "==> SSH: keys only (01- sorts before 50-cloudimg-settings.conf; in sshd the first value wins)"
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

# --- docker ---------------------------------------------------------------------------------------
docker_engine() {
  echo "==> Docker Engine (official repo) + compose/buildx plugins"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt_get update -y
  apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  # Container logs rotate (small disk); containers survive a dockerd restart.
  mkdir -p /etc/docker
  local want='{
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
}

# --- native ---------------------------------------------------------------------------------------
native_engine() {
  echo "==> build tools, nginx, supervisor, redis, certbot, PDF libraries"
  apt_get install -y build-essential pkg-config libmariadb-dev cron \
    nginx supervisor redis-server fail2ban certbot python3-certbot-nginx \
    xvfb libfontconfig1 fontconfig libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz0b

  echo "==> MariaDB $MARIADB_SERIES (MariaDB's repo; Ubuntu ships 10.11) + Node $NODE_MAJOR (NodeSource)"
  apt_key mariadb https://mariadb.org/mariadb_release_signing_key.pgp "$MARIADB_KEY_FPR"
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/mariadb.gpg] https://dlm.mariadb.com/repo/mariadb-server/$MARIADB_SERIES/repo/ubuntu noble main" \
    > /etc/apt/sources.list.d/mariadb.list
  # supervisor and sudo can't see an nvm-installed node; NodeSource puts it in /usr/bin
  apt_key nodesource https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key "$NODESOURCE_KEY_FPR"
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt_get update -y
  apt_get install -y mariadb-server mariadb-client nodejs
  command -v yarn >/dev/null || npm install -g yarn@1 >/dev/null

  local cnf=/etc/mysql/mariadb.conf.d/99-frappe.cnf want_cnf
  want_cnf='# Frappe: utf8mb4 everywhere (the same flags frappe_docker gives its MariaDB).
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-character-set-client-handshake
innodb_buffer_pool_size = 1G
[mysql]
default-character-set = utf8mb4'
  systemctl enable mariadb >/dev/null 2>&1
  if [ "$(cat "$cnf" 2>/dev/null)" != "$want_cnf" ]; then # restart only on change: live sites use it
    printf '%s\n' "$want_cnf" > "$cnf"
    systemctl restart mariadb
  fi

  echo "==> wkhtmltopdf $WKHTMLTOX_VERSION (patched Qt; Ubuntu's own package is the unpatched one)"
  if ! wkhtmltopdf --version 2>/dev/null | grep -q 'with patched qt'; then
    fetch_checked "https://github.com/wkhtmltopdf/packaging/releases/download/$WKHTMLTOX_VERSION/wkhtmltox_$WKHTMLTOX_VERSION.jammy_amd64.deb" \
      "$WKHTMLTOX_SHA256" /tmp/wkhtmltox.deb
    apt_get install -y /tmp/wkhtmltox.deb
    rm -f /tmp/wkhtmltox.deb
  fi

  echo "==> uv $UV_VERSION → /usr/local/bin"
  if [ "$(uv --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]; then
    fetch_checked "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-x86_64-unknown-linux-gnu.tar.gz" \
      "$UV_SHA256" /tmp/uv.tar.gz
    tar -xzf /tmp/uv.tar.gz -C /tmp
    install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/
    rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-gnu
  fi

  echo "==> Python $PYTHON_VERSION + frappe-bench $BENCH_VERSION for $TARGET_USER"
  as_user uv python install "$PYTHON_VERSION" >/dev/null
  if [ "$(as_user bench --version 2>/dev/null)" != "$BENCH_VERSION" ]; then
    as_user uv tool install --force --python "$PYTHON_VERSION" "frappe-bench==$BENCH_VERSION" >/dev/null
  fi
  grep -q '.local/bin' "$TARGET_HOME/.bashrc" 2>/dev/null ||
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$TARGET_HOME/.bashrc"

  echo "==> services: bench runs its own redis per bench; nginx catch-all; supervisor socket for $TARGET_USER"
  systemctl disable --now redis-server >/dev/null 2>&1 || true
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/conf.d/00-stack.conf <<'EOF'
# frappe-stack: long site names fit, and a Host no bench serves gets nothing (not the first bench's site).
server_names_hash_bucket_size 128;
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
EOF
  nginx -t
  systemctl enable nginx >/dev/null 2>&1
  systemctl reload nginx || systemctl restart nginx
  # Let the stack user drive supervisor (bench restart, native ps) without sudo.
  local sv=/etc/supervisor/supervisord.conf
  if ! grep -q "^chown=root:$TARGET_USER" "$sv"; then
    sed -i -E "s|^chmod=0700.*|chmod=0770|" "$sv"
    sed -i "/^chmod=0770/a chown=root:$TARGET_USER" "$sv"
    systemctl restart supervisor
  fi
  systemctl enable supervisor >/dev/null 2>&1

  install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 /srv/benches
}

"${MODE}_engine"
echo "$MODE" > /etc/frappe-stack-mode

echo "==> readback"
if [ "$MODE" = docker ]; then
  docker --version; docker compose version; docker buildx version
else
  echo "mariadb $(mariadb --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' | head -1)"
  echo "node $(node -v), yarn $(yarn -v), uv $(uv --version | awk '{print $2}')"
  echo "python $(as_user uv python find "$PYTHON_VERSION"), bench $(as_user bench --version 2>/dev/null)"
  echo "$(wkhtmltopdf --version 2>/dev/null)"
  echo "services: supervisor $(systemctl is-active supervisor), nginx $(systemctl is-active nginx), mariadb $(systemctl is-active mariadb)"
  as_user supervisorctl status >/dev/null 2>&1 && echo "supervisorctl works for $TARGET_USER" || echo "supervisorctl: $TARGET_USER can't reach the socket yet (log in again)"
fi
swapon --show
sysctl vm.swappiness vm.overcommit_memory
sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '
id "$TARGET_USER"

echo "DONE — host prep ($MODE) complete."
if [ -f /var/run/reboot-required ]; then
  echo "REBOOT NEEDED (updated: $(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null)) — run: sudo reboot"
else
  echo "Log out and back in so $TARGET_USER picks up the new groups/PATH."
fi
