# VPS Initialization Script

一键初始化全新 Ubuntu / Debian VPS 的 Bash 脚本，自动完成系统安全加固、资源优化、Docker 环境安装以及 Portainer 部署。适用于个人开发服务器、小型生产环境的基础配置。

## ✨ 功能特性

- ✅ 系统更新与基础工具安装（`vim`、`git`、`wget`、`curl` 等）
- ✅ 自动创建 Swap（物理内存 < 4GB 时，默认 2GB）
- ✅ SSH 安全加固（禁止密码登录、仅允许公钥认证、创建 sudo 用户）
- ✅ UFW 防火墙 + Fail2ban 入侵防御
- ✅ 内核参数优化（BBR、文件描述符、TCP 优化）
- ✅ 安装 Docker CE 与 Docker Compose Plugin（v2）
- ✅ 配置 Docker 日志限制（防止磁盘爆满）与可选 IPv6
- ✅ 部署 Portainer CE，默认仅监听本机 `127.0.0.1`，自动生成随机管理员密码
- ✅ 启用无人值守安全更新
- ✅ 输出初始化摘要，包含登录信息与访问方式

## 🚀 快速开始

> **注意**：请务必在运行脚本前准备好你的 SSH 公钥，否则脚本会跳过 SSH 加固，仅以 root 密码登录（不安全）。

在全新安装的 Ubuntu 或 Debian VPS 上，以 root 用户执行：

```bash
curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库/main/vps_init.sh | \
  SSH_PUBLIC_KEY="粘贴你的公钥" \
  NEW_USER="deploy" \
  PORTAINER_BIND="127.0.0.1" \
  bash
```

等待脚本执行完毕（约 5～10 分钟），即可获得一个加固且配置好 Docker 环境的基础服务器。

## 🔧 环境变量说明

| 变量名 | 默认值 | 必填 | 说明 |
|--------|--------|------|------|
| `SSH_PUBLIC_KEY` | 无 | **是** | 你的 SSH 公钥，用于创建免密登录用户和 root 紧急恢复 |
| `NEW_USER` | `deploy` | 否 | 新建的 sudo 用户名 |
| `PORTAINER_PASSWORD` | 随机生成 | 否 | Portainer 管理员密码，留空则自动生成 32 位随机密码 |
| `PORTAINER_BIND` | `127.0.0.1` | 否 | Portainer 监听地址。`127.0.0.1` 仅本机（推荐），`0.0.0.0` 公网可访问 |
| `SSH_PORT` | `22` | 否 | SSH 端口（仅用于防火墙放行，不修改 sshd 实际端口） |
| `TIMEZONE` | `Asia/Shanghai` | 否 | 系统时区 |
| `CREATE_SWAP` | `true` | 否 | 是否创建 Swap |
| `SWAP_SIZE_MB` | `2048` | 否 | Swap 大小（MB） |
| `ENABLE_IPV6` | `true` | 否 | Docker 是否启用 IPv6 |
| `UFW_ALLOW_PORTAINER_IP` | 无 | 否 | 当 `PORTAINER_BIND=0.0.0.0` 时，可选限制来源 IP |

## 🔑 如何生成 SSH 公钥

如果你还没有 SSH 密钥对，请根据你的操作系统执行以下命令：

### Windows（PowerShell）

1. 打开 PowerShell。
2. 生成密钥对：

```powershell
ssh-keygen -t ed25519 -C "你的邮箱或备注"
```

按提示回车（可设置密码短语，或直接回车留空）。  
3. 查看公钥内容：

```powershell
Get-Content ~/.ssh/id_ed25519.pub
```

### macOS / Linux

1. 打开终端。
2. 生成密钥对：

```bash
ssh-keygen -t ed25519 -C "你的邮箱或备注"
```

按提示回车。  
3. 查看公钥内容：

```bash
cat ~/.ssh/id_ed25519.pub
```

复制输出的整行内容（以 `ssh-ed25519` 开头），作为 `SSH_PUBLIC_KEY` 的值传入脚本。

## ✅ 运行后验证

脚本执行完毕后，你可以通过以下命令检查各项服务是否正常：

```bash
docker --version          # 查看 Docker 版本
docker compose version    # 查看 Docker Compose 版本
docker ps                 # 查看正在运行的容器（应包含 portainer）
ss -lntp | grep 9443      # 查看 Portainer 监听端口
ufw status verbose        # 查看防火墙规则
```

## 🌐 如何访问 Portainer

### 方式一：SSH 隧道（临时使用）

如果 Portainer 仅监听 `127.0.0.1`，你可以在本地终端创建 SSH 隧道：

```bash
ssh -N -L 9443:localhost:9443 deploy@你的服务器IP
```

然后浏览器打开 `https://localhost:9443`，使用脚本输出的用户名 `admin` 和密码登录。

### 方式二：Nginx Proxy Manager 反向代理（推荐）

为了通过域名安全访问 Portainer，推荐在服务器上安装 **Nginx Proxy Manager (NPM)** 并配置反向代理。

#### 1. 安装 NPM

```bash
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'  
      - '81:81'  
      - '443:443' 
    volumes:
      - /home/dockers/npm/data:/data 
      - /home/dockers/npm/letsencrypt:/etc/letsencrypt  
```

#### 2. 配置反向代理

1. 将你的域名（例如 `portainer.example.com`）解析到服务器 IP。
2. 浏览器打开 `http://服务器IP:81`，使用默认账号 `admin@example.com` / `changeme` 登录，并修改密码。
3. 点击 **Proxy Hosts** → **Add Proxy Host**：
   - **Domain Names**: `portainer.example.com`
   - **Scheme**: `https`
   - **Forward Hostname/IP**: `127.0.0.1`
   - **Forward Port**: `9443`
   - 勾选 `Block Common Exploits` 和 `Websockets Support`
4. 切换到 **SSL** 选项卡，选择 “Request a new SSL Certificate”，填写邮箱并同意 Let's Encrypt 条款，保存。
5. 等待证书签发后，即可通过 `https://portainer.example.com` 安全访问。

> **安全建议**：在 NPM 的 Access Lists 中添加 IP 白名单，仅允许你的 IP 访问 Portainer。

## 🔒 安全建议

- **始终使用 SSH 密钥登录**，禁用密码登录。
- **不要将 Portainer 直接暴露公网**（即不要设置 `PORTAINER_BIND=0.0.0.0`），而是通过 NPM 反向代理。
- **定期更新系统与 Docker 镜像**：`apt update && apt upgrade`、`docker compose pull`。
- **备份重要数据**，特别是 `/opt/portainer` 的数据卷和 `/opt/npm` 的配置。
- **监控服务器资源**，可使用 `htop` 或 Portainer 自带的监控功能。

## 📁 文件结构

```
.
├── vps_init.sh    # 主初始化脚本
└── README.md      # 本文档
```

## ❓ 常见问题

### 1. 脚本运行失败，提示不支持当前系统？
请确认你的系统是 **Ubuntu 20.04+** 或 **Debian 11+**，且以 root 用户运行。

### 2. 没有提供 SSH 公钥，脚本会怎样？
脚本会跳过新建用户和 SSH 加固，你仍只能通过 root 密码登录。**强烈建议提供公钥**。

### 3. Portainer 密码在哪里查看？
密码保存在服务器的 `/root/portainer_initial_password.txt` 文件中，同时脚本运行结束时会打印在终端。

### 4. 如何修改 Portainer 密码？
登录 Portainer 后，进入 **Settings** → **Users**，修改 `admin` 用户的密码。

### 5. 脚本会修改 SSH 端口吗？
不会。脚本仅用 `SSH_PORT` 变量来配置防火墙放行，不会修改 `sshd_config`。如需修改，请自行编辑 `/etc/ssh/sshd_config` 并重启 SSH 服务。

## 📄 许可证

MIT License
