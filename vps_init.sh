#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  VPS 初始化脚本 v3.8（最终版）
#  仅适用于全新安装的 Ubuntu / Debian 裸机。
#  运行前请保持另一个 root SSH 会话，以防万一。
#
#  用法：
#    SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." bash vps_init.sh
#  国内等 docker.io 被阻断的网络，请同时配置镜像加速：
#    REGISTRY_MIRRORS="https://docker.m.daocloud.io" bash vps_init.sh
#  （腾讯云内网可用 https://mirror.ccs.tencentyun.com）
#  无人值守时可直接传 PORTAINER_PASSWORD=...（会留在 shell 历史）；
#  交互终端会询问密码（回车则自动生成）。
# =============================================================================

# ==================== 可配置参数 ====================
NEW_USER="${NEW_USER:-deploy}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SSH_PORT="${SSH_PORT:-22}"
PORTAINER_PASSWORD="${PORTAINER_PASSWORD:-}"
PORTAINER_BIND="${PORTAINER_BIND:-127.0.0.1}"        # 强烈建议保持 127.0.0.1
UFW_ALLOW_PORTAINER_IP="${UFW_ALLOW_PORTAINER_IP:-}" # 公网绑定时来源白名单（可选）
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
ENABLE_IPV6="${ENABLE_IPV6:-true}"
ALLOW_NON_FRESH="${ALLOW_NON_FRESH:-0}"
REGISTRY_MIRRORS="${REGISTRY_MIRRORS:-}"             # Docker Hub 镜像加速，空格分隔多个

# ==================== 辅助函数 ====================
log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m" >&2; }  # 走 stderr：函数输出可能被命令替换捕获，不能污染 stdout
err()  { echo -e "\033[1;31m[-] $*\033[0m" >&2; exit 1; }
trap 'echo -e "\033[1;31m[-] 脚本在第 $LINENO 行失败，请检查上方输出后重跑。\033[0m" >&2' ERR

SSHD_BIN="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"

# 规范化：docker -p 不接受 "localhost" 作为 host IP
[ "$PORTAINER_BIND" = "localhost" ] && PORTAINER_BIND="127.0.0.1"

# /run 是 tmpfs，每次开机重建；/run/sshd 由 ssh.service 的 RuntimeDirectory= 或
# openssh 包的 tmpfiles.d 创建，并会在服务停止时被 systemd 清除。
# sshd -t/-T 在目录缺失时直接 fatal（"Missing privilege separation directory"）。
# 关键教训：apt 升级 openssh-server 会重启/停止 ssh 服务、清掉该目录——
# 所以除了这里，SSH 加固段（apt 之后）必须再次调用本函数。
ensure_run_sshd() {
  mkdir -p /run/sshd
  chmod 0755 /run/sshd
}
ensure_run_sshd   # 覆盖稍后 get_ssh_port 的 sshd -T

# ==================== 前置条件检查 ====================
[ "$(id -u)" -eq 0 ] || err "请用 root 用户运行本脚本。"
command -v systemctl &>/dev/null || err "未检测到 systemd，无法继续。"

source /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] \
  || err "仅支持 Ubuntu/Debian（检测到 ${ID:-unknown}）。"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # 避免 needrestart 弹交互菜单

# ---- 裸机检测 ----
WARN_COUNT=0

if command -v docker &>/dev/null; then
  if [ "$ALLOW_NON_FRESH" != "1" ]; then
    err "检测到 Docker 已安装，脚本会重新安装并可能影响已有容器。ALLOW_NON_FRESH=1 可强制继续。"
  else
    warn "检测到 Docker 已安装（ALLOW_NON_FRESH=1 已启用，继续）。"
  fi
fi

# 云厂商镜像自带 ubuntu/debian 用户属正常情况，仅提示
REGULAR_USERS="$(awk -F: '$3>=1000 && $3<65534 && $7 ~ /(bash|sh|zsh)$/ {printf "%s ", $1}' /etc/passwd || true)"
if [ -n "$REGULAR_USERS" ]; then
  warn "检测到已存在普通用户：${REGULAR_USERS}（云镜像常见）"
fi

if ufw status 2>/dev/null | grep -q "Status: active"; then
  WARN_COUNT=$((WARN_COUNT + 1))
fi

if [ "$WARN_COUNT" -gt 0 ] && [ "$ALLOW_NON_FRESH" != "1" ]; then
  err "检测到 ${WARN_COUNT} 个非裸机信号。ALLOW_NON_FRESH=1 可强制继续。"
fi

# ==================== SSH 端口检测（不修改 sshd，仅用于 UFW/提示） ====================
get_ssh_port() {
  local out port
  if ! out="$("$SSHD_BIN" -T 2>&1)"; then
    warn "sshd -T 读取失败: ${out}——端口检测回退为 22"
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
log "检测到 sshd 当前监听端口: ${DETECTED_SSH_PORT}"

# ==================== 系统更新与基础包 ====================
log "更新系统并安装基础包..."
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban \
  unattended-upgrades apache2-utils openssl sudo wget vim git iptables

if [ -f /run/reboot-required ]; then
  warn "系统提示需要重启才能完成更新，验证 SSH 后建议 reboot。"
fi

log "配置时区..."
timedatectl set-timezone "$TIMEZONE" 2>/dev/null || warn "时区设置失败，跳过。"

# ==================== 用户与 SSH 安全 ====================
LOGIN_USER="root"
SUDO_PASS_NOTE=""

if [ -n "$SSH_PUBLIC_KEY" ]; then
  log "创建/配置用户 ${NEW_USER} 并写入 SSH 公钥..."
  if ! id "$NEW_USER" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$NEW_USER"
    INIT_PASS="$(openssl rand -base64 24)"
    echo "$NEW_USER:$INIT_PASS" | chpasswd
    # 落盘保存：sudo 虽已免密，此密码仍作 su / 供应商控制台救援的备用凭证
    echo "$INIT_PASS" > "/root/${NEW_USER}_initial_password.txt"
    chmod 600 "/root/${NEW_USER}_initial_password.txt"
    SUDO_PASS_NOTE="  ${NEW_USER} 初始密码: ${INIT_PASS}"
  else
    warn "用户 ${NEW_USER} 已存在，跳过创建。若忘记密码: passwd ${NEW_USER}"
  fi
  usermod -aG sudo "$NEW_USER" || true
  LOGIN_USER="$NEW_USER"

  # 免密 sudo（写入后立刻校验，失败则移除，用户仍可用密码 sudo）
  cat > "/etc/sudoers.d/90-${NEW_USER}" <<EOF
 ${NEW_USER} ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 440 "/etc/sudoers.d/90-${NEW_USER}"
  if ! visudo -cf "/etc/sudoers.d/90-${NEW_USER}" &>/dev/null; then
    rm -f "/etc/sudoers.d/90-${NEW_USER}"
    err "sudoers 语法校验失败，已移除该文件。用户密码 sudo 仍可用，请排查后重跑。"
  fi

  # 幂等：追加公钥而非覆盖，保留已有密钥
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

  log "加固 SSH（drop-in 命名 00-，先于 cloud-init 读取）..."
  mkdir -p /etc/ssh/sshd_config.d

  # 少数镜像主配置缺 Include，补到文件顶部
  grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config \
    || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

  # 关键修复：上面 apt-get upgrade 刚升级过 openssh-server，升级重启/停止 ssh 服务时
  # RuntimeDirectory=sshd 被 systemd 清除，必须在这里重建，否则后续 sshd 检测全部 fatal
  ensure_run_sshd

  # 逐项探测本机 sshd 是否支持指令，避免整个 drop-in 因单条指令失效
  # （OpenSSH 8.2 不认 KbdInteractiveAuthentication，新版本可能移除 ChallengeResponseAuthentication）
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
  SSH_OPTS+=("AllowUsers root ${NEW_USER}")

  # 关键：sshd 对大多数指令取『首次出现的值』。
  # 00- 前缀保证本文件按字典序最先读取，先于 50-cloud-init.conf 生效。
  # 切勿改成 99- 等更大序号，否则加固会被 cloud-init 静默覆盖！
  {
    echo "# 由 VPS 初始化脚本 v3.8 生成。"
    echo "# sshd 首次出现的值生效；00- 前缀保证先于 50-cloud-init.conf 读取。"
    for opt in "${SSH_OPTS[@]}"; do
      echo "$opt"
    done
  } > /etc/ssh/sshd_config.d/00-hardening.conf
  chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf

  if [ -n "$REGULAR_USERS" ]; then
    warn "AllowUsers 仅含 root 和 ${NEW_USER}；以下已有用户加固后将无法 SSH 登录：${REGULAR_USERS}"
    warn "如需保留，请把用户名加入 /etc/ssh/sshd_config.d/00-hardening.conf 的 AllowUsers 行"
  fi

  # 校验失败时输出 sshd 的真实报错；若失败是 /run/sshd 再次丢失，先重建再重试一次
  if ! SSHD_T_OUT="$("$SSHD_BIN" -t 2>&1)"; then
    ensure_run_sshd
    if ! SSHD_T_OUT="$("$SSHD_BIN" -t 2>&1)"; then
      err "sshd -t 校验失败: ${SSHD_T_OUT:-未知错误}。请检查 /etc/ssh/sshd_config.d/00-hardening.conf 与 sshd 主配置。"
    fi
    log "sshd -t 首次失败（目录竞态），重建 /run/sshd 后重试通过。"
  fi

  if ! systemctl restart sshd 2>/dev/null && ! systemctl restart ssh 2>/dev/null; then
    err "SSH 重启失败（此时 UFW 尚未启用，当前会话不受影响）。请手动排查后重跑。"
  fi
  log "SSH 已重启，生效参数核对（sshd -T）："
  "$SSHD_BIN" -T 2>/dev/null \
    | grep -Ei '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|challengeresponseauthentication|allowusers) ' \
    | sed 's/^/      /'
  # 断言：防止加固被其他文件覆盖后静默失效
  EFFECTIVE_PA="$("$SSHD_BIN" -T 2>/dev/null | awk '/^passwordauthentication /{print $2; exit}')"
  if [ "$EFFECTIVE_PA" = "yes" ]; then
    warn "危险：PasswordAuthentication 实际仍为 yes（被其他配置覆盖），请立即检查 /etc/ssh/sshd_config.d/ 与主配置！"
  fi
else
  log "未提供 SSH_PUBLIC_KEY，跳过用户创建与 SSH 加固（避免被锁在系统外）。"
fi

# ==================== 内核参数（含 BBR 实测） ====================
log "配置内核参数..."
cat > /etc/sysctl.d/99-optimize.conf <<'EOF'
# 基础网络与内存调优
# 注：不设 fs.file-max——新内核默认值远高于 10 万，手工设置反而是倒退
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

# BBR：模块可用才写入持久化配置，避免在不支持的内核上留下报错项
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
  log "BBR 拥塞控制已启用。"
else
  warn "BBR 未生效（内核/虚拟化可能不支持），当前算法: ${CURRENT_CC}"
fi

# ==================== 安装 Docker ====================
log "安装 Docker CE + Compose 插件（官方 GPG 源）..."
install -m 0755 -d /etc/apt/keyrings
rm -f /etc/apt/keyrings/docker.gpg   # 幂等：--dearmor 遇已存在文件会报错
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

# 构建 registry-mirrors JSON 数组（始终写出该键，空数组合法）
MIRROR_ARR=""
for m in $REGISTRY_MIRRORS; do
  MIRROR_ARR+="\"${m}\", "
done
MIRROR_ARR="${MIRROR_ARR%, }"

mkdir -p /etc/docker
if [ "$ENABLE_IPV6" = "true" ]; then
  # ipv6/ip6tables 自 Docker 27 起为稳定特性，无需 experimental
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
  log "已配置 Docker Hub 镜像加速: ${REGISTRY_MIRRORS}"
else
  warn "未配置 REGISTRY_MIRRORS。若本机网络无法直连 docker.io（国内常见），Portainer 镜像将拉取失败。"
fi

# ==================== 部署 Portainer ====================
log "部署 Portainer CE..."
mkdir -p /opt/portainer

# 幂等：数据卷存在且密码 hash 文件在 → 视为已部署，沿用旧密码；否则重新初始化
PORTAINER_FRESH=1
if docker volume inspect portainer_data &>/dev/null && [ -f /root/portainer_admin_password_hash ]; then
  PORTAINER_FRESH=0
  warn "检测到已部署的 Portainer 数据卷，跳过管理员密码初始化（沿用首次部署的密码）。"
fi

if [ "$PORTAINER_FRESH" = "1" ]; then
  if [ -z "$PORTAINER_PASSWORD" ] && [ -t 0 ]; then
    read -r -s -p "设置 Portainer admin 密码（输入不回显，直接回车则自动生成）: " PORTAINER_PASSWORD || true
    echo ""
  fi
  if [ -z "$PORTAINER_PASSWORD" ]; then
    PORTAINER_PASSWORD="$(openssl rand -base64 24)"
  fi
  # -i 从 stdin 读密码，避免密码出现在 htpasswd 的 argv（ps 可见）
  printf '%s' "$PORTAINER_PASSWORD" | htpasswd -niB -C 10 admin | cut -d: -f2- \
    > /root/portainer_admin_password_hash
  echo "$PORTAINER_PASSWORD" > /root/portainer_initial_password.txt
  chmod 600 /root/portainer_admin_password_hash /root/portainer_initial_password.txt
fi

# 卷已存在时 --admin-password-file 不会生效，且挂载不存在的 bind 路径会让 Docker
# 创建同名目录导致容器异常，因此两种情况使用不同的 compose 文件。
if [ "$PORTAINER_FRESH" = "1" ]; then
  cat > /opt/portainer/docker-compose.yml <<COMPOSE_EOF
services:
  portainer:
    image: portainer/portainer-ce:2.21.4   # 锁定版本便于复现/回滚；升级时手动修改
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
    name: portainer_data
COMPOSE_EOF
else
  cat > /opt/portainer/docker-compose.yml <<COMPOSE_EOF
services:
  portainer:
    image: portainer/portainer-ce:2.21.4
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
fi

# Docker Hub 连通性预检（仅未配置镜像时）
if [ -z "$REGISTRY_MIRRORS" ]; then
  if ! curl -m 5 -sI https://registry-1.docker.io/v2/ >/dev/null 2>&1; then
    warn "Docker Hub 直连超时且未配置 REGISTRY_MIRRORS——镜像拉取预计失败。"
    warn "建议现在中止，改用: REGISTRY_MIRRORS=\"https://docker.m.daocloud.io\" bash $0 重跑"
    read -r -t 10 -p "      （10 秒后自动继续部署，失败不影响其余初始化步骤）" _ || true
    echo ""
  fi
fi

docker rm -f portainer >/dev/null 2>&1 || true

# 部署失败不中止脚本：初始化脚本不应被单一组件的镜像拉取问题卡死
PORTAINER_UP=0
if docker compose -f /opt/portainer/docker-compose.yml up -d; then
  PORTAINER_UP=1
else
  warn "Portainer 部署失败（通常是 docker.io 拉取被阻断）。脚本继续执行其余步骤，恢复方法："
  warn "  方法1（预拉取+retag）:"
  warn "    docker pull docker.m.daocloud.io/portainer/portainer-ce:2.21.4"
  warn "    docker tag docker.m.daocloud.io/portainer/portainer-ce:2.21.4 portainer/portainer-ce:2.21.4"
  warn "    cd /opt/portainer && docker compose up -d"
  warn "  方法2（全局加速后重跑）:"
  warn "    REGISTRY_MIRRORS=\"https://docker.m.daocloud.io\" ALLOW_NON_FRESH=1 bash $0"
fi

if [ "$PORTAINER_UP" = "1" ]; then
  log "等待 Portainer 就绪（最多 30 秒）..."
  PORTAINER_OK=0
  for _ in {1..10}; do
    sleep 3
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^portainer$' \
       && curl -skf "https://${PORTAINER_BIND}:9443/api/status" >/dev/null 2>&1; then
      PORTAINER_OK=1
      break
    fi
  done
  if [ "$PORTAINER_OK" = "1" ]; then
    log "Portainer 已就绪。"
  else
    warn "Portainer 未在 30 秒内就绪。请手动检查: docker logs portainer"
  fi
fi

# ==================== Swap ====================
log "配置 swap..."
if swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/swapfile'; then
  log "swapfile 已启用，跳过。"
else
  mem_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
  if [ "${mem_mb:-0}" -lt 4096 ]; then
    if [ ! -f /swapfile ]; then
      fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || echo unknown)"
      if [ "$fstype" = "btrfs" ]; then
        warn "根分区为 btrfs：fallocate 生成的文件无法 swapon，改用 dd（较慢）。"
        dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
      else
        fallocate -l "${SWAP_SIZE_MB}M" /swapfile 2>/dev/null \
          || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
      fi
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
    else
      mkswap /swapfile
      swapon /swapfile
    fi
    grep -q '^/swapfile[[:space:]]' /etc/fstab \
      || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap 已启用（/swapfile）。"
  else
    log "物理内存 ≥4GB，跳过 Swap。"
  fi
fi

# ==================== 自动安全更新 + fail2ban ====================
log "启用无人值守安全更新..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable unattended-upgrades &>/dev/null || true

log "配置 fail2ban（backend=systemd，适配 Ubuntu 24.04 无 /var/log/auth.log）..."
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
  || warn "fail2ban 启动失败，请手动检查: systemctl status fail2ban"
sleep 2
if fail2ban-client status sshd &>/dev/null; then
  log "fail2ban sshd jail 已生效。"
else
  warn "fail2ban sshd jail 未生效，请检查 /etc/fail2ban/jail.local。"
fi

# ==================== 防火墙（最后启用） ====================
log "配置 UFW 防火墙..."
ufw default deny incoming
ufw default allow outgoing

ufw limit "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
if [ "$DETECTED_SSH_PORT" != "$SSH_PORT" ]; then
  ufw limit "${DETECTED_SSH_PORT}/tcp" comment 'SSH (detected)' >/dev/null
  warn "sshd 实际监听 ${DETECTED_SSH_PORT} ≠ SSH_PORT=${SSH_PORT}，两个端口均已放行；确认后请删除多余一条。"
fi

if [ "$PORTAINER_BIND" != "127.0.0.1" ]; then
  if [ -n "$UFW_ALLOW_PORTAINER_IP" ]; then
    ufw allow from "$UFW_ALLOW_PORTAINER_IP" to any port 9443 proto tcp comment 'Portainer' >/dev/null
  else
    ufw allow 9443/tcp comment 'Portainer (all IPs)' >/dev/null
    warn "Portainer 9443 对所有 IP 开放。"
  fi

  # UFW 只管 INPUT 链，管不到 Docker DNAT 的转发流量；真正生效的是 DOCKER-USER 链
  log "安装 DOCKER-USER 端口白名单（systemd 持久化）..."
  cat > /usr/local/sbin/docker-user-guard.sh <<'GUARD_EOF'
#!/usr/bin/env bash
# 由 VPS 初始化脚本 v3.8 生成：限制 Docker 发布端口 9443 的来源。
# 更换白名单时：iptables -F DOCKER-USER 后重跑本脚本，或重启 docker-user-guard 服务。
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
    warn "DOCKER-USER 规则下发失败，请手动执行: /usr/local/sbin/docker-user-guard.sh ${UFW_ALLOW_PORTAINER_IP}"
  fi
fi

ufw --force enable

# ==================== 完成提示 ====================
echo ""
echo "=============================================="
log "初始化完成"
echo "=============================================="
if [ -n "$SSH_PUBLIC_KEY" ]; then
  echo "  登录用户: ${LOGIN_USER}"
  if [ "$DETECTED_SSH_PORT" != "$SSH_PORT" ]; then
    echo "  SSH 端口: sshd=${DETECTED_SSH_PORT}；UFW 已放行 ${SSH_PORT} 和 ${DETECTED_SSH_PORT}（请核对后清理）"
  else
    echo "  SSH 端口: ${DETECTED_SSH_PORT}"
  fi
  if [ -n "$SUDO_PASS_NOTE" ]; then
    echo "$SUDO_PASS_NOTE"
    echo "  （已写入 /root/${NEW_USER}_initial_password.txt；sudo 已免密，此密码仅作 su/控制台救援备用）"
  fi
else
  echo "  未创建新用户，仍可用 root 登录。"
fi
echo "  Portainer 用户名: admin"
if [ "$PORTAINER_UP" = "1" ]; then
  if [ "$PORTAINER_FRESH" = "1" ]; then
    echo "  Portainer 初始密码: ${PORTAINER_PASSWORD}"
    echo "  （已写入 /root/portainer_initial_password.txt，记下后请删除）"
  else
    echo "  Portainer 密码: 沿用首次部署时设置（本次未改动）。"
  fi
  if [ "$PORTAINER_BIND" = "127.0.0.1" ]; then
    echo "  Portainer 访问（SSH 隧道）:"
    echo "    ssh -N -p ${DETECTED_SSH_PORT} -L 9443:localhost:9443 ${LOGIN_USER}@<服务器IP>"
    echo "    然后打开 https://localhost:9443"
  else
    echo "  Portainer 公网地址: https://<服务器IP>:9443"
  fi
else
  echo "  Portainer: 未部署成功（其余初始化均已完成），按上方日志中的两种方法恢复。"
fi
echo ""
warn "退出当前会话前，请完成以下检查："
warn "  1. ufw status verbose  — 确认放行端口正确"
warn "  2. docker info         — Docker 正常"
if [ "$PORTAINER_UP" = "1" ]; then
  warn "  3. docker ps           — Portainer 运行中"
else
  warn "  3. Portainer 未部署——先按上方方法恢复，再 docker ps 验证"
fi
warn "  4. 另开终端用 ${LOGIN_USER} 密钥登录，并执行 sudo -n whoami 验证提权"
warn "  5. 确认后删除密码文件: rm -f /root/*_initial_password.txt"
warn "  6. 以后新增登录用户需同步修改 /etc/ssh/sshd_config.d/00-hardening.conf 的 AllowUsers"
if [ -f /run/reboot-required ]; then
  warn "  7. 系统提示需要重启，验证 SSH 可登录后执行 reboot"
fi
echo "=============================================="
