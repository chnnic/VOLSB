#!/usr/bin/env bash
#
# sing-box 一键安装管理脚本
# 支持: VLESS-Reality / Hysteria2 / VMess-WS / Trojan
# 系统: Debian/Ubuntu/CentOS/RHEL/Alma/Rocky/Fedora
# Author: claude-generated
# Version: 1.0.0
#

set -o pipefail

# ============ 颜色定义 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ============ 全局变量 ============
SB_BIN="/usr/local/bin/sing-box"
SB_CONFIG_DIR="/etc/sing-box"
SB_CONFIG="${SB_CONFIG_DIR}/config.json"
SB_LOG_DIR="/var/log/sing-box"
SB_LOG="${SB_LOG_DIR}/sing-box.log"
SB_SERVICE="/etc/systemd/system/sing-box.service"
SB_INFO="${SB_CONFIG_DIR}/nodes.txt"

# ============ 工具函数 ============
msg()  { echo -e "${GREEN}[INFO]${PLAIN} $*"; }
warn() { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
err()  { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; }
ask()  { echo -en "${CYAN}[?]${PLAIN} $*"; }

die() { err "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "请使用 root 用户运行此脚本 (sudo -i)"
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID=$ID
        OS_VER=$VERSION_ID
    else
        die "无法识别系统类型"
    fi

    case "$OS_ID" in
        debian|ubuntu)
            PKG_MGR="apt"
            PKG_UPDATE="apt update -y"
            PKG_INSTALL="apt install -y"
            ;;
        centos|rhel|almalinux|rocky|fedora)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MGR="dnf"
                PKG_UPDATE="dnf makecache"
                PKG_INSTALL="dnf install -y"
            else
                PKG_MGR="yum"
                PKG_UPDATE="yum makecache"
                PKG_INSTALL="yum install -y"
            fi
            ;;
        *)
            die "不支持的系统: $OS_ID"
            ;;
    esac
    msg "检测到系统: $OS_ID $OS_VER (包管理器: $PKG_MGR)"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        armv7l)         ARCH="armv7" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
    msg "检测到架构: $ARCH"
}

install_deps() {
    msg "安装必要依赖..."
    $PKG_UPDATE >/dev/null 2>&1 || true
    $PKG_INSTALL curl wget tar jq openssl qrencode ca-certificates >/dev/null 2>&1 || \
        warn "部分依赖安装失败,继续执行..."
}

get_public_ip() {
    local ip
    ip=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null) || \
    ip=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null) || \
    ip=$(curl -s4 --max-time 5 https://ipinfo.io/ip 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s6 --max-time 5 https://api6.ipify.org 2>/dev/null)
    echo "$ip"
}

random_port() {
    local port
    while :; do
        port=$((RANDOM % 50000 + 10000))
        if ! ss -tuln 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

# ============ sing-box 核心安装 ============
get_latest_version() {
    local v
    v=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')
    [[ -z "$v" || "$v" == "null" ]] && die "无法获取 sing-box 最新版本号,请检查网络"
    echo "$v"
}

download_singbox() {
    local version="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    local file="sing-box-${version}-linux-${ARCH}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${file}"

    msg "下载 sing-box v${version} (${ARCH})..."
    if ! curl -fsSL -o "${tmpdir}/${file}" "$url"; then
        rm -rf "$tmpdir"
        die "下载失败: $url"
    fi

    tar -xzf "${tmpdir}/${file}" -C "$tmpdir" || die "解压失败"
    install -m 755 "${tmpdir}/sing-box-${version}-linux-${ARCH}/sing-box" "$SB_BIN" \
        || die "安装二进制文件失败"
    rm -rf "$tmpdir"

    msg "sing-box 已安装到 $SB_BIN"
    "$SB_BIN" version
}

create_service() {
    cat > "$SB_SERVICE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=${SB_BIN} -D /var/lib/sing-box -C ${SB_CONFIG_DIR} run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /var/lib/sing-box "$SB_CONFIG_DIR" "$SB_LOG_DIR"
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
}

# ============ 协议配置生成 ============
gen_reality_keys() {
    "$SB_BIN" generate reality-keypair
}

gen_uuid() {
    "$SB_BIN" generate uuid
}

gen_short_id() {
    openssl rand -hex 8
}

# 生成 VLESS Reality 入站
config_vless_reality() {
    local port="$1" uuid="$2" private_key="$3" short_id="$4" sni="$5"
    cat <<EOF
{
  "type": "vless",
  "tag": "vless-reality-in",
  "listen": "::",
  "listen_port": ${port},
  "users": [
    {
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "${sni}",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "${sni}",
        "server_port": 443
      },
      "private_key": "${private_key}",
      "short_id": ["${short_id}"]
    }
  }
}
EOF
}

# Hysteria2 入站
config_hysteria2() {
    local port="$1" password="$2" cert="$3" key="$4"
    cat <<EOF
{
  "type": "hysteria2",
  "tag": "hy2-in",
  "listen": "::",
  "listen_port": ${port},
  "users": [
    {
      "password": "${password}"
    }
  ],
  "tls": {
    "enabled": true,
    "alpn": ["h3"],
    "certificate_path": "${cert}",
    "key_path": "${key}"
  }
}
EOF
}

# VMess + WS 入站(适合套CDN)
config_vmess_ws() {
    local port="$1" uuid="$2" wspath="$3"
    cat <<EOF
{
  "type": "vmess",
  "tag": "vmess-ws-in",
  "listen": "::",
  "listen_port": ${port},
  "users": [
    {
      "uuid": "${uuid}",
      "alterId": 0
    }
  ],
  "transport": {
    "type": "ws",
    "path": "${wspath}"
  }
}
EOF
}

# Trojan 入站
config_trojan() {
    local port="$1" password="$2" cert="$3" key="$4"
    cat <<EOF
{
  "type": "trojan",
  "tag": "trojan-in",
  "listen": "::",
  "listen_port": ${port},
  "users": [
    {
      "password": "${password}"
    }
  ],
  "tls": {
    "enabled": true,
    "certificate_path": "${cert}",
    "key_path": "${key}"
  }
}
EOF
}

# ============ 自签证书 ============
gen_self_signed_cert() {
    local domain="${1:-bing.com}"
    local cert_dir="${SB_CONFIG_DIR}/cert"
    mkdir -p "$cert_dir"
    local cert="${cert_dir}/${domain}.crt"
    local key="${cert_dir}/${domain}.key"

    if [[ ! -f "$cert" || ! -f "$key" ]]; then
        msg "生成自签证书 ($domain)..."
        openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null
        openssl req -new -x509 -days 36500 -key "$key" -out "$cert" \
            -subj "/CN=${domain}" 2>/dev/null
    fi
    echo "$cert|$key"
}

# ============ 组装完整配置 ============
build_config() {
    local inbounds_json="$1"
    cat > "$SB_CONFIG" <<EOF
{
  "log": {
    "level": "info",
    "output": "${SB_LOG}",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "tag": "google", "address": "tls://8.8.8.8" },
      { "tag": "cloudflare", "address": "tls://1.1.1.1" }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": ${inbounds_json},
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "direct" }
    ]
  }
}
EOF
    # 校验配置
    if ! "$SB_BIN" check -c "$SB_CONFIG" 2>/dev/null; then
        err "配置文件校验失败,请查看日志"
        "$SB_BIN" check -c "$SB_CONFIG"
        return 1
    fi
    msg "配置已写入 $SB_CONFIG"
}

# ============ 交互式协议选择 ============
choose_protocols() {
    echo ""
    echo "==================================="
    echo "  请选择要部署的协议(可多选)"
    echo "==================================="
    echo "  1) VLESS + Reality  (推荐,抗审查)"
    echo "  2) Hysteria2        (UDP高速)"
    echo "  3) VMess + WS       (可套CDN)"
    echo "  4) Trojan + TLS     (经典)"
    echo "  0) 全部"
    echo "==================================="
    ask "请输入序号(空格分隔,如 1 2): "
    read -r choices
    [[ -z "$choices" ]] && choices="1"
    [[ "$choices" =~ 0 ]] && choices="1 2 3 4"
    SELECTED="$choices"
}

build_selected_inbounds() {
    local inbounds=()
    local ip
    ip=$(get_public_ip)
    [[ -z "$ip" ]] && ip="YOUR_SERVER_IP"

    : > "$SB_INFO"
    echo "===== sing-box 节点信息 =====" >> "$SB_INFO"
    echo "服务器: $ip" >> "$SB_INFO"
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')" >> "$SB_INFO"
    echo "" >> "$SB_INFO"

    for c in $SELECTED; do
        case "$c" in
            1)
                local port uuid keys priv pub sid sni
                port=$(random_port)
                uuid=$(gen_uuid)
                keys=$(gen_reality_keys)
                priv=$(echo "$keys" | awk '/PrivateKey/ {print $2}')
                pub=$(echo "$keys" | awk '/PublicKey/ {print $2}')
                sid=$(gen_short_id)
                sni="www.cloudflare.com"

                inbounds+=("$(config_vless_reality "$port" "$uuid" "$priv" "$sid" "$sni")")

                local link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp#VLESS-Reality"
                {
                    echo "[VLESS + Reality]"
                    echo "  地址 : $ip"
                    echo "  端口 : $port"
                    echo "  UUID : $uuid"
                    echo "  Flow : xtls-rprx-vision"
                    echo "  SNI  : $sni"
                    echo "  PBK  : $pub"
                    echo "  SID  : $sid"
                    echo "  Link : $link"
                    echo ""
                } >> "$SB_INFO"
                ;;
            2)
                local port password cert_pair cert key
                port=$(random_port)
                password=$(openssl rand -base64 16)
                cert_pair=$(gen_self_signed_cert "bing.com")
                cert=${cert_pair%|*}
                key=${cert_pair#*|}

                inbounds+=("$(config_hysteria2 "$port" "$password" "$cert" "$key")")

                local link="hysteria2://${password}@${ip}:${port}/?sni=bing.com&insecure=1#Hysteria2"
                {
                    echo "[Hysteria2]"
                    echo "  地址 : $ip"
                    echo "  端口 : $port"
                    echo "  密码 : $password"
                    echo "  SNI  : bing.com (自签)"
                    echo "  跳过证书校验: 是"
                    echo "  Link : $link"
                    echo ""
                } >> "$SB_INFO"
                ;;
            3)
                local port uuid wspath
                port=$(random_port)
                uuid=$(gen_uuid)
                wspath="/$(openssl rand -hex 4)"

                inbounds+=("$(config_vmess_ws "$port" "$uuid" "$wspath")")

                local vmess_json b64 link
                vmess_json=$(cat <<JSON
{"v":"2","ps":"VMess-WS","add":"${ip}","port":"${port}","id":"${uuid}","aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"${wspath}","tls":""}
JSON
)
                b64=$(echo -n "$vmess_json" | base64 -w0)
                link="vmess://${b64}"
                {
                    echo "[VMess + WS]"
                    echo "  地址 : $ip"
                    echo "  端口 : $port"
                    echo "  UUID : $uuid"
                    echo "  路径 : $wspath"
                    echo "  Link : $link"
                    echo ""
                } >> "$SB_INFO"
                ;;
            4)
                local port password cert_pair cert key
                port=$(random_port)
                password=$(openssl rand -base64 16)
                cert_pair=$(gen_self_signed_cert "bing.com")
                cert=${cert_pair%|*}
                key=${cert_pair#*|}

                inbounds+=("$(config_trojan "$port" "$password" "$cert" "$key")")

                local link="trojan://${password}@${ip}:${port}?sni=bing.com&allowInsecure=1#Trojan"
                {
                    echo "[Trojan]"
                    echo "  地址 : $ip"
                    echo "  端口 : $port"
                    echo "  密码 : $password"
                    echo "  SNI  : bing.com (自签)"
                    echo "  Link : $link"
                    echo ""
                } >> "$SB_INFO"
                ;;
            *) warn "忽略未知选项: $c" ;;
        esac
    done

    [[ ${#inbounds[@]} -eq 0 ]] && die "未选择任何协议"

    # 用 jq 合成 JSON 数组,避免逗号问题
    local joined
    joined=$(printf '%s\n' "${inbounds[@]}" | jq -s '.')
    echo "$joined"
}

# ============ 防火墙处理 ============
open_firewall_ports() {
    local ports
    ports=$(jq -r '.inbounds[].listen_port' "$SB_CONFIG" 2>/dev/null)
    for port in $ports; do
        if command -v ufw >/dev/null 2>&1; then
            ufw allow "$port" >/dev/null 2>&1 || true
        fi
        if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    done
    msg "已尝试在 ufw/firewalld 上放行端口"
}

# ============ 主功能 ============
do_install() {
    require_root
    detect_os
    detect_arch
    install_deps

    if [[ -x "$SB_BIN" ]]; then
        ask "检测到 sing-box 已安装,是否覆盖安装? [y/N]: "
        read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || { msg "已取消"; return; }
    fi

    local ver
    ver=$(get_latest_version)
    download_singbox "$ver"
    create_service

    choose_protocols
    local inbounds_json
    inbounds_json=$(build_selected_inbounds)
    build_config "$inbounds_json" || die "构建配置失败"
    open_firewall_ports

    systemctl restart sing-box
    sleep 2

    if systemctl is-active --quiet sing-box; then
        msg "sing-box 启动成功 ✔"
    else
        err "sing-box 启动失败,查看: journalctl -u sing-box -n 50"
        return 1
    fi

    show_nodes
}

do_uninstall() {
    require_root
    ask "确认卸载 sing-box 及全部配置? [y/N]: "
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { msg "已取消"; return; }

    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f "$SB_BIN" "$SB_SERVICE"
    rm -rf "$SB_CONFIG_DIR" "$SB_LOG_DIR" /var/lib/sing-box
    systemctl daemon-reload
    msg "已完全卸载"
}

do_update() {
    require_root
    [[ -x "$SB_BIN" ]] || die "尚未安装 sing-box"
    detect_arch
    install_deps

    local cur new
    cur=$("$SB_BIN" version | head -1 | awk '{print $3}')
    new=$(get_latest_version)
    if [[ "$cur" == "$new" ]]; then
        msg "已是最新版本: v$cur"
        return
    fi
    msg "升级: v$cur -> v$new"
    download_singbox "$new"
    systemctl restart sing-box
    msg "升级完成"
}

show_nodes() {
    if [[ ! -f "$SB_INFO" ]]; then
        warn "未找到节点信息文件"
        return
    fi
    echo ""
    cat "$SB_INFO"
    echo ""
    msg "节点信息已保存到: $SB_INFO"
}

show_status() {
    if [[ ! -x "$SB_BIN" ]]; then
        warn "sing-box 未安装"
        return
    fi
    echo ""
    "$SB_BIN" version
    echo ""
    systemctl status sing-box --no-pager -l | head -20
}

do_restart() { require_root; systemctl restart sing-box && msg "已重启"; }
do_stop()    { require_root; systemctl stop sing-box && msg "已停止"; }
do_start()   { require_root; systemctl start sing-box && msg "已启动"; }

show_log() {
    [[ -f "$SB_LOG" ]] && tail -n 50 "$SB_LOG" || journalctl -u sing-box -n 50 --no-pager
}

edit_config() {
    require_root
    ${EDITOR:-vi} "$SB_CONFIG"
    if "$SB_BIN" check -c "$SB_CONFIG"; then
        systemctl restart sing-box
        msg "配置已更新并重启"
    else
        err "配置校验失败,未重启服务"
    fi
}

# ============ 菜单 ============
show_menu() {
    clear
    echo -e "${CYAN}"
    cat <<'EOF'
  ╔════════════════════════════════════════╗
  ║      sing-box 一键管理脚本             ║
  ║      Version: 1.0.0                    ║
  ╚════════════════════════════════════════╝
EOF
    echo -e "${PLAIN}"
    echo "  1) 安装 sing-box"
    echo "  2) 卸载 sing-box"
    echo "  3) 更新 sing-box 版本"
    echo "  ─────────────────"
    echo "  4) 启动服务"
    echo "  5) 停止服务"
    echo "  6) 重启服务"
    echo "  7) 查看状态"
    echo "  ─────────────────"
    echo "  8) 查看节点信息"
    echo "  9) 查看日志"
    echo " 10) 编辑配置文件"
    echo "  ─────────────────"
    echo "  0) 退出"
    echo ""
    ask "请选择 [0-10]: "
    read -r opt
    case "$opt" in
        1)  do_install ;;
        2)  do_uninstall ;;
        3)  do_update ;;
        4)  do_start ;;
        5)  do_stop ;;
        6)  do_restart ;;
        7)  show_status ;;
        8)  show_nodes ;;
        9)  show_log ;;
        10) edit_config ;;
        0)  exit 0 ;;
        *)  warn "无效选项" ;;
    esac
    echo ""
    ask "按回车键继续..."
    read -r
    show_menu
}

# ============ 入口 ============
main() {
    case "${1:-}" in
        install)   do_install ;;
        uninstall) do_uninstall ;;
        update)    do_update ;;
        start)     do_start ;;
        stop)      do_stop ;;
        restart)   do_restart ;;
        status)    show_status ;;
        log|logs)  show_log ;;
        info|node) show_nodes ;;
        "")        show_menu ;;
        *)
            echo "用法: $0 [install|uninstall|update|start|stop|restart|status|log|info]"
            echo "无参数则进入交互菜单"
            ;;
    esac
}

main "$@"
