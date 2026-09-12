#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  VPS Init Script v4.1 (International Edition)
#  For freshly installed Ubuntu / Debian machines (systemd) only.
#  Keep another root SSH session open while running, just in case.
#
#  Usage:
#    SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." bash vps_init.sh
#  To keep distro-shipped users (e.g. "ubuntu") able to log in via SSH:
#    EXTRA_SSH_USERS="ubuntu" bash vps_init.sh
#  If this host cannot reach docker.io directly, configure a pull mirror:
#    REGISTRY_MIRRORS="https://mirror.example.com" bash vps_init.sh
#
#  Portainer is installed the official default way: you create the admin
#  account on the first web visit. Note: it must be done within ~5 minutes
#  of container start; if the window expires, run `docker restart portainer`
#  and reload the page.
# =============================================================================

# ==================== Configuration ====================
NEW_USER="${NEW_USER:-deploy}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SSH_PORT="${SSH_PORT:-22}"
EXTRA_SSH_USERS="${EXTRA_SSH_USERS:-}"               # extra existing users allowed to SSH, space-separated
PORTAINER_BIND="${PORTAINER_BIND:-127.0.0.1}"        # keep 127.0.0.1 (SSH tunnel access) unless you know better
UFW_ALLOW_PORTAINER_IP="${UFW_ALLOW_PORTAINER_IP:-}" # source allowlist when bound publicly (optional)
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
TIMEZONE="${TIMEZONE:-UTC}"                          # UTC is the conventional default for servers
ENABLE_IPV6="${ENABLE_IPV6:-true}"
ALLOW_NON_FRESH="${ALLOW_NON_FRESH:-0}"
REGISTRY_MIRRORS="${REGISTRY_MIRRORS:-}"             # Docker Hub mirrors, space-separated; usually unnecessary with direct internet access

# ==================== Helpers ====================
log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m" >&2; }  # stderr: helper output may be captured via command substitution, never poll stdout
err()  { echo -e "\033[1;31m[-] $*\033[0m" >&2; exit 1; }
trap 'echo -e "\033[1;31m[-] Script failed at line $LINENO — inspect the output above, then re-run.\033[0m" >&2' ERR

SSHD_BIN="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"

# Normalize: docker -p does not accept "localhost" as a host IP
[ "$PORTAINER_BIND" = "localhost" ] && PORTAINER_BIND="127.0.0.1"

# /run is tmpfs and is recreated on every boot; /run/sshd is created by the
# ssh.service RuntimeDirectory= directive or by openssh's tmpfiles.d entry,
# and systemd removes it when the service stops. sshd -t/-T fails hard with
# "Missing privilege separation directory" when it is absent.
# Hard-learned lesson: `apt-get upgrade` may upgrade openssh-server, which
# restarts/stops ssh and wipes the directory — so besides here, the SSH
# hardening section (which runs AFTER apt) must call this function again.
ensure_run_sshd() {
  mkdir -p /run/sshd
  chmod 0755 /run/sshd
}
ensure_run_sshd   # covers the `sshd -T` call in get_ssh_port below

# ==================== Prerequisites ====================
[ "$(id -u)" -eq 0 ] || err "Please run this script as root."
command -v systemctl &>/dev/null || err "systemd not detected; cannot continue."

source /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] \
  || err "Only Ubuntu/Debian are supported (detected: ${ID:-unknown})."

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # prevent needrestart interactive menus during upgrades

# ---- Fresh-machine detection ----
WARN_COUNT=0

if command -v docker &>/dev/null; then
  if [ "$ALLOW_NON_FRESH" != "1" ]; then
    err "Docker is already installed; this script would reinstall it and may affect existing containers. Set ALLOW_NON_FRESH=1 to force."
  else
    warn "Docker already installed (ALLOW_NON_FRESH=1 set, continuing)."
  fi
fi

# Distro cloud images ship a default user (ubuntu/debian); informational only
REGULAR_USERS="$(awk -F: '$3>=1000 && $3<65534 && $7 ~ /(bash|sh|zsh)$/ {printf "%s ", $1}' /etc/passwd || true)"
if [ -n "$REGULAR_USERS" ]; then
  warn "Detected existing regular users: ${REGULAR_USERS} (common on cloud images)"
fi

if ufw status 2>/dev/null | grep -q "Status: active"; then
  WARN_COUNT=$((WARN_COUNT + 1))
fi

if [ "$WARN_COUNT" -gt 0 ] && [ "$ALLOW_NON_FRESH" != "1" ]; then
  err "Detected ${WARN_COUNT} non-fresh-machine signal(s). Set ALLOW_NON_FRESH=1 to force."
fi

# ==================== SSH port detection (never modifies sshd; used for UFW/hints) ====================
get_ssh_port() {
  local out port
  if ! out="$("$SSHD_BIN" -T 2>&1)"; then
    warn "sshd -T failed: ${out} — falling back to port 22"
    echo "22"
    return 0
  fi
  port="$(awk '/^port /{print $2; exit}' <<<"$out")"
  if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -gt 0 ]; then
    echo "$port"
  else
    echo "22"
  fi
}
DETECTED_SSH_PORT="$(get_ssh_port)"
log "Detected sshd listening port: ${DETECTED_SSH_PORT}"

# ==================== System update & base packages ====================
log "Updating system and installing base packages..."
apt-get update -y
apt-get upgrade -y
# Base packages include git; apache2-utils was dropped (htpasswd no longer used)
apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban \
  unattended-upgrades openssl sudo wget vim git iptables

if [ -f /run/reboot-required ]; then
  warn "The system requests a reboot to finish updates. Verify SSH access first, then reboot."
fi

log "Setting timezone..."
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || warn "Failed to set timezone, skipping."

# ==================== User & SSH hardening ====================
LOGIN_USER="root"
SUDO_PASS_NOTE=""
ALLOW_SSH_USERS="root"

if [ -n "$SSH_PUBLIC_KEY" ]; then
  log "Creating/configuring user ${NEW_USER} and installing the SSH public key..."
  if ! id "$NEW_USER" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$NEW_USER"
    INIT_PASS="$(openssl rand -base64 24)"
    echo "$NEW_USER:$INIT_PASS" | chpasswd
    # Persisted on disk: sudo is passwordless below, but this password remains a
    # fallback for `su` and the provider's out-of-band console.
    echo "$INIT_PASS" > "/root/${NEW_USER}_initial_password.txt"
    chmod 600 "/root/${NEW_USER}_initial_password.txt"
    SUDO_PASS_NOTE="  ${NEW_USER} initial password: ${INIT_PASS}"
  else
    warn "User ${NEW_USER} already exists; skipping creation. Forgot the password? Run: passwd ${NEW_USER}"
  fi
  usermod -aG sudo "$NEW_USER" || true
  LOGIN_USER="$NEW_USER"
  ALLOW_SSH_USERS="root ${NEW_USER}"

  # Passwordless sudo (validated immediately; on failure the file is removed and
  # password-based sudo still works, so you are never locked out)
  cat > "/etc/sudoers.d/90-${NEW_USER}" <<EOF
 ${NEW_USER} ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 440 "/etc/sudoers.d/90-${NEW_USER}"
  if ! visudo -cf "/etc/sudoers.d/90-${NEW_USER}" &>/dev/null; then
    rm -f "/etc/sudoers.d/90-${NEW_USER}"
    err "sudoers syntax check failed; the file was removed. Password-based sudo still works — fix and re-run."
  fi

  # Idempotent: append the key instead of overwriting, preserving existing keys
  install -d -m 700 "/home/${NEW_USER}/.ssh"
  touch "/home/${NEW_USER}/.ssh/authorized_keys"
  grep -qxF "$SSH_PUBLIC_KEY" "/home/${NEW_USER}/.ssh/authorized_keys" 2>/dev/null \
    || echo "$SSH_PUBLIC_KEY" >> "/home/${NEW_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"
  chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"

  mkdir -p /root/.ssh
  touch /root/.ssh/authorized_keys
  grep -qxF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys 2>/dev/null \
    || echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys

  log "Hardening SSH (drop-in named 00- so it loads BEFORE cloud-init)..."
  mkdir -p /etc/ssh/sshd_config.d

  # Some images lack the Include directive in the main config; add it at the top
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config \
    || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

  # The apt upgrade above may have upgraded openssh-server; restarting/stopping
  # the ssh service wipes RuntimeDirectory=/run/sshd. Recreate it here or every
  # subsequent sshd check fails hard.
  ensure_run_sshd

  # Probe each directive individually so one unsupported option cannot invalidate
  # the whole drop-in (OpenSSH 8.2 lacks KbdInteractiveAuthentication; newer
  # releases may have dropped ChallengeResponseAuthentication)
  mapfile -t SSH_OPTS <<'OPTS'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
OPTS
  if "$SSHD_BIN" -t -o "ChallengeResponseAuthentication=no" 2>/dev/null; then
    SSH_OPTS+=("ChallengeResponseAuthentication no")
  fi
  if "$SSHD_BIN" -t -o "KbdInteractiveAuthentication=no" 2>/dev/null; then
    SSH_OPTS+=("KbdInteractiveAuthentication no")
  fi

  if [ -n "$EXTRA_SSH_USERS" ]; then
    ALLOW_SSH_USERS+=" ${EXTRA_SSH_USERS}"
  fi
  SSH_OPTS+=("AllowUsers ${ALLOW_SSH_USERS}")

  if [ -n "$REGULAR_USERS" ] && [ -z "$EXTRA_SSH_USERS" ]; then
    warn "AllowUsers will only contain root and ${NEW_USER}; these existing users will LOSE SSH access: ${REGULAR_USERS}"
    warn "To keep them: set EXTRA_SSH_USERS=\"<names space-separated>\" and re-run, or edit 00-hardening.conf and restart ssh"
  fi

  # CRITICAL: for most directives sshd uses the FIRST value encountered.
  # The 00- prefix makes this file sort first, ahead of e.g. 50-cloud-init.conf.
  # NEVER rename it to 99- or higher, or cloud-init will silently override it!
  {
    echo "# Generated by VPS Init Script v4.1."
    echo "# sshd honors the first value seen; the 00- prefix loads this before 50-cloud-init.conf."
    for opt in "${SSH_OPTS[@]}"; do
      echo "$opt"
    done
  } > /etc/ssh/sshd_config.d/00-hardening.conf
  chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf

  # On failure, surface sshd's real error; if it's the /run/sshd race again,
  # recreate the directory and retry once
  if ! SSHD_T_OUT="$("$SSHD_BIN" -t 2>&1)"; then
    ensure_run_sshd
    if ! SSHD_T_OUT="$("$SSHD_BIN" -t 2>&1)"; then
      err "sshd -t failed: ${SSHD_T_OUT:-unknown error}. Check /etc/ssh/sshd_config.d/00-hardening.conf and the main sshd config."
    fi
    log "First sshd -t attempt failed (directory race); recreated /run/sshd and the retry passed."
  fi

  if ! systemctl restart sshd 2>/dev/null && ! systemctl restart ssh 2>/dev/null; then
    err "Failed to restart SSH (UFW is not enabled yet, so this session is unaffected). Troubleshoot manually and re-run."
  fi

  # Effective-value audit: read sshd -T ONCE into a variable, then parse it.
  # Lesson: `pipeline + awk early-exit` sends SIGPIPE(141) to the upstream sshd -T;
  # under pipefail that fails the whole assignment and set -e kills the script.
  # A variable has no pipe writer, so the problem cannot occur.
  if ! SSHD_T_EFF="$("$SSHD_BIN" -T 2>&1)"; then
    ensure_run_sshd
    SSHD_T_EFF="$("$SSHD_BIN" -T 2>&1)" || err "sshd -T failed: ${SSHD_T_EFF:-unknown error}"
  fi
  log "SSH restarted; effective settings audit (sshd -T):"
  awk '/^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|challengeresponseauthentication|allowusers) /{printf "      %s\n", $0}' <<<"$SSHD_T_EFF"
  EFFECTIVE_PA="$(awk '/^passwordauthentication /{print $2; exit}' <<<"$SSHD_T_EFF")"
  if [ "$EFFECTIVE_PA" = "yes" ]; then
    warn "DANGER: PasswordAuthentication is still 'yes' (overridden by another config file). Inspect /etc/ssh/sshd_config.d/ and the main config immediately!"
  elif [ -z "$EFFECTIVE_PA" ]; then
    warn "Could not parse PasswordAuthentication from sshd -T; verify manually: sshd -T | grep -i passwordauth"
  fi
else
  log "No SSH_PUBLIC_KEY provided — skipping user creation and SSH hardening (to avoid locking you out)."
fi

# ==================== Kernel tuning (with BBR verification) ====================
log "Configuring kernel parameters..."
cat > /etc/sysctl.d/99-optimize.conf <<'EOF'
# Basic network and memory tuning
# Note: fs.file-max is intentionally NOT set — modern kernels default far
# higher than 100k; setting it manually would be a regression
net.core.somaxconn=65535
net.core.netdev_max_backlog=65535
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

# BBR: persist only when the module is available, to avoid leaving broken
# settings on kernels that lack it
if modprobe tcp_bbr 2>/dev/null; then
  echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
  cat >> /etc/sysctl.d/99-optimize.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
fi

sysctl --system >/dev/null 2>&1 || true

CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
if [ "$CURRENT_CC" = "bbr" ]; then
  log "BBR congestion control is active."
else
  warn "BBR not active (kernel/virtualization may not support it); current algorithm: ${CURRENT_CC}"
fi

# ==================== Docker ====================
log "Installing Docker CE + Compose plugin (official GPG repo)..."
install -m 0755 -d /etc/apt/keyrings
rm -f /etc/apt/keyrings/docker.gpg   # idempotency: --dearmor errors if the file already exists
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

CODENAME="${VERSION_CODENAME:-$(lsb_release -cs)}"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

if [ -n "$SSH_PUBLIC_KEY" ] && id "$NEW_USER" &>/dev/null; then
  usermod -aG docker "$NEW_USER" || true
fi

# Build the registry-mirrors JSON array (the key is always written; an empty array is valid)
MIRROR_ARR=""
for m in $REGISTRY_MIRRORS; do
  MIRROR_ARR+="\"${m}\", "
done
MIRROR_ARR="${MIRROR_ARR%, }"

mkdir -p /etc/docker
if [ "$ENABLE_IPV6" = "true" ]; then
  # ipv6/ip6tables are stable since Docker 27 — no "experimental" flag needed
  cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "registry-mirrors": [${MIRROR_ARR}],
  "ipv6": true,
  "ip6tables": true,
  "fixed-cidr-v6": "fd00:dead:beef:c0::/80"
}
EOF
else
  cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "registry-mirrors": [${MIRROR_ARR}]
}
EOF
fi
systemctl restart docker

if [ -n "$REGISTRY_MIRRORS" ]; then
  log "Docker Hub pull mirrors configured: ${REGISTRY_MIRRORS}"
else
  warn "REGISTRY_MIRRORS is not set. If this host cannot reach docker.io directly, the Portainer image pull will fail."
fi

# ==================== Portainer (official default install) ====================
log "Deploying Portainer CE (official default: admin account is created on first web visit)..."
mkdir -p /opt/portainer

# Idempotency: an existing data volume means Portainer was initialized before
# (admin already created) — keep it. No volume means a fresh deploy: create the
# admin account via the web UI within ~5 minutes of container start.
PORTAINER_FRESH=1
if docker volume inspect portainer_data &>/dev/null; then
  PORTAINER_FRESH=0
  warn "Existing portainer_data volume detected; keeping current Portainer data and admin account."
fi

# Clean up password files left by older script versions (v3.x): the
# --admin-password-file mechanism is gone, so these files serve no purpose
if [ -f /root/portainer_admin_password_hash ] || [ -f /root/portainer_initial_password.txt ]; then
  rm -f /root/portainer_admin_password_hash /root/portainer_initial_password.txt
  log "Removed legacy Portainer password files (pre-seeded passwords are no longer used)."
fi

cat > /opt/portainer/docker-compose.yml <<COMPOSE_EOF
services:
  portainer:
    image: portainer/portainer-ce:2.21.4   # pinned for reproducibility/rollback; bump manually when upgrading
    container_name: portainer
    restart: always
    environment:
      - TZ=${TIMEZONE}
    ports:
      - "${PORTAINER_BIND}:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
    name: portainer_data
COMPOSE_EOF

# Docker Hub connectivity pre-flight (only when no mirror is configured)
if [ -z "$REGISTRY_MIRRORS" ]; then
  if ! curl -m 5 -sI https://registry-1.docker.io/v2/ >/dev/null 2>&1; then
    warn "Docker Hub is unreachable and REGISTRY_MIRRORS is not set — the image pull will likely fail."
    warn "Consider aborting now and re-running with: REGISTRY_MIRRORS=\"https://mirror.example.com\" bash $0"
    read -r -t 10 -p "      (continuing in 10 seconds; a pull failure will not abort the remaining init steps)" _ || true
    echo ""
  fi
fi

docker rm -f portainer >/dev/null 2>&1 || true

# A failed deploy must not abort the script: an init script should never be
# blocked by a single component's image-pull problem
PORTAINER_UP=0
if docker compose -f /opt/portainer/docker-compose.yml up -d; then
  PORTAINER_UP=1
else
  warn "Portainer deploy failed (usually a blocked docker.io pull). Continuing with the remaining steps. Recovery options:"
  warn "  Option 1 (pre-pull + retag):"
  warn "    docker pull <mirror>/portainer/portainer-ce:2.21.4"
  warn "    docker tag <mirror>/portainer/portainer-ce:2.21.4 portainer/portainer-ce:2.21.4"
  warn "    cd /opt/portainer && docker compose up -d"
  warn "  Option 2 (configure a mirror and re-run):"
  warn "    REGISTRY_MIRRORS=\"https://mirror.example.com\" ALLOW_NON_FRESH=1 bash $0"
fi

if [ "$PORTAINER_UP" = "1" ]; then
  log "Waiting for Portainer to become ready (up to 30 seconds)..."
  PORTAINER_OK=0
  for _ in {1..10}; do
    sleep 3
    # No `grep -q`: it would exit early and SIGPIPE the upstream docker ps,
    # which under pipefail can produce a false negative
    if docker ps --format '{{.Names}}' 2>/dev/null | grep '^portainer$' >/dev/null \
       && curl -skf "https://${PORTAINER_BIND}:9443/api/status" >/dev/null 2>&1; then
      PORTAINER_OK=1
      break
    fi
  done
  if [ "$PORTAINER_OK" = "1" ]; then
    log "Portainer is ready."
  else
    warn "Portainer did not become ready within 30 seconds. Check manually: docker logs portainer"
  fi
fi

# ==================== Swap ====================
log "Configuring swap..."
if swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/swapfile'; then
  log "swapfile already active; skipping."
else
  mem_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
  if [ "${mem_mb:-0}" -lt 4096 ]; then
    if [ ! -f /swapfile ]; then
      fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"
      if [ "$fstype" = "btrfs" ]; then
        warn "Root filesystem is btrfs: fallocate-created files cannot be swapon'd; using dd (slower)."
        dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
      else
        fallocate -l "${SWAP_SIZE_MB}M" /swapfile 2>/dev/null \
          || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
      fi
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
    else
      # File exists but is not active (e.g. fstab was wiped); just re-enable it
      mkswap /swapfile
      swapon /swapfile
    fi
    grep -q '^/swapfile[[:space:]]' /etc/fstab \
      || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap enabled (/swapfile)."
  else
    log "Physical memory >= 4GB; skipping swap."
  fi
fi

# ==================== Unattended security updates + fail2ban ====================
log "Enabling unattended security upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable unattended-upgrades &>/dev/null || true

log "Configuring fail2ban (backend=systemd; works on Ubuntu 24.04 which has no /var/log/auth.log)..."
if [ "$DETECTED_SSH_PORT" != "$SSH_PORT" ]; then
  F2B_PORTS="${DETECTED_SSH_PORT},${SSH_PORT}"
else
  F2B_PORTS="${SSH_PORT}"
fi
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend = systemd
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ${F2B_PORTS}
EOF
systemctl enable fail2ban &>/dev/null || true
systemctl restart fail2ban 2>/dev/null \
  || warn "fail2ban failed to start; check manually: systemctl status fail2ban"
sleep 2
if fail2ban-client status sshd &>/dev/null; then
  log "fail2ban sshd jail is active."
else
  warn "fail2ban sshd jail is NOT active; check /etc/fail2ban/jail.local."
fi

# ==================== Firewall (enabled last) ====================
log "Configuring UFW..."
ufw default deny incoming
ufw default allow outgoing

# `limit` adds built-in rate limiting (6 connections/30s); when the detected
# port differs from SSH_PORT, allow both to avoid a lockout
ufw limit "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
if [ "$DETECTED_SSH_PORT" != "$SSH_PORT" ]; then
  ufw limit "${DETECTED_SSH_PORT}/tcp" comment 'SSH (detected)' >/dev/null
  warn "sshd actually listens on ${DETECTED_SSH_PORT} but SSH_PORT=${SSH_PORT}; both ports are now allowed — remove the extra rule once confirmed."
fi

if [ "$PORTAINER_BIND" != "127.0.0.1" ]; then
  if [ -n "$UFW_ALLOW_PORTAINER_IP" ]; then
    ufw allow from "$UFW_ALLOW_PORTAINER_IP" to any port 9443 proto tcp comment 'Portainer' >/dev/null
  else
    ufw allow 9443/tcp comment 'Portainer (all IPs)' >/dev/null
    warn "Portainer 9443 is now open to ALL source IPs."
  fi

  # UFW only filters the INPUT chain; traffic to published Docker ports is
  # DNATed through FORWARD and never hits UFW. DOCKER-USER is what counts.
  log "Installing DOCKER-USER port allowlist (persisted via systemd)..."
  cat > /usr/local/sbin/docker-user-guard.sh <<'GUARD_EOF'
#!/usr/bin/env bash
# Generated by VPS Init Script v4.1: restricts source IPs for the Docker-published
# port 9443. To change the allowlist: iptables -F DOCKER-USER, then re-run this
# script or restart the docker-user-guard service.
set -euo pipefail
ALLOW_IP="${1:-}"
iptables -C DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
if [ -n "$ALLOW_IP" ]; then
  iptables -C DOCKER-USER -p tcp --dport 9443 -s "$ALLOW_IP" -j ACCEPT 2>/dev/null \
    || iptables -I DOCKER-USER 2 -p tcp --dport 9443 -s "$ALLOW_IP" -j ACCEPT
  iptables -C DOCKER-USER -p tcp --dport 9443 -j DROP 2>/dev/null \
    || iptables -I DOCKER-USER 3 -p tcp --dport 9443 -j DROP
fi
GUARD_EOF
  chmod 755 /usr/local/sbin/docker-user-guard.sh

  cat > /etc/systemd/system/docker-user-guard.service <<UNIT_EOF
[Unit]
Description=Restore DOCKER-USER rules for published Docker ports
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/docker-user-guard.sh ${UFW_ALLOW_PORTAINER_IP}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
  systemctl daemon-reload
  if ! systemctl enable --now docker-user-guard.service; then
    warn "Failed to apply DOCKER-USER rules. Run manually: /usr/local/sbin/docker-user-guard.sh ${UFW_ALLOW_PORTAINER_IP}"
  fi
fi

ufw --force enable

# ==================== Final summary ====================
echo ""
echo "=============================================="
log "Initialization complete"
echo "=============================================="
if [ -n "$SSH_PUBLIC_KEY" ]; then
  echo "  Login user: ${LOGIN_USER}"
  echo "  SSH-allowed users: ${ALLOW_SSH_USERS}"
  if [ "$DETECTED_SSH_PORT" != "$SSH_PORT" ]; then
    echo "  SSH port: sshd=${DETECTED_SSH_PORT}; UFW allows both ${SSH_PORT} and ${DETECTED_SSH_PORT} (reconcile and clean up)"
  else
    echo "  SSH port: ${DETECTED_SSH_PORT}"
  fi
  if [ -n "$SUDO_PASS_NOTE" ]; then
    echo "$SUDO_PASS_NOTE"
    echo "  (saved to /root/${NEW_USER}_initial_password.txt; sudo is passwordless — keep this only as an su/console rescue credential)"
  fi
else
  echo "  No new user created; root login remains available."
fi
if [ "$PORTAINER_UP" = "1" ]; then
  if [ "$PORTAINER_FRESH" = "1" ]; then
    echo "  Portainer: fresh deploy — admin account NOT yet created"
    echo "  * Open https://localhost:9443 and create the admin account (within ~5 min of container start)"
    echo "    If the page says the window expired: docker restart portainer, then reload"
  else
    echo "  Portainer: existing data kept; admin credentials are the ones from the original deploy"
  fi
  if [ "$PORTAINER_BIND" = "127.0.0.1" ]; then
    echo "  Portainer access (SSH tunnel):"
    echo "    ssh -N -p ${DETECTED_SSH_PORT} -L 9443:localhost:9443 ${LOGIN_USER}@<server-ip>"
    echo "    then open https://localhost:9443"
  else
    echo "  Portainer public URL: https://<server-ip>:9443"
  fi
else
  echo "  Portainer: deploy FAILED (everything else succeeded) — see recovery options in the log above."
fi
echo ""
warn "Before closing this session, complete these checks:"
warn "  1. ufw status verbose  — confirm allowed ports are correct"
warn "  2. docker info         — Docker is healthy"
if [ "$PORTAINER_UP" = "1" ]; then
  warn "  3. docker ps           — Portainer is running"
else
  warn "  3. Portainer is NOT deployed — recover it first, then verify with docker ps"
fi
warn "  4. From ANOTHER terminal, log in as ${LOGIN_USER} with your key and run: sudo -n whoami"
warn "  5. Once confirmed, delete password files: rm -f /root/*_initial_password.txt"
warn "  6. To add/remove SSH users later: re-run with EXTRA_SSH_USERS, or edit AllowUsers in 00-hardening.conf and restart ssh"
if [ -f /run/reboot-required ]; then
  warn "  7. A reboot is required to finish updates; verify SSH login works, then reboot"
fi
echo "=============================================="
