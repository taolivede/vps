# VPS 初始化脚本（VPS Init Script）

一键初始化全新 **Ubuntu / Debian** VPS 的 Bash 脚本：系统安全加固、内核与资源优化、Docker 环境安装、Portainer 部署，一气呵成。适用于个人开发服务器与小型生产环境的基础配置。

---

## ✨ 功能特性

- ✅ **系统更新与基础工具**（git、vim、curl、wget、iptables 等）
- ✅ **全新机器检测**：发现已装 Docker / 已启用 UFW 时拒绝执行，防止误伤现有环境（可用 `ALLOW_NON_FRESH=1` 显式覆盖）
- ✅ **SSH 安全加固**
  - 仅公钥认证，彻底关闭密码登录
  - 创建 sudo 管理用户（免密 sudo，另生成一份救援密码落盘备用）
  - `AllowUsers` 白名单；可通过 `EXTRA_SSH_USERS` 保留云镜像自带用户
  - 加固配置以 `00-` 前缀写入 drop-in 目录，**先于 cloud-init 读取**，防止被厂商默认配置静默覆盖
  - 重启后自动核对 `sshd -T` 生效值，被覆盖时立即告警
- ✅ **fail2ban 入侵防御**（`backend=systemd`，兼容无 `/var/log/auth.log` 的 Ubuntu 24.04）
- ✅ **UFW 防火墙**：SSH 使用 `limit` 规则自带连接限速；**最后启用**，杜绝中途断连
- ✅ **内核参数优化**：TCP 队列、端口复用、FastOpen 等调优；**BBR 模块可用才启用并实测验证**
- ✅ **Docker CE + Compose Plugin (v2)**，官方 GPG 仓库安装
- ✅ **Docker 日志轮转**（单文件 20MB × 3，防止磁盘爆满）、可选 IPv6、可选镜像加速（`REGISTRY_MIRRORS`）
- ✅ **Portainer CE** 按官方默认方式部署，默认仅监听 `127.0.0.1`，管理员账号在首次访问网页时由你自己创建
- ✅ **无人值守安全更新**（unattended-upgrades）
- ✅ **Swap 自动配置**（物理内存 < 4GB 时创建，默认 2GB，兼容 btrfs 根分区）
- ✅ **幂等可重跑**：重复执行安全，已有配置自动去重/跳过
- ✅ **初始化摘要与退出前检查清单**，包含登录信息、访问方式与收尾步骤

---

## 🚀 快速开始

### 前置条件

- 全新安装的 Ubuntu 20.04+ 或 Debian 11+（systemd）
- root 权限
- **一份 SSH 公钥**（强烈建议。不提供则脚本跳过 SSH 加固，仅保留 root 密码登录——不安全）

### 运行

推荐先下载再执行（脚本内含少量交互提示，`curl | bash` 管道方式可能被 stdin 干扰）：

```bash
wget -O vps_init.sh https://raw.githubusercontent.com/你的用户名/你的仓库/main/vps_init.sh
chmod +x vps_init.sh

SSH_PUBLIC_KEY="ssh-ed25519 AAAA...你的公钥..." \
bash vps_init.sh
```

国内服务器（docker.io 不可达）追加镜像加速：

```bash
REGISTRY_MIRRORS="https://docker.m.daocloud.io" \
SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." \
bash vps_init.sh
```

云镜像自带 `ubuntu` 等用户、希望保留其 SSH 登录能力时：

```bash
EXTRA_SSH_USERS="ubuntu lighthouse" \
SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." \
bash vps_init.sh
```

等待脚本执行完毕（约 5～10 分钟），按结尾输出的**检查清单**逐项验证。若系统提示需要重启，验证 SSH 可登录后执行 `reboot`。

> ⚠️ 运行期间请**保持当前 SSH 会话不断开**，全部验证通过前它就是你的生命线。

---

## 🔧 环境变量说明

| 变量名 | 默认值 | 必填 | 说明 |
|---|---|---|---|
| `SSH_PUBLIC_KEY` | 无 | 强烈建议 | SSH 公钥，用于创建免密登录用户并写入 root 的 authorized_keys。**留空则跳过用户创建与全部 SSH 加固** |
| `NEW_USER` | `deploy` | 否 | 新建的 sudo 管理用户名 |
| `SSH_PORT` | `22` | 否 | 仅用于防火墙放行，**不会修改 sshd 实际监听端口**。脚本会探测 sshd 真实端口，两者不一致时两个端口都会放行并告警 |
| `EXTRA_SSH_USERS` | 无 | 否 | 额外允许 SSH 登录的已有用户，空格分隔（如 `"ubuntu lighthouse"`）。云镜像默认用户不加入将被 AllowUsers 拒绝 |
| `PORTAINER_BIND` | `127.0.0.1` | 否 | Portainer 监听地址。`127.0.0.1` 仅本机（推荐，配合 SSH 隧道）；设为 `0.0.0.0` 则公网可访问（脚本会自动配置 DOCKER-USER 白名单机制） |
| `UFW_ALLOW_PORTAINER_IP` | 无 | 否 | 当 `PORTAINER_BIND≠127.0.0.1` 时，限制可访问 9443 的来源 IP |
| `SWAP_SIZE_MB` | `2048` | 否 | Swap 大小（MB），仅物理内存 < 4GB 时生效 |
| `TIMEZONE` | `UTC`（国际版）/ `Asia/Shanghai`（中文版） | 否 | 系统时区 |
| `ENABLE_IPV6` | `true` | 否 | Docker 是否启用 IPv6（对无 IPv6 的 VPS 无副作用） |
| `REGISTRY_MIRRORS` | 无 | 否 | Docker Hub 镜像加速地址，空格分隔多个。docker.io 被阻断的网络必需 |
| `ALLOW_NON_FRESH` | `0` | 否 | 重跑开关：机器已有 Docker/UFW 时设为 `1` 强制继续 |

> 自 v4.0 起，`PORTAINER_PASSWORD` 已移除——Portainer 采用官方默认安装，管理员在首次访问网页时创建（见下文）。

---

## 🔑 如何生成 SSH 公钥

如果你还没有 SSH 密钥对：

**Windows（PowerShell）/ macOS / Linux 通用：**

```bash
ssh-keygen -t ed25519 -C "你的邮箱或备注"
# 按提示回车（可设置 passphrase，或直接回车留空）
```

查看公钥：

```bash
# macOS / Linux
cat ~/.ssh/id_ed25519.pub
# Windows PowerShell
Get-Content ~/.ssh/id_ed25519.pub
```

复制**整行输出**（以 `ssh-ed25519` 开头），作为 `SSH_PUBLIC_KEY` 的值。

---

## 🌐 Portainer 初始化与访问

### 首次初始化（重要！）

本脚本采用 Portainer **官方默认安装方式**：不预置密码，管理员账号由你在网页上创建。

1. 建立隧道（见下）后，浏览器打开 `https://localhost:9443`（自签证书，选择继续访问）；
2. 在表单中设置 admin 用户名与密码，提交即完成初始化；
3. ⏱️ **容器启动后约 5 分钟内必须完成此操作**，否则 Portainer 会锁定安装入口。超时了也没关系：

```bash
docker restart portainer   # 重启后刷新页面，重新获得 5 分钟窗口
```

### 方式一：SSH 隧道访问（推荐）

```bash
ssh -N -L 9443:localhost:9443 deploy@你的服务器IP
# 浏览器打开 https://localhost:9443
```

可写入本地 `~/.ssh/config` 免每次输长命令：

```
Host myvps
    HostName 你的服务器IP
    User deploy
    IdentityFile ~/.ssh/id_ed25519
    LocalForward 9443 localhost:9443
```

之后仅需 `ssh -N myvps`。

### 方式二：反向代理（业务服务对外的标准架构）

当你开始部署对外业务（网站、API 等）时，推荐安装 Nginx Proxy Manager (NPM) 作为统一入口：**云防火墙只开 22/80/443 三个端口，此后新增任何服务都通过 NPM 的子域名转发，无需再去云控制台开端口。**

1. NPM 的 stack 示例（注意管理端口 81 绑定回环）：

```yaml
services:
  app:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '127.0.0.1:81:81'   # 管理后台仅本机可达，走 SSH 隧道访问
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
```

2. 访问管理后台：`ssh -N -L 8181:localhost:81 deploy@服务器IP`，浏览器打开 `http://localhost:8181`，用默认账号 `admin@example.com / changeme` 登录并**立即修改密码**、开启 2FA；
3. 业务容器与 NPM 加入同一 Docker network，在 NPM 中添加 Proxy Host（域名 → 容器名:端口），SSL 证书自动申请、自动续期。

**安全原则**：管理面板（Portainer 9443、NPM 81）永远绑 `127.0.0.1` 走隧道；只有面向公众的业务端口才发布公网。

---

## ✅ 运行后验证

```bash
docker --version              # Docker 版本
docker compose version        # Compose v2（注意：空格，不是 docker-compose）
docker ps                     # 应包含 portainer
sudo ss -lntp | grep 9443     # 应显示绑定 127.0.0.1:9443
sudo ufw status verbose       # 22/tcp LIMIT，默认 deny incoming
sudo fail2ban-client status sshd   # sshd jail 已生效
sysctl net.ipv4.tcp_congestion_control   # bbr
git --version                 # 基础工具已含 git
```

**最重要的一步**：另开一个终端，用新用户 + 密钥登录并验证提权：

```bash
ssh deploy@服务器IP
sudo -n whoami        # 应输出 root
```

确认无误后清理救援密码文件：

```bash
sudo rm -f /root/*_initial_password.txt
```

---

## 🔁 重跑与幂等

脚本设计为**可安全重复执行**：

| 场景 | 行为 |
|---|---|
| 用户已存在 | 跳过创建（追加公钥，保留已有密钥） |
| SSH 加固配置 | 重新生成（以最后一次运行参数为准） |
| Docker 已安装 | 默认拒绝执行，`ALLOW_NON_FRESH=1` 强制 |
| portainer_data 卷已存在 | 沿用现有数据与管理员，不再初始化 |
| swap 已启用 / 文件已存在 | 自动跳过或重新挂载 |
| authorized_keys | 追加去重，不覆盖 |

重跑命令示例：

```bash
ALLOW_NON_FRESH=1 SSH_PUBLIC_KEY="..." bash vps_init.sh
```

---

## 📁 服务器上产生的文件

```
/etc/ssh/sshd_config.d/00-hardening.conf   # SSH 加固 drop-in（00- 前缀确保先于 cloud-init）
/etc/sudoers.d/90-<user>                   # 免密 sudo
/root/<user>_initial_password.txt          # 救援密码（600，验证后删除）
/etc/sysctl.d/99-optimize.conf             # 内核参数
/etc/modules-load.d/tcp_bbr.conf           # BBR 模块持久化（内核支持时）
/etc/docker/daemon.json                    # Docker 配置（日志轮转/IPv6/镜像加速）
/etc/apt/sources.list.d/docker.list        # Docker 官方源
/etc/apt/apt.conf.d/20auto-upgrades        # 无人值守更新
/etc/fail2ban/jail.local                   # fail2ban 规则
/opt/portainer/docker-compose.yml          # Portainer 编排文件
/usr/local/sbin/docker-user-guard.sh       # DOCKER-USER 白名单（仅公网绑定时）
```

---

## 🔒 安全建议

1. **始终密钥登录**：脚本已关闭密码认证；不要为图方便重新打开。
2. **管理面板不暴露公网**：保持 `PORTAINER_BIND=127.0.0.1`，NPM 管理端口 81 同理；公网只保留业务必需端口（80/443）。
3. **及时收尾**：验证通过后删除 `/root/*_initial_password.txt`；系统提示重启就重启。
4. **定期更新**：系统安全补丁已由 unattended-upgrades 自动处理；容器镜像定期 `docker compose pull && docker compose up -d`。
5. **备份**：Portainer 数据卷、NPM 配置目录、以及你自己的业务数据卷。
6. **增删 SSH 用户**：修改 `EXTRA_SSH_USERS` 重跑，或直接编辑 `00-hardening.conf` 的 `AllowUsers` 行后 `systemctl restart ssh`。
7. 可选：安装 [Tailscale](https://tailscale.com) 组建私有网络，管理面板从此零公网暴露且手机可直接访问。

---

## ❓ 常见问题

**1. 提示不支持当前系统？**
仅支持 Ubuntu 20.04+ / Debian 11+，且需 root + systemd。`systemd-detect-virt` 可查看虚拟化类型（LXC/OpenVZ 容器上部分功能可能受限）。

**2. 没有提供 SSH 公钥会怎样？**
脚本跳过用户创建与 SSH 加固，仍以 root 密码登录（不安全）。随时可补传公钥重跑。

**3. Portainer 的管理员密码是什么？**
v4.0 起**没有预置密码**。首次访问 `https://localhost:9443` 时由你自己创建 admin 账号（容器启动后约 5 分钟内完成，超时执行 `docker restart portainer` 恢复）。旧版脚本生成的 `/root/portainer_initial_password.txt` 会被自动清理。

**4. 如何修改 Portainer 密码？**
登录网页 UI → 右上角用户名 → My account → 修改密码。

**5. 脚本会修改 SSH 端口吗？**
不会。`SSH_PORT` 仅用于防火墙放行。脚本会探测 sshd 真实端口，不一致时两个端口都会放行并打印告警。

**6. 新连接报 `Permission denied (publickey)`？**
服务器只收密钥，而你未提供正确私钥。本地执行 `ssh -v user@ip 2>&1 | grep -i offering` 查看是否提供了密钥；最常见原因是本地从未持有配对私钥（如一直使用云厂商网页终端）。修复：本地 `ssh-keygen` 生成新密钥，把新公钥追加到服务器 `/home/deploy/.ssh/authorized_keys`。

**7. 新连接直接超时？**
网络层丢包：检查云厂商防火墙是否放行 22；是否触发 `ufw limit` 限速（等 60 秒再试单次）；fail2ban 是否误封（`fail2ban-client status sshd` 查看）。终极救援走云控制台 **VNC**（不走 SSH，不受防火墙影响）。

**8. 报 `Missing privilege separation directory: /run/sshd`？**
`/run` 是 tmpfs，该目录在 sshd 非 systemd 托管运行时会缺失。执行 `mkdir -p /run/sshd && chmod 0755 /run/sshd` 后重跑脚本（脚本已内置自动重建与重试，正常情况不会再遇到）。

**9. 镜像拉取失败 / `i/o timeout`？**
docker.io 被网络阻断（DNS 污染或防火墙）。配置 `REGISTRY_MIRRORS="https://docker.m.daocloud.io"` 重跑，或手动预拉取后 retag（脚本失败时会打印完整恢复命令）。

**10. apt 升级时输出大量警告（fwupd 失败、SyntaxWarning 等）？**
均无害：fwupd 是物理机固件更新服务（可 `systemctl disable --now fwupd` 屏蔽）；SyntaxWarning 是 Python 3.12 对 fail2ban 自带代码的弃用提示，不影响功能。

**11. deploy 用户的密码文件是干什么的？**
sudo 已配置免密，此密码平时用不到，仅作 `su` 切换或云控制台救援登录的备用凭证。验证一切正常后删除即可。

**12. 之后想新增 SSH 登录用户？**
设置 `EXTRA_SSH_USERS="新用户名" ALLOW_NON_FRESH=1` 重跑；或直接编辑 `00-hardening.conf` 的 `AllowUsers` 行后 `systemctl restart ssh`。

---
