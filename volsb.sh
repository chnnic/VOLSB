#!/usr/bin/env bash
# =============================================================================
#   sing-box 服务端一键部署管理脚本
#   支持协议: VLESS-Reality / Hysteria2 / VMess-WS / Trojan-TLS / ShadowTLS v3
#   支持系统: Debian / Ubuntu / CentOS / RHEL / Alma / Rocky /
#             Fedora / openSUSE / Arch Linux
#   Version : 2.0.0
# =============================================================================

set -euo pipefail

# ======================== 颜色 / 输出工具 ========================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
step()  { echo -e "\n${BLUE}${BOLD}──── $* ────${NC}"; }
ask()   { echo -en "${CYAN}[?]${NC} $*"; }
die()   { err "$*"; exit 1; }
hr()    { echo -e "${BLUE}$(printf '─%.0s' {1..50})${NC}"; }

# ======================== 全局路径 ========================
SB_BIN="/usr/local/bin/sing-box"
SB_CONF_DIR="/etc/sing-box"
SB_CONFIG="${SB_CONF_DIR}/config.json"
SB_CERT_DIR="${SB_CONF_DIR}/certs"
SB_INFO_FILE="${SB_CONF_DIR}/nodes.info"
SB_LOG_DIR="/var/log/sing-box"
SB_LOG="${SB_LOG_DIR}/sing-box.log"
SB_DATA_DIR="/var/lib/sing-box"
SB_SERVICE="/etc/systemd/system/sing-box.service"

# ======================== 系统检测 ========================
require_root() {
    [[ $EUID -eq 0 ]] || die "请用 root 用户执行 (sudo -i 后再运行)"
}

detect_os() {
    [[ -f /etc/os-release ]] || die "无法识别操作系统"
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-0}" # from os-release
    OS_NAME="${PRETTY_NAME:-$OS_ID}"

    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop)
            PKG_UPDATE="apt-get update -y -qq"
            PKG_INSTALL="apt-get install -y -qq"
            PKGS="curl wget tar jq openssl ca-certificates qrencode"
            ;;
        centos|rhel|almalinux|rocky)
            if command -v dnf &>/dev/null; then
                PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q"
            else
                PKG_UPDATE="yum makecache -q"; PKG_INSTALL="yum install -y -q"
            fi
            PKGS="curl wget tar jq openssl ca-certificates qrencode"
            ;;
        fedora)
            PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q"
            PKGS="curl wget tar jq openssl ca-certificates qrencode"
            ;;
        opensuse*|sles)
            PKG_UPDATE="zypper refresh -q"; PKG_INSTALL="zypper install -y -q"
            PKGS="curl wget tar jq libopenssl1_1 ca-certificates qrencode"
            ;;
        arch|manjaro|endeavouros)
            PKG_UPDATE="pacman -Sy --noconfirm"; PKG_INSTALL="pacman -S --noconfirm --needed"
            PKGS="curl wget tar jq openssl ca-certificates qrencode"
            ;;
        *)
            die "不支持的发行版: $OS_ID"
            ;;
    esac
    info "检测到系统: $OS_NAME"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv7)  ARCH="armv7" ;;
        s390x)         ARCH="s390x" ;;
        *) die "不支持的 CPU 架构: $(uname -m)" ;;
    esac
    info "CPU 架构: $ARCH"
}

install_deps() {
    step "安装依赖"
    eval "$PKG_UPDATE" 2>/dev/null | tail -1 || warn "包列表更新失败,继续..."
    eval "$PKG_INSTALL $PKGS" 2>/dev/null || warn "部分依赖安装失败,继续..."
}

# ======================== sing-box 安装 ========================
get_latest_version() {
    local ver
    ver=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    [[ -n "$ver" ]] || die "获取最新版本失败,请检查网络"
    echo "$ver"
}

install_singbox_binary() {
    local ver="$1"
    local tmpdir; tmpdir=$(mktemp -d)
    local pkg="sing-box-${ver}-linux-${ARCH}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg}"

    info "下载 sing-box v${ver} ..."
    if ! curl -fsSL --max-time 120 -o "${tmpdir}/${pkg}" "$url"; then
        rm -rf "$tmpdir"; die "下载失败: $url"
    fi
    tar -xzf "${tmpdir}/${pkg}" -C "$tmpdir" 2>/dev/null || die "解压失败"
    install -m 755 "${tmpdir}/sing-box-${ver}-linux-${ARCH}/sing-box" "$SB_BIN"
    rm -rf "$tmpdir"
    info "安装完成: $("$SB_BIN" version | head -1)"
}

setup_directories() {
    mkdir -p "$SB_CONF_DIR" "$SB_CERT_DIR" "$SB_LOG_DIR" "$SB_DATA_DIR"
    chmod 700 "$SB_CERT_DIR"
}

install_service() {
    cat > "$SB_SERVICE" <<'UNIT'
[Unit]
Description=sing-box proxy server
Documentation=https://sing-box.sagernet.org
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable sing-box &>/dev/null
    info "systemd 服务已注册"
}

# ======================== 工具函数 ========================
get_public_ip() {
    local ip=""
    for api in "https://api.ipify.org" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
        ip=$(curl -fsSL --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]') && [[ -n "$ip" ]] && break
    done
    [[ -z "$ip" ]] && ip=$(curl -fsSL --max-time 5 "https://api6.ipify.org" 2>/dev/null | tr -d '[:space:]')
    echo "${ip:-<YOUR_SERVER_IP>}"
}

random_port() {
    local port
    while :; do
        port=$(( RANDOM % 45000 + 10000 ))
        ss -tuln 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
    done
}

gen_uuid()     { "$SB_BIN" generate uuid; }
gen_rand_str() { openssl rand -base64 32 | tr -d '+/=' | head -c "${1:-24}"; }
gen_rand_hex() { openssl rand -hex "${1:-8}"; }

gen_self_cert() {
    local cn="${1:-bing.com}"
    local crt="${SB_CERT_DIR}/${cn}.crt"
    local key="${SB_CERT_DIR}/${cn}.key"
    if [[ ! -f "$crt" ]]; then
        openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null
        openssl req -new -x509 -days 36500 -key "$key" -out "$crt" \
            -subj "/CN=${cn}" 2>/dev/null
        chmod 600 "$key"
    fi
    echo "${crt}:${key}"
}

open_ports() {
    local port="$1" proto="${2:-tcp}"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "${port}/${proto}" &>/dev/null || true
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/${proto}" &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
    fi
}

print_qr() {
    command -v qrencode &>/dev/null && echo "$1" | qrencode -t ANSIUTF8 2>/dev/null || true
}

# ======================== 协议配置函数 ========================
# 每个函数读取用户输入,将 JSON 片段写入 INBOUND_FRAGMENT 变量
# ShadowTLS 写入两个片段,以 ::SPLIT:: 分隔

configure_vless_reality() {
    step "VLESS + XTLS-Reality 参数配置"
    local port uuid sni

    ask "监听端口 (回车随机): "; read -r port
    [[ -z "$port" ]] && port=$(random_port)

    echo ""
    echo "  推荐 SNI: www.cloudflare.com / www.microsoft.com / www.amazon.com"
    ask "伪装 SNI [默认 www.cloudflare.com]: "; read -r sni
    [[ -z "$sni" ]] && sni="www.cloudflare.com"

    uuid=$(gen_uuid)
    local keypair; keypair=$("$SB_BIN" generate reality-keypair)
    local priv_key; priv_key=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
    local pub_key;  pub_key=$(echo  "$keypair" | awk '/PublicKey/{print $2}')
    local short_id; short_id=$(gen_rand_hex 8)

    INBOUND_FRAGMENT=$(cat <<JSON
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [{ "uuid": "${uuid}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${sni}", "server_port": 443 },
          "private_key": "${priv_key}",
          "short_id": ["${short_id}"]
        }
      }
    }
JSON
)
    open_ports "$port" "tcp"

    local ip; ip=$(get_public_ip)
    local link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#VLESS-Reality"

    cat >> "$SB_INFO_FILE" <<INFO

━━━━ VLESS + XTLS-Reality ━━━━
  地址      : ${ip}
  端口      : ${port}
  UUID      : ${uuid}
  Flow      : xtls-rprx-vision
  伪装 SNI  : ${sni}
  PublicKey : ${pub_key}
  ShortID   : ${short_id}
  分享链接  : ${link}
INFO
    info "✓ VLESS-Reality  端口=$port  SNI=$sni"
}

configure_hysteria2() {
    step "Hysteria2 参数配置"
    local port password cert_path key_path masq_domain tls_insecure=true

    ask "监听端口 (回车随机): "; read -r port
    [[ -z "$port" ]] && port=$(random_port)

    ask "连接密码 (回车随机生成): "; read -r password
    [[ -z "$password" ]] && password=$(gen_rand_str 24)

    echo ""
    echo "  TLS 证书选项:"
    echo "   1) 自签证书  (客户端需开启 insecure/跳过验证)"
    echo "   2) Let's Encrypt 正式证书 (需域名已解析到本机)"
    ask "选择 [1/2] 默认1: "; read -r cchoice
    [[ -z "$cchoice" ]] && cchoice="1"

    if [[ "$cchoice" == "2" ]]; then
        ask "输入域名: "; read -r domain
        [[ -z "$domain" ]] && die "域名不能为空"
        _acme_issue "$domain"
        cert_path="${SB_CERT_DIR}/${domain}.crt"
        key_path="${SB_CERT_DIR}/${domain}.key"
        masq_domain="$domain"; tls_insecure=false
    else
        masq_domain="bing.com"
        local pair; pair=$(gen_self_cert "$masq_domain")
        cert_path="${pair%%:*}"; key_path="${pair##*:}"
    fi

    INBOUND_FRAGMENT=$(cat <<JSON
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [{ "password": "${password}" }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${cert_path}",
        "key_path": "${key_path}"
      }
    }
JSON
)
    open_ports "$port" "udp"

    local ip; ip=$(get_public_ip)
    local insecure_p=""; $tls_insecure && insecure_p="&insecure=1"
    local link="hysteria2://${password}@${ip}:${port}/?sni=${masq_domain}${insecure_p}#Hysteria2"

    cat >> "$SB_INFO_FILE" <<INFO

━━━━ Hysteria2 ━━━━
  地址      : ${ip}
  端口      : ${port} (UDP)
  密码      : ${password}
  SNI       : ${masq_domain}
  跳过证书  : ${tls_insecure}
  分享链接  : ${link}
INFO
    info "✓ Hysteria2  端口=$port (UDP)"
}

configure_vmess_ws() {
    step "VMess + WebSocket 参数配置"
    local port uuid ws_path

    ask "监听端口 (回车随机, 建议80): "; read -r port
    [[ -z "$port" ]] && port=$(random_port)

    ask "WebSocket 路径 (回车随机生成): "; read -r ws_path
    [[ -z "$ws_path" ]] && ws_path="/$(gen_rand_hex 6)"
    [[ "${ws_path:0:1}" != "/" ]] && ws_path="/${ws_path}"

    uuid=$(gen_uuid)

    INBOUND_FRAGMENT=$(cat <<JSON
    {
      "type": "vmess",
      "tag": "vmess-ws-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [{ "uuid": "${uuid}", "alterId": 0 }],
      "transport": { "type": "ws", "path": "${ws_path}" }
    }
JSON
)
    open_ports "$port" "tcp"

    local ip; ip=$(get_public_ip)
    local vmess_obj="{\"v\":\"2\",\"ps\":\"VMess-WS\",\"add\":\"${ip}\",\"port\":\"${port}\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"${ws_path}\",\"tls\":\"\"}"
    local b64; b64=$(echo -n "$vmess_obj" | base64 -w0)
    local link="vmess://${b64}"

    cat >> "$SB_INFO_FILE" <<INFO

━━━━ VMess + WebSocket ━━━━
  地址      : ${ip}
  端口      : ${port}
  UUID      : ${uuid}
  AlterID   : 0
  加密      : auto
  传输      : ws
  路径      : ${ws_path}
  TLS       : 无 (建议套 CDN 或 Nginx TLS 反代)
  分享链接  : ${link}
INFO
    info "✓ VMess-WS  端口=$port  路径=$ws_path"
}

configure_trojan() {
    step "Trojan + TLS 参数配置"
    local port password cert_path key_path masq_domain tls_insecure=true

    ask "监听端口 (回车默认443): "; read -r port
    [[ -z "$port" ]] && port=443

    ask "密码 (回车随机生成): "; read -r password
    [[ -z "$password" ]] && password=$(gen_rand_str 24)

    echo ""
    echo "  TLS 证书选项:"
    echo "   1) 自签证书  (客户端需开启 allowInsecure)"
    echo "   2) Let's Encrypt 正式证书"
    ask "选择 [1/2] 默认1: "; read -r cchoice
    [[ -z "$cchoice" ]] && cchoice="1"

    if [[ "$cchoice" == "2" ]]; then
        ask "输入域名: "; read -r domain
        [[ -z "$domain" ]] && die "域名不能为空"
        _acme_issue "$domain"
        cert_path="${SB_CERT_DIR}/${domain}.crt"
        key_path="${SB_CERT_DIR}/${domain}.key"
        masq_domain="$domain"; tls_insecure=false
    else
        masq_domain="bing.com"
        local pair; pair=$(gen_self_cert "$masq_domain")
        cert_path="${pair%%:*}"; key_path="${pair##*:}"
    fi

    INBOUND_FRAGMENT=$(cat <<JSON
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "::",
      "listen_port": ${port},
      "users": [{ "password": "${password}" }],
      "tls": {
        "enabled": true,
        "certificate_path": "${cert_path}",
        "key_path": "${key_path}"
      }
    }
JSON
)
    open_ports "$port" "tcp"

    local ip; ip=$(get_public_ip)
    local insecure_p=""; $tls_insecure && insecure_p="&allowInsecure=1"
    local link="trojan://${password}@${ip}:${port}?sni=${masq_domain}${insecure_p}#Trojan"

    cat >> "$SB_INFO_FILE" <<INFO

━━━━ Trojan + TLS ━━━━
  地址      : ${ip}
  端口      : ${port}
  密码      : ${password}
  SNI       : ${masq_domain}
  跳过证书  : ${tls_insecure}
  分享链接  : ${link}
INFO
    info "✓ Trojan  端口=$port"
}

configure_shadowtls() {
    step "ShadowTLS v3 + Shadowsocks 参数配置"
    local stls_port sni

    ask "ShadowTLS 监听端口 (回车随机): "; read -r stls_port
    [[ -z "$stls_port" ]] && stls_port=$(random_port)

    echo "  推荐 SNI: www.bing.com / www.apple.com / gateway.icloud.com"
    ask "伪装 SNI [默认 www.bing.com]: "; read -r sni
    [[ -z "$sni" ]] && sni="www.bing.com"

    local ss_port; ss_port=$(random_port)
    local stls_pass; stls_pass=$(gen_rand_str 32)
    local ss_pass; ss_pass=$(gen_rand_str 32)

    local stls_frag; stls_frag=$(cat <<JSON
    {
      "type": "shadowtls",
      "tag": "shadowtls-in",
      "listen": "::",
      "listen_port": ${stls_port},
      "version": 3,
      "users": [{ "password": "${stls_pass}" }],
      "handshake": { "server": "${sni}", "server_port": 443 },
      "detour": "ss-backend-in"
    }
JSON
)
    local ss_frag; ss_frag=$(cat <<JSON
    {
      "type": "shadowsocks",
      "tag": "ss-backend-in",
      "listen": "127.0.0.1",
      "listen_port": ${ss_port},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${ss_pass}"
    }
JSON
)

    INBOUND_FRAGMENT="${stls_frag}::SPLIT::${ss_frag}"
    open_ports "$stls_port" "tcp"

    local ip; ip=$(get_public_ip)

    cat >> "$SB_INFO_FILE" <<INFO

━━━━ ShadowTLS v3 + Shadowsocks ━━━━
  地址            : ${ip}
  ShadowTLS 端口  : ${stls_port}
  ShadowTLS 密码  : ${stls_pass}
  SS 内层密码     : ${ss_pass}
  SS 加密方式     : 2022-blake3-aes-128-gcm
  伪装 SNI        : ${sni}
  [客户端需同时配置 shadowtls outbound + ss outbound 并设置 detour 关联]
INFO
    info "✓ ShadowTLS v3  端口=$stls_port  SNI=$sni"
}

# ======================== acme.sh 证书申请 ========================
_acme_issue() {
    local domain="$1"
    local crt="${SB_CERT_DIR}/${domain}.crt"
    local key="${SB_CERT_DIR}/${domain}.key"
    [[ -f "$crt" && -f "$key" ]] && { info "证书已存在,跳过: $crt"; return; }

    info "安装 acme.sh 并申请证书 ..."
    systemctl stop sing-box 2>/dev/null || true

    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl -fsSL https://get.acme.sh | sh -s "email=acme@${domain}" >/dev/null 2>&1 \
            || die "acme.sh 安装失败"
    fi

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --httpport 80 \
        || die "证书申请失败,请确认域名已解析到本机且 80 端口可访问"
    ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
        --cert-file "$crt" --key-file "$key" \
        --reloadcmd "systemctl restart sing-box"

    info "证书已安装: $crt"
}

# ======================== 协议选择菜单 ========================
SELECTED_PROTOS=()

select_protocols() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat <<'BANNER'
  ┌─────────────────────────────────────────────┐
  │         sing-box 服务端协议配置             │
  └─────────────────────────────────────────────┘
BANNER
    echo -e "${NC}"
    hr
    printf "  %-4s %-30s %s\n" "序号" "协议" "说明"
    hr
    printf "  ${BOLD}%-4s${NC} %-30s %s\n" "1)" "VLESS + XTLS-Reality"  "★ 推荐 | 抗审查首选,无需域名"
    printf "  ${BOLD}%-4s${NC} %-30s %s\n" "2)" "Hysteria2"              "★ 推荐 | UDP加速,弱网体验佳"
    printf "  ${BOLD}%-4s${NC} %-30s %s\n" "3)" "VMess + WebSocket"      "  适合套 CDN / Nginx TLS 反代"
    printf "  ${BOLD}%-4s${NC} %-30s %s\n" "4)" "Trojan + TLS"           "  经典方案,客户端兼容性好"
    printf "  ${BOLD}%-4s${NC} %-30s %s\n" "5)" "ShadowTLS v3 + SS"      "  流量伪装为真实 TLS 握手"
    printf "  ${BOLD}%-4s${NC} %-30s %s\n" "0)" "全部"                   "  同时部署以上所有协议"
    hr
    echo ""
    echo "  支持多选,空格分隔  例如: ${CYAN}1 2${NC}  或  ${CYAN}1 4${NC}"
    echo ""
    ask "请选择协议 [0-5]: "; read -r input
    [[ -z "$input" ]] && input="1"
    [[ "$input" =~ ^0$ ]] && input="1 2 3 4 5"

    SELECTED_PROTOS=()
    for num in $input; do
        case "$num" in
            1) SELECTED_PROTOS+=("vless_reality") ;;
            2) SELECTED_PROTOS+=("hysteria2") ;;
            3) SELECTED_PROTOS+=("vmess_ws") ;;
            4) SELECTED_PROTOS+=("trojan") ;;
            5) SELECTED_PROTOS+=("shadowtls") ;;
            *) warn "忽略无效输入: $num" ;;
        esac
    done
    [[ ${#SELECTED_PROTOS[@]} -eq 0 ]] && die "未选择任何协议"

    local labels=()
    for p in "${SELECTED_PROTOS[@]}"; do
        case "$p" in
            vless_reality) labels+=("VLESS-Reality") ;;
            hysteria2)     labels+=("Hysteria2") ;;
            vmess_ws)      labels+=("VMess-WS") ;;
            trojan)        labels+=("Trojan") ;;
            shadowtls)     labels+=("ShadowTLS-v3") ;;
        esac
    done
    echo ""; info "已选择: ${labels[*]}"
}

# ======================== 配置组装 ========================
assemble_config() {
    local all_inbounds=()

    for proto in "${SELECTED_PROTOS[@]}"; do
        INBOUND_FRAGMENT=""
        case "$proto" in
            vless_reality) configure_vless_reality ;;
            hysteria2)     configure_hysteria2 ;;
            vmess_ws)      configure_vmess_ws ;;
            trojan)        configure_trojan ;;
            shadowtls)     configure_shadowtls ;;
        esac

        if [[ "$INBOUND_FRAGMENT" == *"::SPLIT::"* ]]; then
            all_inbounds+=("${INBOUND_FRAGMENT%%::SPLIT::*}")
            all_inbounds+=("${INBOUND_FRAGMENT##*::SPLIT::}")
        else
            all_inbounds+=("$INBOUND_FRAGMENT")
        fi
    done

    local joined; joined=$(printf '%s\n' "${all_inbounds[@]}" | jq -s '.')

    step "写入 sing-box 配置"
    cat > "$SB_CONFIG" <<JSON
{
  "log": {
    "level": "warn",
    "output": "${SB_LOG}",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "tag": "remote", "address": "tls://8.8.8.8",                "detour": "direct" },
      { "tag": "local",  "address": "https://223.5.5.5/dns-query",   "detour": "direct" }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": ${joined},
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block",  "tag": "block"  }
  ],
  "route": {
    "rules": [
      { "geoip": ["private"], "outbound": "block" }
    ],
    "final": "direct"
  }
}
JSON

    if "$SB_BIN" check -c "$SB_CONFIG" &>/dev/null; then
        info "配置校验通过"
    else
        err "配置校验失败:"
        "$SB_BIN" check -c "$SB_CONFIG"
        exit 1
    fi
}

# ======================== 主功能 ========================
do_install() {
    require_root; detect_os; detect_arch; install_deps; setup_directories

    local ip; ip=$(get_public_ip)
    cat > "$SB_INFO_FILE" <<HEADER
==============================================
  sing-box 节点信息
  服务器 IP : ${ip}
  安装时间  : $(date '+%Y-%m-%d %H:%M:%S')
==============================================
HEADER

    step "获取最新版本"
    local ver; ver=$(get_latest_version)
    info "最新版本: v${ver}"

    if [[ -x "$SB_BIN" ]]; then
        local cur; cur=$("$SB_BIN" version 2>/dev/null | awk '{print $3}' | head -1)
        if [[ "$cur" == "$ver" ]]; then
            warn "已安装最新版本 v${ver}"
            ask "仍要重新安装? [y/N]: "; read -r ans
            [[ "$ans" =~ ^[Yy]$ ]] || { info "跳过二进制安装"; goto_config=true; }
        fi
    fi
    [[ "${goto_config:-false}" != "true" ]] && install_singbox_binary "$ver"
    install_service

    select_protocols
    assemble_config

    step "启动服务"
    systemctl restart sing-box
    sleep 2

    if systemctl is-active --quiet sing-box; then
        info "sing-box 运行中 ✔"
    else
        err "sing-box 启动失败! 日志:"
        journalctl -u sing-box -n 20 --no-pager; exit 1
    fi

    show_node_info
    echo ""
    info "安装完成!节点信息已保存: ${BOLD}$SB_INFO_FILE${NC}"
}

do_uninstall() {
    require_root
    ask "确认卸载 sing-box 及所有配置? [y/N]: "; read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f "$SB_BIN" "$SB_SERVICE"
    rm -rf "$SB_CONF_DIR" "$SB_LOG_DIR" "$SB_DATA_DIR"
    systemctl daemon-reload
    info "卸载完成"
}

do_update() {
    require_root; [[ -x "$SB_BIN" ]] || die "sing-box 未安装"; detect_arch
    local cur new
    cur=$("$SB_BIN" version | awk '{print $3}' | head -1)
    new=$(get_latest_version)
    [[ "$cur" == "$new" ]] && { info "已是最新版本 v${cur}"; return; }
    info "v${cur} → v${new}"
    install_singbox_binary "$new"
    systemctl restart sing-box && info "升级完成 ✔"
}

do_add_proto() {
    require_root; [[ -f "$SB_CONFIG" ]] || die "请先安装 sing-box"
    select_protocols; assemble_config
    systemctl restart sing-box && info "配置已更新并重启" || err "重启失败,请查看日志"
}

show_node_info() {
    [[ -f "$SB_INFO_FILE" ]] || { warn "节点信息文件不存在"; return; }
    echo ""; cat "$SB_INFO_FILE"; echo ""

    # 打印每个分享链接的二维码
    if command -v qrencode &>/dev/null; then
        while IFS= read -r line; do
            if [[ "$line" =~ 分享链接 ]]; then
                local lnk; lnk=$(echo "$line" | sed 's/.*: //' | tr -d ' ')
                [[ -n "$lnk" && "$lnk" != *"客户端"* ]] && { echo "  扫码导入:"; print_qr "$lnk"; }
            fi
        done < "$SB_INFO_FILE"
    fi
}

show_status() {
    echo ""
    [[ -x "$SB_BIN" ]] && { "$SB_BIN" version; echo ""; }
    systemctl status sing-box --no-pager -l | head -25
}

show_log() {
    [[ -f "$SB_LOG" ]] && tail -f "$SB_LOG" || journalctl -u sing-box -f
}

edit_config() {
    require_root; [[ -f "$SB_CONFIG" ]] || die "配置文件不存在"
    ${EDITOR:-vi} "$SB_CONFIG"
    if "$SB_BIN" check -c "$SB_CONFIG" &>/dev/null; then
        systemctl restart sing-box && info "已保存并重启"
    else
        err "配置有误,未重启:"; "$SB_BIN" check -c "$SB_CONFIG"
    fi
}

# ======================== 主菜单 ========================
main_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat <<'BANNER'
  ╔══════════════════════════════════════════════╗
  ║      sing-box 服务端管理脚本  v2.0.0         ║
  ╚══════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"

    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "  运行状态 : ${GREEN}${BOLD}● 运行中${NC}"
    elif [[ -f "$SB_SERVICE" ]]; then
        echo -e "  运行状态 : ${RED}${BOLD}● 已停止${NC}"
    else
        echo -e "  运行状态 : ${YELLOW}${BOLD}● 未安装${NC}"
    fi
    [[ -x "$SB_BIN" ]] && \
        echo -e "  当前版本 : $("$SB_BIN" version 2>/dev/null | awk '{print $3}' | head -1)"
    echo ""
    hr
    echo -e "  ${BOLD}安装管理${NC}"
    echo "   1) 全新安装 / 重新部署"
    echo "   2) 追加新协议"
    echo "   3) 升级至最新版本"
    echo "   4) 卸载"
    echo ""
    echo -e "  ${BOLD}服务控制${NC}"
    echo "   5) 启动        6) 停止        7) 重启"
    echo "   8) 查看状态"
    echo ""
    echo -e "  ${BOLD}配置与日志${NC}"
    echo "   9) 查看节点信息 & 分享链接"
    echo "  10) 实时日志 (Ctrl+C 退出)"
    echo "  11) 编辑配置文件"
    hr
    echo "   0) 退出"
    echo ""
    ask "请选择 [0-11]: "; read -r opt

    case "$opt" in
        1)  do_install ;;
        2)  do_add_proto ;;
        3)  do_update ;;
        4)  do_uninstall ;;
        5)  systemctl start   sing-box && info "已启动" ;;
        6)  systemctl stop    sing-box && info "已停止" ;;
        7)  systemctl restart sing-box && info "已重启" ;;
        8)  show_status ;;
        9)  show_node_info ;;
        10) show_log ;;
        11) edit_config ;;
        0)  exit 0 ;;
        *)  warn "无效选项: $opt" ;;
    esac

    echo ""; ask "按回车返回菜单..."; read -r
    main_menu
}

# ======================== 命令行入口 ========================
case "${1:-menu}" in
    install|i)         do_install ;;
    uninstall|remove)  do_uninstall ;;
    update|upgrade)    do_update ;;
    add)               do_add_proto ;;
    start)             systemctl start   sing-box ;;
    stop)              systemctl stop    sing-box ;;
    restart|r)         systemctl restart sing-box ;;
    status|s)          show_status ;;
    info|node)         show_node_info ;;
    log|logs)          show_log ;;
    menu|"")           main_menu ;;
    -h|--help)
        cat <<HELP
用法: $0 [命令]

命令:
  install      全新安装并配置协议
  add          追加协议到现有配置
  update       升级 sing-box 版本
  uninstall    完全卸载
  start        启动服务
  stop         停止服务
  restart      重启服务
  status       查看运行状态
  info         查看节点信息和分享链接
  log          实时日志
  (无参数)     进入交互式菜单

HELP
        ;;
    *) err "未知命令: $1"; "$0" --help ;;
esac
