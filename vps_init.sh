#!/usr/bin/env bash
set -euo pipefail

# ==================== 可配置参数 ====================
NEW_USER="${NEW_USER:-deploy}"              # 新建的 sudo 用户
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"        # 必填：你的 SSH 公钥
SSH_PORT="${SSH_PORT:-22}"                  # SSH 端口（本脚本仅用于防火墙放行，不实际修改 sshd）
PORTAINER_PASSWORD="${PORTAINER_PASSWORD:-}" # Portainer 管理员密码，留空则自动生成
PORTAINER_BIND="${PORTAINER_BIND:-127.0.0.1}" # Portainer 监听地址：127.0.0.1(推荐) 或 0.0.0.0(公网)
CREATE_SWAP="${CREATE_SWAP:-true}"           # 是否创建 swap
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"         # swap 大小（MB）
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"        # 时区
ENABLE_IPV6="${ENABLE_IPV6:-true}"           # Docker 是否启用 IPv6
UFW_ALLOW_PORTAINER_IP="${UFW_ALLOW_PORTAINER_IP:-}" # 若 Portainer 公网开放，可限制来源 IP

# ==================== 基础检查 ====================
if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 用户运行本脚本。"
  exit 1
fi

source /etc/os-release
if [ "$ID" != "ubuntu" ] && [ "$ID" != "debian" ]; then
  echo "当前脚本仅支持 Ubuntu / Debian。"
  exit 1
fi

log() { echo -e "\n\033[1;32m[+] $*\033[0m"; }

# ==================== 系统更新与基础包 ====================
log "更新系统并安装基础包..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban unattended-upgrades apache2-utils openssl sudo wget vim git

log "配置时区..."
timedatectl set-timezone "$TIMEZONE" || true

# ==================== 用户与 SSH 安全 ====================
LOGIN_USER="root"

if [ -n "$SSH_PUBLIC_KEY" ]; then
  log "创建/配置用户 ${NEW_USER} 并写入 SSH 公钥..."
  if ! id "$NEW_USER" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$NEW_USER"
    USER_INITIAL_PASSWORD=$(openssl rand -hex 8)
    echo "$NEW_USER:$USER_INITIAL_PASSWORD" | chpasswd
    echo "$USER_INITIAL_PASSWORD" > "/root/${NEW_USER}_initial_password.txt"
    chmod 600 "/root/${NEW_USER}_initial_password.txt"
  fi
  usermod -aG sudo "$NEW_USER" || true
  LOGIN_USER="$NEW_USER"

  mkdir -p "/home/${NEW_USER}/.ssh"
  echo "$SSH_PUBLIC_KEY" > "/home/${NEW_USER}/.ssh/authorized_keys"
  chmod 700 "/home/${NEW_USER}/.ssh"
  chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"
  chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"

  # root 也放同一把公钥，便于紧急恢复
  mkdir -p /root/.ssh
  echo "$SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys

  log "加固 SSH（禁用密码登录，保留公钥登录）..."
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers root ${NEW_USER}
EOF

  if sshd -t; then
    systemctl restart ssh || systemctl restart sshd || true
  else
    echo "SSH 配置验证失败，未重启 SSH。"
  fi
else
  log "未提供 SSH_PUBLIC_KEY，跳过新用户创建和 SSH 加固，避免被锁在系统外。"
fi

# ==================== 防火墙 / Fail2ban ====================
log "配置防火墙 UFW 和 Fail2ban..."
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
if [ "$PORTAINER_BIND" != "127.0.0.1" ]; then
  if [ -n "$UFW_ALLOW_PORTAINER_IP" ]; then
    ufw allow from "$UFW_ALLOW_PORTAINER_IP" to any port 9443 proto tcp comment 'Portainer'
  else
    ufw allow 9443/tcp comment 'Portainer (所有IP，请尽快改为反代或限制来源)'
  fi
fi
ufw --force enable
systemctl enable --now fail2ban

# ==================== Swap 创建 ====================
log "配置 swap..."
if [ "$CREATE_SWAP" = "true" ] && [ ! -f /swapfile ]; then
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  if [ "$mem_mb" -lt 4096 ]; then
    fallocate -l "${SWAP_SIZE_MB}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap 创建成功：${SWAP_SIZE_MB}MB"
  else
    log "物理内存 ≥4GB，跳过 Swap 创建。"
  fi
fi

# ==================== 内核参数优化 ====================
log "配置内核参数..."
cat > /etc/sysctl.d/99-optimize.conf <<'EOF'
fs.file-max=100000
net.core.somaxconn=65535
net.core.netdev_max_backlog=65535
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fin_timeout=15
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1 || true

# ==================== 安装 Docker ====================
log "安装 Docker CE 与 Docker Compose Plugin..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

if [ -n "$SSH_PUBLIC_KEY" ] && id "$NEW_USER" &>/dev/null; then
  usermod -aG docker "$NEW_USER" || true
fi

# ==================== Docker daemon 配置 ====================
log "配置 Docker daemon（日志限制 + IPv6 可选）..."
mkdir -p /etc/docker
if [ "$ENABLE_IPV6" = "true" ]; then
  cat > /etc/docker/daemon.json <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    },
    "ipv6": true,
    "fixed-cidr-v6": "fd00:dead:beef:c0::/80",
    "experimental": true,
    "ip6tables": true
}
EOF
else
  cat > /etc/docker/daemon.json <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    }
}
EOF
fi
systemctl restart docker

# ==================== Portainer 部署 ====================
log "部署 Portainer CE（默认仅监听 127.0.0.1，通过 NPM 反代访问）..."
if [ -z "$PORTAINER_PASSWORD" ]; then
  PORTAINER_PASSWORD=$(openssl rand -hex 16)
fi
PORTAINER_HASH=$(htpasswd -nbB admin "$PORTAINER_PASSWORD" | cut -d ':' -f2)
echo "$PORTAINER_PASSWORD" > /root/portainer_initial_password.txt
echo "$PORTAINER_HASH" > /root/portainer_admin_password_hash
chmod 600 /root/portainer_initial_password.txt /root/portainer_admin_password_hash

mkdir -p /opt/portainer
cat > /opt/portainer/docker-compose.yml <<COMPOSE_EOF
services:
  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: always
    environment:
      - TZ=${TIMEZONE}
    ports:
      - "${PORTAINER_BIND}:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
      - /root/portainer_admin_password_hash:/tmp/portainer_password:ro
    command: --admin-password-file /tmp/portainer_password

volumes:
  portainer_data:
COMPOSE_EOF

docker rm -f portainer >/dev/null 2>&1 || true
cd /opt/portainer && docker compose up -d

# ==================== 自动安全更新 ====================
log "启用无人值守安全更新..."
dpkg-reconfigure -f noninteractive unattended-upgrades || true

# ==================== 输出摘要 ====================
echo -e "\n=============================================="
echo -e "初始化完成"
echo -e "=============================================="
if [ -n "$SSH_PUBLIC_KEY" ]; then
  echo -e "登录用户: ${LOGIN_USER}"
  if [ -f "/root/${NEW_USER}_initial_password.txt" ]; then
    echo -e "${NEW_USER} 初始密码（用于 sudo，尽快修改）: $(cat /root/${NEW_USER}_initial_password.txt)"
  fi
else
  echo -e "未创建新用户（未提供 SSH_PUBLIC_KEY），仍可用 root 登录。"
fi
echo -e "Portainer 用户名: admin"
echo -e "Portainer 初始密码: ${PORTAINER_PASSWORD}"
echo -e "Portainer 密码已保存于: /root/portainer_initial_password.txt"
if [ "$PORTAINER_BIND" = "127.0.0.1" ]; then
  echo -e "Portainer 仅监听本机，请安装 NPM 并反代，或使用 SSH 隧道访问："
  echo -e "  ssh -N -L 9443:localhost:9443 ${LOGIN_USER}@<服务器IP>"
  echo -e "然后浏览器打开 https://localhost:9443"
else
  echo -e "Portainer 公网地址: https://<服务器IP>:9443"
  echo -e "注意：直接暴露 9443 存在安全风险，请尽快配置 NPM 反代。"
fi
echo -e "=============================================="
