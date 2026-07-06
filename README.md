# VOLSB

> sing-box 服务端一键部署与管理脚本

```
  ██╗   ██╗ ██████╗ ██╗     ███████╗██████╗
  ██║   ██║██╔═══██╗██║     ██╔════╝██╔══██╗
  ██║   ██║██║   ██║██║     ███████╗██████╔╝
  ╚██╗ ██╔╝██║   ██║██║     ╚════██║██╔══██╗
   ╚████╔╝ ╚██████╔╝███████╗███████║██████╔╝
    ╚═══╝   ╚═════╝ ╚══════╝╚══════╝╚═════╝
```

[![Version](https://img.shields.io/badge/version-1.4.44-blue.svg)](https://github.com/chnnic/VOLSB)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![sing-box](https://img.shields.io/badge/sing--box-1.13.14-orange.svg)](https://github.com/SagerNet/sing-box)

---

## 简介

VOLSB 是一个功能完整的 **sing-box 服务端** 一键部署脚本，支持落地机和线路机（中转机）两种部署模式，安装后通过 `volsb` 命令进入管理界面。

---

## 功能特性

### 🎯 部署机（落地机）

| 功能 | 说明 |
|------|------|
| 一键安装 | 自动下载并固定 sing-box 1.13.14 后部署 |
| 多协议支持 | VLESS+Reality / Hysteria2 / VMess-WS / Trojan / ShadowTLS v3 / AnyTLS / Shadowsocks / TUIC |
| 证书复用 | Hysteria2 / Trojan / AnyTLS / TUIC 支持复用已有证书、自签证书或 Let's Encrypt 正式证书 |
| 多节点生成 | 每个协议支持同时生成 1-10 个节点（独立 UUID/密码） |
| 按节点出口 | 每个入站节点组可选择 VPS 直连、全部 SS 家宽、AI 分流 + SS 家宽，或 AI 分流 + VPS 直连 |
| UDP 分流 | 支持普通 TCP 走 SS 家宽、普通 UDP 走 VPS 直连，绕开家宽 UDP unknown |
| IPv6 支持 | 入站监听 IPv4/IPv6，分享链接会自动兼容 IPv6 地址格式 |
| AI 规则 | 内置 OpenAI / Claude / Gemini / Perplexity 等规则，兼容 `geosite:`、`domain:`、`full:`、`keyword:` |
| AnyTLS Reality | 输出分享链接和 sing-box 客户端 JSON，兼容不识别 Reality URI 的客户端 |
| 自动生成密钥 | Reality 密钥对、UUID、ShortID 全自动生成 |
| 自定义连接地址 | 自动检测公网 IP 或手动输入 IP/DDNS 域名 |
| 分享链接 | 自动生成标准分享链接，支持二维码输出 |
| 链接命名 | 分享链接名称自动追加端口号，方便区分多节点 |
| 节点展示 | 出口说明会归并到上一个节点块，避免误判下一个节点的出口 |
| 节点管理 | 可查看节点、删除节点或选中单个节点直接显示二维码 |
| 追加协议 | 可在不删除旧节点的情况下追加新协议 |
| 路由保留 | 追加节点时保留旧出站和旧分流规则，避免家宽兜底丢失 |
| 删除节点 | 可多选删除入站节点，并同步清理路由规则、分享链接和节点出口说明 |

### 🔗 线路机（中转机）

| 功能 | 说明 |
|------|------|
| 一键部署 | VLESS+Reality 入站 → Shadowsocks 出站 → 落地机 |
| SS 链接解析 | 支持直接粘贴 `ss://` 链接自动解析落地机信息 |
| SS 节点输出 | 可直接生成 Shadowsocks 入站 `ss://` 分享链接 |
| TUIC 节点输出 | 可直接生成 TUIC 入站分享链接 |
| 手动输入 | 支持手动填写落地机 IP、端口、密码、加密方式 |
| 连通性验证 | 自动验证转发链路，支持选择不同入站端口和多个 SS 出站逐个检测 |
| 一键安装命令 | 生成可直接在其他 VPS 运行的线路机安装命令 |

### ⚙️ 系统管理

| 功能 | 说明 |
|------|------|
| 服务控制 | 启动 / 停止 / 重启 / 查看状态 |
| 版本管理 | 一键升级 sing-box 核心 / 更新 VOLSB 脚本自身 |
| 返回逻辑 | 子菜单支持 `0` 或 `b` 返回上一级，协议选择保留 `0=全部协议`、使用 `b` 返回 |
| 端口重置 | 支持按节点单选/多选重置端口、密码/UUID，并同步更新分享链接和节点信息 |
| 端口池 | 同一轮部署/追加/重置会保留已分配随机端口，避免批量生成时撞端口 |
| Reality SNI 检测 | 集成 Reality-SNI-Check，可在落地机上检测 TLS1.3 / h2 / X25519 / 证书链并推荐 SNI |
| 流量统计 | Clash API 实时速率 + 按入站端口统计连接数 + 网卡累计流量兜底 |
| 时间同步 | 四级兜底强制同步系统时间（NTP/chrony/ntpdate/HTTP） |
| 卸载清理 | 完整移除 sing-box 及所有配置文件 |

### 🖥️ 系统兼容

| 初始化系统 | 发行版 |
|-----------|--------|
| **systemd** | Debian / Ubuntu / CentOS / RHEL / AlmaLinux / Rocky / Fedora / openSUSE / Arch |
| **OpenRC** | Alpine Linux |

---

## 快速开始

### 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chnnic/VOLSB/refs/heads/main/volsb.sh)
```

安装完成后，输入 `volsb` 进入管理界面。

### 直接执行命令

```bash
volsb                # 进入交互式管理界面
volsb install        # 全新安装
volsb add            # 追加协议（保留旧节点）
volsb update         # 升级 sing-box 核心版本
volsb self-update    # 更新 VOLSB 脚本自身
volsb start          # 启动服务
volsb stop           # 停止服务
volsb restart        # 重启服务
volsb status         # 查看运行状态
volsb info           # 查看节点信息和分享链接
volsb traffic        # 查看流量统计
volsb log            # 实时日志
volsb sync-time      # 强制同步系统时间
volsb verify         # 验证线路机转发连通性
volsb check-sni      # 检测 Reality dest/SNI 候选
volsb uninstall      # 完全卸载
```

---

## 管理界面

```
  ██╗   ██╗ ██████╗ ██╗     ███████╗██████╗
  ...
  v1.4.44  |  2026-07-01 00:00:00

  状态: ● 运行中
  版本: 1.13.14
  节点: 3 个入站 / 6 条链接
  ────────────────────────────────────────────
  📦 安装管理
   1) 全新安装 / 重新部署
   2) 追加新协议
   3) 更新 (脚本/sing-box)
   4) 卸载

  ⚙️  服务控制
   5) 启动    6) 停止    7) 重启    8) 查看状态

  📋 节点与配置
   9) 查看节点信息 / 删除节点 / 分享节点
  10) 重置端口 / 密码 / UUID
  11) 编辑配置文件

  📊 流量管理
  12) 查看流量统计
  13) 清空流量日志
  14) 实时日志

  🔍 诊断
  15) 验证线路机转发连通性
  16) 强制同步系统时间
  17) 检测 Reality SNI 候选
  ────────────────────────────────────────────
   0) 退出
```

---

## 协议说明

| # | 协议 | 传输 | 特点 |
|---|------|------|------|
| 1 | VLESS + XTLS-Reality | TCP | ★ 推荐，抗审查首选，无需域名或证书 |
| 2 | Hysteria2 | UDP | ★ 推荐，高速 UDP，弱网体验佳 |
| 3 | VMess + WebSocket | TCP/WS | 适合套 CDN 或 Nginx TLS 反代 |
| 4 | Trojan + TLS | TCP | 经典方案，客户端兼容性好 |
| 5 | ShadowTLS v3 + Shadowsocks | TCP | 流量伪装为真实 TLS 握手 |
| 6 | AnyTLS | TCP | 支持自签 / Let's Encrypt / Reality |
| 7 | Shadowsocks | TCP/UDP | 直接生成 `ss://` 分享链接 |
| 8 | TUIC | UDP | QUIC 协议，适合弱网 |

---

## Reality SNI 检测

VLESS-Reality / AnyTLS-Reality 选择 SNI 时，可先在落地机运行：

```bash
volsb check-sni              # 进入 Reality-SNI-Check 菜单
volsb check-sni -r jp        # 按地区推荐
volsb check-sni -c cdn,cloud # 指定分类检测
```

安装或追加 Reality 节点时，在 SNI 输入处也可以输入 `c` 临时运行检测器，检测结束后把推荐的 `dest/SNI` 粘贴回来。

检测器来自 [Reality-SNI-Check](https://github.com/chnnic/Reality-SNI-Check)，按需下载到 `/usr/local/lib/volsb/Reality-SNI-Check.sh`，只做标准 HTTPS 探测，不修改 sing-box 配置。

---

## 按节点出口与 AI 分流

部署机模式下，每个入站节点组都可以单独选择出口：

```text
 节点出口模式: VLESS-Reality
 1) 直连 VPS 出口
 2) 全部 → ss-home
 3) AI → ss-ai，其余 → ss-home
 4) AI → ss-ai，其余 → 直连 VPS 出口
 5) AI → ss-ai，TCP其余 → ss-home，UDP其余 → 直连 VPS 出口
```

如果需要一条链接一个出口策略，建议每次生成节点数量填 `1`，再通过菜单 **2) 追加新协议** 一条条生成。这样可以同时保留：

- 直连节点：所有流量走 VPS 本地出口
- 全转发节点：所有流量走 `ss-home`
- 分流节点：AI 流量走 `ss-ai`，其他流量走 `ss-home`
- AI 转发节点：AI 流量走 `ss-ai`，其他流量走 VPS 本地出口
- UDP 直连节点：AI 流量走 `ss-ai`，普通 TCP 走 `ss-home`，普通 UDP 走 VPS 本地出口
- 分流节点会自动添加 `action: sniff` 路由规则，用于识别 TLS/HTTP 目标域名并命中 AI 规则
- AnyTLS 可选择 Reality 模式，无需证书，并会生成 `pbk` / `sid` 分享参数和 sing-box 客户端 JSON
- Hysteria2 / Trojan / AnyTLS 证书模式支持复用已有证书、带 SAN 的自签证书或 Let's Encrypt 正式证书
- Let's Encrypt 未到续期时间时会复用 acme.sh 中已有证书，并安装 fullchain
- Let's Encrypt 申请前会放行 80/tcp；域名存在 AAAA 记录时会尝试 IPv6 standalone，避免 IPv6 域名验证连接被拒绝后误复用空证书
- AnyTLS 可先选择“复用已有证书”，再从本地或 acme.sh 证书列表中选择具体域名；证书列表支持按 `d` 删除旧证书
- 追加协议失败时不会写入空配置，也不会继续重启服务

`AI → ss-ai，其余 → ss-home` 会要求填写两个 Shadowsocks 链接：

```text
AI 日本家宽 SS 链接     -> 出站 tag: ss-ai
香港家宽默认出口 SS 链接 -> 出站 tag: ss-home
```

`AI → ss-ai，其余 → 直连 VPS 出口` 只需要填写 AI Shadowsocks 链接：

```text
AI 日本家宽 SS 链接     -> 出站 tag: ss-ai
其他流量               -> 出站 tag: direct
```

内置 AI 规则会自动转换为 sing-box 可用字段：

- `geosite:openai`、`geosite:anthropic` 兼容旧写法，会自动展开为域名规则
- `claude.ai`、`perplexity.ai`、`mistral.ai` 等 → `domain`
- 自动生成精简后的 `domain_suffix`
- 输入 `https://new.ai:443/path` 这类 URL 时会自动提取为 `new.ai`

追加自定义 AI 域名或规则时，可在安装交互中输入逗号分隔内容，例如：

```text
geosite:customai,https://new.ai/path,api.example.ai
```

也可以用环境变量：

```bash
VOLSB_AI_EXTRA="geosite:customai,https://new.ai/path,api.example.ai"
```

---

## 线路机部署

线路机（中转机）将客户端流量通过 VLESS+Reality 接入，再经由 Shadowsocks 转发至落地机。

```
客户端 ──VLESS+Reality──► 线路机 ──Shadowsocks──► 落地机 ──► 互联网
```

### 部署流程

1. 进入管理界面 → 选 **1) 全新安装**
2. 选择部署模式 → 选 **2) 线路机（中转机）**
3. 粘贴落地机 SS 链接，或手动输入落地机信息
4. 配置线路机入站（端口、SNI、节点数量）
5. 安装完成后通过 **15) 验证转发连通性** 确认链路正常

### 支持的 SS 链接格式

```bash
# SIP002 明文格式
ss://2022-blake3-aes-128-gcm:PASSWORD@host:port#备注

# 旧版 Base64 格式
ss://BASE64(method:password)@host:port#备注
```

粘贴时支持三种输入方式：
- 直接在选项提示处粘贴完整 `ss://` 链接
- 选 `1` 后粘贴链接
- 选 `2` 手动逐项填写

---

## 追加协议

选择菜单 **2) 追加新协议** 时，会检测已有节点并询问：

```
检测到已有 2 个入站节点:
  - vless 端口:34305 [vless-reality-in]
  - hysteria2 端口:21831 [hysteria2-in]

选项:
 1) 保留旧节点，追加新节点（推荐）
 2) 清除旧节点，只保留新节点
```

选择保留旧节点后，新旧节点共存于同一配置文件中。
执行完成后会自动刷新节点总览，直接显示新生成的分享链接。

---

## 时间同步

`2022-blake3-aes-128-gcm` 等现代加密方式对时间精度要求严格，**两端时间差超过 30 秒将导致连接静默失败**。

```bash
volsb sync-time
# 或菜单 16) 强制同步系统时间
```

同步优先级：
1. `timedatectl`（systemd 系统）
2. `chronyc makestep`
3. `ntpdate pool.ntp.org`
4. HTTP 时间头（终极兜底，无需任何 NTP 工具）

连通性验证时也会自动检测时间偏差并给出提示。

---

## 环境变量（自动化部署）

支持通过环境变量跳过交互，适合 CI/CD 或批量部署场景：

```bash
# VOLSB_MODE: 1=部署机, 2=线路机
# VOLSB_PROTO: 1=VLESS, 2=HY2, 0=全部
VOLSB_MODE=1 \
VOLSB_PROTO="1 2" \
VOLSB_IP=1.2.3.4 \
VOLSB_PORT=443 \
VOLSB_SNI=www.cloudflare.com \
bash volsb.sh install
```

分流相关环境变量：

```bash
# AI -> ss-ai，其余 -> ss-home
VOLSB_ROUTE_MODE=ai-ss \
VOLSB_AI_SS='ss://...' \
VOLSB_HOME_SS='ss://...' \
VOLSB_AI_EXTRA='https://new.ai/path,geosite:customai' \
bash volsb.sh install
```

如果只想让 AI 走 SS，其他流量仍走 VPS 直连：

```bash
# AI -> ss-ai，其余 -> direct
VOLSB_ROUTE_MODE=ai-direct \
VOLSB_AI_SS='ss://...' \
VOLSB_AI_EXTRA='https://new.ai/path,geosite:customai' \
bash volsb.sh install
```

`VOLSB_AI_SPEC` 可用于完全覆盖内置 AI 规则；`VOLSB_AI_EXTRA` / `VOLSB_AI_DOMAINS` / `VOLSB_AI_RULES` 用于在默认规则基础上追加。

---

## 文件路径

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/sing-box` | sing-box 主程序 |
| `/usr/local/bin/volsb` | volsb 快捷命令 |
| `/etc/sing-box/config.json` | sing-box 配置文件 |
| `/etc/sing-box/nodes.info` | 节点明文信息 |
| `/etc/sing-box/links.txt` | 所有分享链接 |
| `/etc/sing-box/certs/` | TLS 证书目录 |
| `/var/log/sing-box/sing-box.log` | 运行日志 |
| `/var/lib/sing-box/` | sing-box 数据目录 |

---

## 注意事项

- **需要 root 权限**运行，建议 `sudo -i` 后执行
- sing-box 最低版本要求 **1.12.0**（部分 DNS 配置格式已更新）
- sing-box 1.12+ 已移除旧版 `geosite` 数据库，脚本会把内置 AI 规则写为 `domain` / `domain_suffix`
- AnyTLS 需要客户端核心同样支持 sing-box 1.12+，AnyTLS + Reality 需要客户端支持 Reality TLS 参数
- Hysteria2 和 Trojan 使用自签证书时，客户端需开启"跳过证书验证"
- `2022-blake3-*` 系列加密的密码必须是 **base64 编码的固定字节随机数**，不可使用普通字符串
- 线路机与落地机时间差必须 **小于 30 秒**

---

## 许可证

MIT License

---

## 相关项目

- [sing-box](https://github.com/SagerNet/sing-box) — 通用代理平台
- [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust) — Shadowsocks Rust 实现
