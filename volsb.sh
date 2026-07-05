#!/usr/bin/env bash
# =============================================================================
#   VOLSB — sing-box 服务端一键部署与管理脚本
#   版本   : 1.4.42
#   项目   : https://github.com/chnnic/VOLSB
#   模式   : 部署机(落地机) / 线路机(中转机)
#   协议   : VLESS+Reality / Hysteria2 / VMess-WS / Trojan / ShadowTLS / AnyTLS / SS / TUIC
#   系统   : Alpine(OpenRC) / Debian / Ubuntu / CentOS / RHEL /
#             Alma / Rocky / Fedora / openSUSE / Arch
#   快捷键 : 安装后输入 volsb 进入管理界面
# =============================================================================

# 注意：不使用全局 set -e，交互式脚本需要手动处理每处错误
set -uo pipefail

# ──────────────────────── 颜色 & 输出 ────────────────────────
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
# shellcheck disable=SC2034
C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'
C_BOLD='\033[1m'; C_DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${C_GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${C_YELLOW}[!]${NC} $*"; }
err()     { echo -e "${C_RED}[✗]${NC} $*" >&2; }
step()    { echo -e "\n${C_CYAN}${C_BOLD}▶ $*${NC}"; }
ask()     { printf "${C_YELLOW}[?]${NC} %s" "$*"; }
die()     { err "$*"; exit 1; }
hr()      { echo -e "${C_DIM}$(printf '─%.0s' {1..60})${NC}"; }
banner()  { echo -e "\n${C_BOLD}${C_BLUE}  $*${NC}"; }
is_back_choice() { [[ "${1:-}" =~ ^([bBqQ]|back|BACK|返回)$ ]]; }

# ──────────────────────── 全局路径 ────────────────────────
VOLSB_VER="1.4.42"
VOLSB_REPO="https://raw.githubusercontent.com/chnnic/VOLSB/refs/heads/main/volsb.sh"
SING_BOX_VER="1.13.13"

# ── 环境变量支持 (方便 CI / 自动化部署) ──
# VOLSB_IP        : 指定连接地址,跳过 IP 检测提示
# VOLSB_PORT      : 指定入站端口,跳过端口交互
# VOLSB_SNI       : 指定 Reality SNI,跳过 SNI 交互
# VOLSB_MODE      : 1=部署机 2=线路机,跳过模式选择
# VOLSB_PROTO     : 协议序号,如 "1" "1 2" "0"(全部),跳过协议选择
SB_BIN="/usr/local/bin/sing-box"
SB_CONF_DIR="/etc/sing-box"
SB_CONFIG="${SB_CONF_DIR}/config.json"
SB_CERT_DIR="${SB_CONF_DIR}/certs"
SB_DATA_DIR="/var/lib/sing-box"
SB_LOG_DIR="/var/log/sing-box"
SB_LOG="${SB_LOG_DIR}/sing-box.log"
SB_INFO="${SB_CONF_DIR}/nodes.info"          # 节点明文信息
SB_LINKS="${SB_CONF_DIR}/links.txt"          # 所有分享链接
SB_TRAFFIC="${SB_CONF_DIR}/traffic.json"     # 流量统计缓存
SB_ENV="${SB_CONF_DIR}/volsb.env"            # 持久化运行参数
VOLSB_LIB_DIR="/usr/local/lib/volsb"
VOLSB_SCRIPT="${VOLSB_LIB_DIR}/volsb.sh"     # 管理脚本固定落盘路径
VOLSB_CMD="/usr/local/bin/volsb"             # 快捷命令路径
VOLSB_PORT_RESERVE_FILE="${TMPDIR:-/tmp}/volsb_ports.$$"
trap 'rm -f "$VOLSB_PORT_RESERVE_FILE" 2>/dev/null || true' EXIT
# Systemd / OpenRC service
SB_SYSTEMD="/etc/systemd/system/sing-box.service"
SB_OPENRC="/etc/init.d/sing-box"

# ──────────────────────── 系统检测 ────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "请用 root 用户执行  (提示: sudo -i)"
}

require_commands() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "缺少依赖: ${missing[*]}，请先安装后重试"
}

secure_sensitive_files() {
    chmod 700 "$SB_CONF_DIR" "$SB_CERT_DIR" 2>/dev/null || true
    chmod 600 "$SB_CONFIG" "$SB_INFO" "$SB_LINKS" "$SB_TRAFFIC" "$SB_ENV" 2>/dev/null || true
}

valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

normalize_port() {
    local port="$1"
    printf '%d' "$((10#$port))"
}

require_valid_port() {
    local port="${1:-}" label="${2:-端口}"
    if ! valid_port "$port"; then
        err "${label}无效: ${port:-空} (必须是 1-65535 的整数)"
        return 1
    fi
}

current_script_path() {
    local src="${BASH_SOURCE[0]:-$0}"
    readlink -f "$src" 2>/dev/null || true
}

is_ephemeral_script_path() {
    local path="${1:-}"
    [[ -z "$path" ]] && return 0
    [[ "$path" == /dev/fd/* || "$path" == /proc/*/fd/* || "$path" == *"pipe:["* ]] && return 0
    [[ -f "$path" ]] || return 0
    return 1
}

validate_script_file() {
    local file="$1" first_line
    first_line=$(head -1 "$file" 2>/dev/null)
    grep -q "VOLSB_VER=" "$file" 2>/dev/null && [[ "$first_line" == *"bash"* ]]
}

install_managed_script() {
    mkdir -p "$VOLSB_LIB_DIR" || return 1
    chmod 755 "$VOLSB_LIB_DIR" 2>/dev/null || true

    local src tmp
    src=$(current_script_path)
    tmp=$(mktemp "${VOLSB_LIB_DIR}/volsb.sh.XXXXXX") || return 1

    if ! is_ephemeral_script_path "$src"; then
        cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
    else
        curl -fsSL --max-time 60 -o "$tmp" "$VOLSB_REPO" || {
            rm -f "$tmp"
            err "无法将脚本落盘到固定路径: $VOLSB_SCRIPT"
            return 1
        }
    fi

    if ! validate_script_file "$tmp"; then
        rm -f "$tmp"
        err "脚本内容校验失败，未安装快捷命令"
        return 1
    fi

    chmod 755 "$tmp"
    mv "$tmp" "$VOLSB_SCRIPT"
}

write_shortcut() {
    cat > "$VOLSB_CMD" <<SHORTCUT
#!/usr/bin/env bash
exec bash "${VOLSB_SCRIPT}" "\$@"
SHORTCUT
    chmod 755 "$VOLSB_CMD"
}

detect_os() {
    if [[ -f /etc/alpine-release ]]; then
        OS_ID="alpine"; OS_VER=$(cat /etc/alpine-release)
        OS_NAME="Alpine Linux $OS_VER"
        PKG_UPDATE="apk update -q"; PKG_INSTALL="apk add -q"
        PKGS="curl wget tar jq openssl ca-certificates qrencode coreutils"
        INIT_SYS="openrc"
    elif [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-}"   # 衍生发行版兜底 (PopOS, Mint, Kali 等)
        OS_VER="${VERSION_ID:-0}"
        OS_NAME="${PRETTY_NAME:-$OS_ID}"

        # 用 ID 和 ID_LIKE 共同判断发行版系列
        local os_family="" id_all="${OS_ID} ${OS_ID_LIKE}"
        if echo "$id_all" | grep -qiE "debian|ubuntu|mint|pop|kali|elementary|zorin"; then
            os_family="debian"
        elif echo "$id_all" | grep -qiE "centos|rhel|almalinux|rocky|oracle"; then
            os_family="redhat"
        elif echo "$id_all" | grep -qi "fedora"; then
            os_family="fedora"
        elif echo "$id_all" | grep -qiE "opensuse|sles"; then
            os_family="suse"
        elif echo "$id_all" | grep -qiE "arch|manjaro|endeavour"; then
            os_family="arch"
        else
            os_family="unknown"
        fi

        case "$os_family" in
            debian)
                export DEBIAN_FRONTEND=noninteractive   # 防止 apt 交互提示卡住
                PKG_UPDATE="apt-get update -y -qq"
                PKG_INSTALL="apt-get install -y -qq"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            redhat)
                local pm="yum"; command -v dnf &>/dev/null && pm="dnf"
                PKG_UPDATE="$pm makecache -q"; PKG_INSTALL="$pm install -y -q"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            fedora)
                PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            suse)
                PKG_UPDATE="zypper refresh -q"; PKG_INSTALL="zypper install -y -q"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            arch)
                PKG_UPDATE="pacman -Sy --noconfirm"
                PKG_INSTALL="pacman -S --noconfirm --needed"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            *) die "不支持的发行版: $OS_ID (ID_LIKE: ${OS_ID_LIKE:-无})" ;;
        esac
        INIT_SYS="systemd"
    else
        die "无法识别操作系统"
    fi
    info "系统: $OS_NAME  |  初始化: $INIT_SYS"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l)        ARCH="armv7" ;;
        s390x)         ARCH="s390x" ;;
        *) die "不支持的 CPU 架构: $(uname -m)" ;;
    esac
}

install_deps() {
    step "安装依赖"
    eval "$PKG_UPDATE" 2>/dev/null || warn "包列表更新失败,继续..."
    # shellcheck disable=SC2086
    eval "$PKG_INSTALL $PKGS" 2>/dev/null || warn "部分依赖安装失败,继续..."
    require_commands curl tar jq openssl
}

# ──────────────────────── sing-box 下载安装 ────────────────────────
get_latest_version() {
    echo "$SING_BOX_VER"
}

install_binary() {
    local ver="$1"
    local tmpdir; tmpdir=$(mktemp -d)
    local pkg="sing-box-${ver}-linux-${ARCH}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg}"
    info "下载 sing-box v${ver} (${ARCH})..."
    curl -fsSL --max-time 180 -o "${tmpdir}/${pkg}" "$url" \
        || { rm -rf "$tmpdir"; die "下载失败: $url"; }
    tar -xzf "${tmpdir}/${pkg}" -C "$tmpdir" 2>/dev/null || die "解压失败"
    install -m 755 "${tmpdir}/sing-box-${ver}-linux-${ARCH}/sing-box" "$SB_BIN"
    rm -rf "$tmpdir"
    info "sing-box 已安装: $("$SB_BIN" version | head -1)"
}

setup_dirs() {
    mkdir -p "$SB_CONF_DIR" "$SB_CERT_DIR" "$SB_LOG_DIR" "$SB_DATA_DIR"
    secure_sensitive_files
}

# ──────────────────────── 服务管理 (systemd / OpenRC) ────────────────────────
install_service() {
    if [[ "$INIT_SYS" == "openrc" ]]; then
        cat > "$SB_OPENRC" <<'RC'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy server"
command="/usr/local/bin/sing-box"
command_args="-D /var/lib/sing-box -C /etc/sing-box run"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box/sing-box.log"
error_log="/var/log/sing-box/sing-box.log"

depend() { need net; after firewall; }

start_pre() {
    /usr/local/bin/sing-box check -C /etc/sing-box || return 1
    mkdir -p /var/lib/sing-box /var/log/sing-box
}
RC
        chmod +x "$SB_OPENRC"
        rc-update add sing-box default &>/dev/null
        info "OpenRC 服务已注册 (开机自启)"
    else
        cat > "$SB_SYSTEMD" <<'UNIT'
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
        info "Systemd 服务已注册 (开机自启)"
    fi
}

svc_start()   {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service sing-box start
    else systemctl start sing-box; fi
}
svc_stop()    {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service sing-box stop
    else systemctl stop sing-box; fi
}
svc_restart() {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service sing-box restart
    else systemctl restart sing-box; fi
}
svc_status()  {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service sing-box status
    else systemctl status sing-box --no-pager -l | head -30; fi
}
svc_active()  {
    if [[ "$INIT_SYS" == "openrc" ]]; then
        rc-service sing-box status 2>/dev/null | grep -q "started"
    else
        systemctl is-active --quiet sing-box 2>/dev/null
    fi
}

# ──────────────────────── 工具函数 ────────────────────────
get_public_ipv4() {
    local ip=""
    for api in         "https://api.ipify.org"         "https://ipinfo.io/ip"         "https://ifconfig.me/ip"         "https://icanhazip.com"         "https://ipecho.net/plain"; do
        ip=$(curl -fsSL --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"; return 0
        fi
    done
    echo ""
}

get_public_ipv6() {
    local ip=""
    for api in "https://api6.ipify.org" "https://ifconfig.co/ip"; do
        ip=$(curl -6 -fsSL --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" == *:* ]] && { echo "$ip"; return 0; }
    done
    echo ""
}

get_public_ip() {
    local ip=""
    ip=$(get_public_ipv4)
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    ip=$(get_public_ipv6)
    [[ "$ip" == *:* ]] && echo "$ip" || echo ""
}

url_host() {
    local host="$1"
    if [[ "$host" == \[*\] ]]; then
        echo "$host"
    elif [[ "$host" == *:* ]]; then
        echo "[${host}]"
    else
        echo "$host"
    fi
}

url_encode() {
    local s="$1"
    printf '%s' "$s" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

port_is_reserved() {
    local port="$1"
    [[ -f "$VOLSB_PORT_RESERVE_FILE" ]] && grep -qx "$port" "$VOLSB_PORT_RESERVE_FILE" 2>/dev/null
}

reserve_port() {
    local port="$1"
    valid_port "$port" || return 0
    port_is_reserved "$port" && return 0
    printf '%s\n' "$port" >> "$VOLSB_PORT_RESERVE_FILE"
}

random_port() {
    local p
    while :; do
        p=$(( RANDOM % 45000 + 10000 ))
        ss -tuln 2>/dev/null | grep -q ":${p} " && continue
        port_is_reserved "$p" && continue
        reserve_port "$p"
        echo "$p"
        return
    done
}

gen_uuid()     { "$SB_BIN" generate uuid; }
gen_rand_str() { openssl rand -base64 48 | tr -d '+/=\n' | head -c "${1:-32}"; }
gen_rand_hex() { openssl rand -hex "${1:-8}"; }

gen_self_cert() {
    local cn="${1:-bing.com}"
    local crt="${SB_CERT_DIR}/${cn}.crt"
    local key="${SB_CERT_DIR}/${cn}.key"
    local san_type="DNS"
    [[ "$cn" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && san_type="IP"

    openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null
    if ! openssl req -new -x509 -days 36500 -key "$key" -out "$crt" \
        -subj "/CN=${cn}" -addext "subjectAltName = ${san_type}:${cn}" 2>/dev/null; then
        local ext_file; ext_file=$(mktemp)
        cat > "$ext_file" <<EOF
subjectAltName = ${san_type}:${cn}
EOF
        openssl req -new -x509 -days 36500 -key "$key" -out "$crt" \
            -subj "/CN=${cn}" -extfile "$ext_file" 2>/dev/null
        rm -f "$ext_file"
    fi
    chmod 600 "$key"
    echo "${crt}:${key}"
}

open_port() {
    local port="$1" proto="${2:-tcp}"
    valid_port "$port" || { warn "跳过放行无效端口: ${port:-空}"; return 0; }
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active" && \
        ufw allow "${port}/${proto}" &>/dev/null || true
    command -v firewall-cmd &>/dev/null && \
        systemctl is-active --quiet firewalld 2>/dev/null && {
            firewall-cmd --permanent --add-port="${port}/${proto}" &>/dev/null || true
            firewall-cmd --reload &>/dev/null || true
        }
    # iptables fallback
    command -v iptables &>/dev/null && {
        iptables  -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        ip6tables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
    }
}

print_qr() {
    command -v qrencode &>/dev/null || return
    echo -e "\n${C_DIM}  扫码导入:${NC}"
    echo "$1" | qrencode -t ANSIUTF8 2>/dev/null || true
}

tcp_connect_test() {
    local host="$1" port="$2"
    valid_port "$port" || return 1
    timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null
}

share_link_proto() {
    local link="$1"
    echo "${link%%://*}" | tr '[:lower:]' '[:upper:]'
}

share_link_name() {
    local link="$1" fallback="$2" name
    name=$(printf '%s' "$link" | grep -oP '(?<=#)[^#]*$' 2>/dev/null || true)
    [[ -n "$name" ]] && printf '%s' "$name" || printf '%s' "$fallback"
}

save_env() {
    mkdir -p "$SB_CONF_DIR" 2>/dev/null || true
    touch "$SB_ENV" 2>/dev/null || true
    chmod 600 "$SB_ENV" 2>/dev/null || true
    declare -p "$1" >> "$SB_ENV" 2>/dev/null || true
}

load_env() {
    # shellcheck disable=SC1090
    [[ -f "$SB_ENV" ]] && source "$SB_ENV" 2>/dev/null || true
}

# ──────────────────────── acme.sh Let's Encrypt ────────────────────────
acme_has_domain() {
    local domain="$1"
    [[ -f "$HOME/.acme.sh/${domain}_ecc/${domain}.cer" || -f "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" || \
       -f "$HOME/.acme.sh/${domain}/${domain}.cer" || -f "$HOME/.acme.sh/${domain}/fullchain.cer" ]]
}

domain_has_aaaa() {
    local domain="$1"
    command -v getent &>/dev/null || return 1
    getent ahostsv6 "$domain" 2>/dev/null | awk '{print $1}' | grep -q ':' \
        || getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | grep -q ':'
}

acme_install_cert() {
    local domain="$1"
    local crt="${SB_CERT_DIR}/${domain}.crt"
    local key="${SB_CERT_DIR}/${domain}.key"
    local reload_cmd="$VOLSB_CMD restart"
    if ! acme_has_domain "$domain"; then
        err "acme.sh 中未找到完整证书: $domain"
        return 1
    fi
    [[ -x "$VOLSB_CMD" ]] || reload_cmd="$(command -v bash) ${VOLSB_SCRIPT} restart"
    ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
        --fullchain-file "$crt" --key-file "$key" \
        --reloadcmd "$reload_cmd" \
        || { err "证书安装失败 — 请确认: ① 域名已解析到本机 ② 80端口未被占用 ③ acme.sh 中已有该域名证书"; return 1; }
    [[ -s "$crt" && -s "$key" ]] || { err "证书文件不完整: $crt / $key"; return 1; }
    chmod 600 "$key" 2>/dev/null || true
    info "证书已安装(fullchain): $crt"
}

acme_issue() {
    local domain="$1"
    local crt="${SB_CERT_DIR}/${domain}.crt"
    local key="${SB_CERT_DIR}/${domain}.key"
    [[ -f "$crt" && -f "$key" ]] && { info "证书已存在,跳过申请"; return; }
    info "申请或复用 Let's Encrypt 证书 (域名: $domain)..."
    open_port 80 tcp
    svc_stop 2>/dev/null || true
    [[ -f ~/.acme.sh/acme.sh ]] || \
        curl -fsSL https://get.acme.sh | sh -s "email=acme@${domain}" >/dev/null 2>&1 \
        || die "acme.sh 安装失败"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    local force_args=()
    if ! acme_has_domain "$domain" && [[ -d "$HOME/.acme.sh/${domain}_ecc" || -d "$HOME/.acme.sh/${domain}" ]]; then
        warn "检测到旧的未完成证书记录，强制重新签发..."
        force_args+=(--force)
    fi
    if ! ~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --httpport 80 "${force_args[@]}"; then
        if domain_has_aaaa "$domain"; then
            warn "检测到 AAAA 记录，尝试使用 IPv6 standalone 重新申请..."
            ~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --httpport 80 --listen-v6 --force || {
                warn "IPv6 申请仍失败，尝试安装 acme.sh 中已有证书..."
            }
        else
            warn "证书未重新签发，尝试安装 acme.sh 中已有证书..."
        fi
    fi
    acme_install_cert "$domain" || return 1
}

collect_reusable_cert_domains() {
    local crt domain dir
    {
        find "$SB_CERT_DIR" -maxdepth 1 -type f -name '*.crt' 2>/dev/null \
            | while IFS= read -r crt; do
                [[ -f "${crt%.crt}.key" ]] || continue
                basename "$crt" .crt
            done

        if [[ -d "$HOME/.acme.sh" ]]; then
            find "$HOME/.acme.sh" -maxdepth 1 -type d 2>/dev/null \
                | while IFS= read -r dir; do
                    domain=$(basename "$dir")
                    case "$domain" in
                        *_ecc) domain="${domain%_ecc}" ;;
                        *) continue ;;
                    esac
                    [[ -f "$dir/${domain}.cer" || -f "$dir/fullchain.cer" ]] || continue
                    printf '%s\n' "$domain"
                done
        fi
    } | sort -u
}

select_existing_cert() {
    local certs=() crt key domain
    SELECTED_CERT_DOMAIN=""
    SELECTED_CERT_PATH=""
    SELECTED_CERT_KEY_PATH=""
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        certs+=("$domain")
    done < <(collect_reusable_cert_domains)

    if [[ ${#certs[@]} -eq 0 ]]; then
        err "未找到可复用证书，请先申请 Let's Encrypt 证书"
        return 1
    fi

    echo "" >&2
    echo "  可复用证书:" >&2
    local i=1
    for domain in "${certs[@]}"; do
        printf "   %d) %s\n" "$i" "$domain" >&2
        (( i++ )) || true
    done
    echo "   d) 删除旧证书" >&2
    echo "   0) 返回上一级" >&2
    printf "${C_YELLOW}[?]${NC} 选择证书 [1-${#certs[@]}] / d删除 / 0返回:" >&2
    read -r cert_choice
    [[ -z "$cert_choice" ]] && cert_choice="1"
    if [[ "$cert_choice" == "0" ]]; then
        info "已返回上一级"
        return 1
    fi
    if is_back_choice "$cert_choice"; then
        info "已返回上一级"
        return 1
    fi
    if [[ "$cert_choice" == "d" || "$cert_choice" == "D" ]]; then
        delete_existing_cert || true
        select_existing_cert
        return $?
    fi
    if ! [[ "$cert_choice" =~ ^[0-9]+$ ]] || (( cert_choice < 1 || cert_choice > ${#certs[@]} )); then
        err "证书选择无效"
        return 1
    fi

    domain="${certs[$(( cert_choice - 1 ))]}"
    crt="${SB_CERT_DIR}/${domain}.crt"
    key="${SB_CERT_DIR}/${domain}.key"
    if [[ ! -f "$crt" || ! -f "$key" ]]; then
        info "证书未安装到 sing-box，尝试从 acme.sh 安装 fullchain..."
        acme_install_cert "$domain" || return 1
    fi
    SELECTED_CERT_DOMAIN="$domain"
    SELECTED_CERT_PATH="$crt"
    SELECTED_CERT_KEY_PATH="$key"
}

delete_existing_cert() {
    local certs=() crt key domain cert_choice confirm
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        certs+=("$domain")
    done < <(collect_reusable_cert_domains)

    if [[ ${#certs[@]} -eq 0 ]]; then
        warn "没有可删除的本地证书"
        return 0
    fi

    echo "" >&2
    echo "  删除证书:" >&2
    local i=1
    for domain in "${certs[@]}"; do
        printf "   %d) %s\n" "$i" "$domain" >&2
        (( i++ )) || true
    done
    echo "   0) 返回上一级" >&2
    printf "${C_YELLOW}[?]${NC} 选择要删除的证书 [1-${#certs[@]}]，回车/0取消:" >&2
    read -r cert_choice
    [[ -z "$cert_choice" ]] && return 0
    [[ "$cert_choice" == "0" ]] && return 0
    is_back_choice "$cert_choice" && return 0
    if ! [[ "$cert_choice" =~ ^[0-9]+$ ]] || (( cert_choice < 1 || cert_choice > ${#certs[@]} )); then
        err "证书选择无效"
        return 1
    fi

    domain="${certs[$(( cert_choice - 1 ))]}"
    crt="${SB_CERT_DIR}/${domain}.crt"
    key="${SB_CERT_DIR}/${domain}.key"
    printf "${C_YELLOW}[?]${NC} 输入 DELETE 确认删除 %s:" "$domain" >&2
    read -r confirm
    [[ "$confirm" == "DELETE" ]] || { warn "已取消删除"; return 0; }

    rm -f -- "$crt" "$key"
    rm -rf -- "$HOME/.acme.sh/${domain}_ecc" 2>/dev/null || true
    info "已删除本地证书: ${domain}"
}

# ════════════════════════════════════════════════════════════
#  ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗
#  ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝
#  ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝
#  ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝
#  ██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║
#  ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝
#           MODE: 部署机 (落地机)
# ════════════════════════════════════════════════════════════

# 全局:存放当前安装的所有入站 JSON 片段
declare -a ALL_INBOUNDS=()
declare -a ALL_LINKS=()
ROUTE_HOME_ADDR=""
ROUTE_HOME_PORT=""
ROUTE_HOME_METHOD=""
ROUTE_HOME_PASS=""
ROUTE_AI_ADDR=""
ROUTE_AI_PORT=""
ROUTE_AI_METHOD=""
ROUTE_AI_PASS=""
ROUTE_AI_TAG="ss-ai"
ROUTE_OUTBOUNDS_JSON=""
ROUTE_CONFIG_JSON=""
ROUTE_AI_ITEMS=""
ROUTE_SS_CONFIGURED=false
ROUTE_BASE_OUTBOUNDS_JSON=""
ROUTE_BASE_ROUTE_JSON=""
declare -a ROUTE_DIRECT_TAGS=()
declare -a ROUTE_HOME_TAGS=()
declare -a ROUTE_SPLIT_TAGS=()
declare -a ROUTE_SPLIT_UDP_DIRECT_TAGS=()
declare -a ROUTE_SPLIT_DIRECT_TAGS=()
SELECTED_CERT_DOMAIN=""
SELECTED_CERT_PATH=""
SELECTED_CERT_KEY_PATH=""

select_tls_cert_mode() {
    local label="${1:-TLS}"
    local choice
    SELECTED_TLS_DOMAIN=""
    SELECTED_TLS_CERT_PATH=""
    SELECTED_TLS_KEY_PATH=""
    SELECTED_TLS_INSECURE="true"
    SELECTED_TLS_LINK_ADDR=""

    echo "  ${label}:"
    echo "   1) 复用已有证书"
    echo "   2) 自签证书 (客户端需开 insecure)"
    echo "   3) Let's Encrypt 正式证书"
    echo "   0) 返回上一级"
    ask "选择 [0/1/2/3] 默认1:"; read -r choice
    if [[ "$choice" == "0" ]] || is_back_choice "$choice"; then
        info "已返回上一级"; return 1
    fi
    [[ -z "$choice" ]] && choice="1"
    select_tls_cert_mode_from_choice "$choice"
}

select_tls_cert_mode_from_choice() {
    local choice="$1"
    local domain pair
    SELECTED_TLS_DOMAIN=""
    SELECTED_TLS_CERT_PATH=""
    SELECTED_TLS_KEY_PATH=""
    SELECTED_TLS_INSECURE="true"
    SELECTED_TLS_LINK_ADDR=""

    case "$choice" in
        1)
            select_existing_cert || return 1
            domain="$SELECTED_CERT_DOMAIN"
            SELECTED_TLS_CERT_PATH="$SELECTED_CERT_PATH"
            SELECTED_TLS_KEY_PATH="$SELECTED_CERT_KEY_PATH"
            if [[ -z "$domain" || -z "$SELECTED_TLS_CERT_PATH" || -z "$SELECTED_TLS_KEY_PATH" ]]; then
                err "证书选择失败，请重新选择"
                return 1
            fi
            if acme_has_domain "$domain"; then
                info "检测到 acme.sh 证书记录，重新安装 fullchain..."
                acme_install_cert "$domain" || return 1
                SELECTED_TLS_CERT_PATH="${SB_CERT_DIR}/${domain}.crt"
                SELECTED_TLS_KEY_PATH="${SB_CERT_DIR}/${domain}.key"
            elif [[ -d "$HOME/.acme.sh/${domain}_ecc" || -d "$HOME/.acme.sh/${domain}" ]]; then
                warn "检测到 acme.sh 目录但没有完整证书文件，已跳过复用"
            fi
            SELECTED_TLS_DOMAIN="$domain"
            SELECTED_TLS_LINK_ADDR="$domain"
            SELECTED_TLS_INSECURE="false"
            info "复用证书: ${domain}"
            ;;
        2)
            domain="${CONNECT_ADDR}"
            pair=$(gen_self_cert "$domain")
            SELECTED_TLS_DOMAIN="$domain"
            SELECTED_TLS_CERT_PATH="${pair%%:*}"
            SELECTED_TLS_KEY_PATH="${pair##*:}"
            SELECTED_TLS_LINK_ADDR="$CONNECT_ADDR"
            SELECTED_TLS_INSECURE="true"
            ;;
        3)
            ask "域名:"; read -r domain
            [[ -z "$domain" ]] && { err "域名不能为空"; return 1; }
            acme_issue "$domain" || return 1
            SELECTED_TLS_DOMAIN="$domain"
            SELECTED_TLS_CERT_PATH="${SB_CERT_DIR}/${domain}.crt"
            SELECTED_TLS_KEY_PATH="${SB_CERT_DIR}/${domain}.key"
            SELECTED_TLS_LINK_ADDR="$domain"
            SELECTED_TLS_INSECURE="false"
            ;;
        *)
            err "证书模式选择无效"
            return 1
            ;;
    esac
}

select_ss_method() {
    local choice
    echo "  Shadowsocks 加密方式:"
    echo "   1) 2022-blake3-aes-128-gcm (推荐)"
    echo "   2) 2022-blake3-aes-256-gcm"
    echo "   3) aes-128-gcm"
    echo "   4) aes-256-gcm"
    echo "   0) 返回上一级"
    ask "选择 [0/1/2/3/4] 默认1:"; read -r choice
    if [[ "$choice" == "0" ]] || is_back_choice "$choice"; then
        info "已返回上一级"; return 1
    fi
    [[ -z "$choice" ]] && choice="1"
    case "$choice" in
        1)
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
        2)
            SS_METHOD="2022-blake3-aes-256-gcm"
            ;;
        3)
            SS_METHOD="aes-128-gcm"
            ;;
        4)
            SS_METHOD="aes-256-gcm"
            ;;
        *)
            err "Shadowsocks 加密方式选择无效"
            return 1
            ;;
    esac
    info "已选择 Shadowsocks 加密方式: ${SS_METHOD}"
}

# ────── 公共参数收集:连接IP/域名 ──────
ask_connect_addr() {
    # 支持环境变量 VOLSB_IP 跳过交互
    if [[ -n "${VOLSB_IP:-}" ]]; then
        CONNECT_ADDR="$VOLSB_IP"
        info "连接地址 (环境变量): $CONNECT_ADDR"; return
    fi

    local auto_ipv4 auto_ipv6
    auto_ipv4=$(get_public_ipv4)
    auto_ipv6=$(get_public_ipv6)
    echo ""
    echo -e "  ${C_BOLD}客户端连接地址${NC}（填入客户端的服务器地址）:"
    echo -e "  ① 自动检测公网 IPv4: ${C_CYAN}${auto_ipv4:-检测失败}${NC}"
    echo -e "  ② 自动检测公网 IPv6: ${C_CYAN}${auto_ipv6:-检测失败}${NC}"
    echo    "  ③ 手动输入（如有域名/DDNS 可在此填入）"
    echo    "  0) 返回上一级"
    ask "选择 [0/1/2/3] 默认1:"; read -r opt
    [[ "$opt" == "0" ]] && { info "已返回上一级"; return 1; }
    is_back_choice "$opt" && { info "已返回上一级"; return 1; }
    if [[ "$opt" == "2" ]]; then
        CONNECT_ADDR="${auto_ipv6:-${auto_ipv4:-127.0.0.1}}"
    elif [[ "$opt" == "3" ]]; then
        ask "输入 IP 或域名:"; read -r CONNECT_ADDR
        [[ -z "$CONNECT_ADDR" ]] && CONNECT_ADDR="${auto_ipv4:-${auto_ipv6:-127.0.0.1}}"
    else
        CONNECT_ADDR="${auto_ipv4:-${auto_ipv6:-127.0.0.1}}"
    fi
    info "连接地址: $CONNECT_ADDR"
}

# ────── 线路机专用:连接IP/域名（提示更明确）──────
ask_relay_connect_addr() {
    if [[ -n "${VOLSB_IP:-}" ]]; then
        CONNECT_ADDR="$VOLSB_IP"
        info "线路机连接地址 (环境变量): $CONNECT_ADDR"; return
    fi

    local auto_ipv4 auto_ipv6
    auto_ipv4=$(get_public_ipv4)
    auto_ipv6=$(get_public_ipv6)
    echo ""
    echo -e "  ${C_BOLD}线路机（本机）对外连接地址${NC}"
    echo    "  客户端将连接此地址，线路机再转发到落地机"
    echo -e "  ① 自动检测公网 IPv4: ${C_CYAN}${auto_ipv4:-检测失败}${NC}"
    echo -e "  ② 自动检测公网 IPv6: ${C_CYAN}${auto_ipv6:-检测失败}${NC}"
    echo    "  ③ 手动输入（如有域名/DDNS）"
    echo    "  0) 返回上一级"
    ask "选择 [0/1/2/3] 默认1:"; read -r opt
    [[ "$opt" == "0" ]] && { info "已返回上一级"; return 1; }
    is_back_choice "$opt" && { info "已返回上一级"; return 1; }
    if [[ "$opt" == "2" ]]; then
        CONNECT_ADDR="${auto_ipv6:-${auto_ipv4:-127.0.0.1}}"
    elif [[ "$opt" == "3" ]]; then
        ask "输入线路机 IP 或域名:"; read -r CONNECT_ADDR
        [[ -z "$CONNECT_ADDR" ]] && CONNECT_ADDR="${auto_ipv4:-${auto_ipv6:-127.0.0.1}}"
    else
        CONNECT_ADDR="${auto_ipv4:-${auto_ipv6:-127.0.0.1}}"
    fi
    info "线路机连接地址: $CONNECT_ADDR"
}

# ────── 多用户输入 ──────
# 结果写入全局变量 USER_COUNT，避免子 shell 吞掉 read
USER_COUNT=1
ask_multi_user_count() {
    ask "生成节点数量 (1-10, 回车默认1):"; read -r _cnt
    [[ "$_cnt" =~ ^[1-9][0-9]?$ ]] || _cnt=1
    [[ "$_cnt" -gt 10 ]] && _cnt=10
    USER_COUNT="$_cnt"
}

# ────── 协议 1: VLESS + XTLS-Reality ──────
deploy_vless_reality() {
    step "配置 VLESS + XTLS-Reality"

    local port sni
    # 支持环境变量 VOLSB_PORT / VOLSB_SNI
    if [[ -n "${VOLSB_PORT:-}" ]]; then
        port="$VOLSB_PORT"; info "端口 (环境变量): $port"
    else
        ask "监听端口 (回车随机):"; read -r port
        [[ -z "$port" ]] && port=$(random_port)
    fi
    require_valid_port "$port" "监听端口" || return 1
    port=$(normalize_port "$port")
    reserve_port "$port"

    if [[ -n "${VOLSB_SNI:-}" ]]; then
        sni="$VOLSB_SNI"; info "SNI (环境变量): $sni"
    else
        echo ""
        echo "  SNI 用于伪装 TLS 握手,建议选目标国大型网站:"
        echo "  推荐: www.cloudflare.com / www.microsoft.com / www.apple.com / www.icloud.com"
        ask "输入 SNI [默认 www.cloudflare.com]:"; read -r sni
        [[ -z "$sni" ]] && sni="www.cloudflare.com"
    fi

    # 生成 Reality 密钥对
    local keypair; keypair=$("$SB_BIN" generate reality-keypair)
    local priv_key; priv_key=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
    local pub_key;  pub_key=$(echo  "$keypair" | awk '/PublicKey/{print $2}')

    ask_multi_user_count; local user_count="$USER_COUNT"

    # 先收集所有用户数据，保证 short_id 在 link 和配置里完全一致
    local users_json="["
    local short_ids_json="["
    local idx=0

    for i in $(seq 1 "$user_count"); do
        local uuid; uuid=$(gen_uuid)
        local short_id; short_id=$(gen_rand_hex 8)

        [[ $idx -gt 0 ]] && { users_json+=","; short_ids_json+=","; }
        (( idx++ )) || true

        users_json+=$(printf '{"uuid":"%s","flow":"xtls-rprx-vision"}' "$uuid")
        short_ids_json+=$(printf '"%s"' "$short_id")

        local connect_host; connect_host=$(url_host "$CONNECT_ADDR")
        local link="vless://${uuid}@${connect_host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#VOLSB-Reality-${i}-${port}"
        ALL_LINKS+=("$link")

        cat >> "$SB_INFO" <<INFO
  [VLESS-Reality #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port}
    UUID     : ${uuid}
    SNI      : ${sni}
    PublicKey: ${pub_key}
    ShortID  : ${short_id}
    Flow     : xtls-rprx-vision
    链接     : ${link}
INFO
    done
    users_json+="]"
    short_ids_json+="]"

    local inbound
    inbound=$(jq -n \
        --argjson port      "$port" \
        --argjson users     "$users_json" \
        --arg     sni       "$sni" \
        --arg     priv_key  "$priv_key" \
        --argjson short_ids "$short_ids_json" \
        '{type:"vless",tag:"vless-reality-in",listen:"::",listen_port:$port,
           users:$users,tls:{enabled:true,server_name:$sni,
           reality:{enabled:true,handshake:{server:$sni,server_port:443},
           private_key:$priv_key,short_id:$short_ids}}}')
    ALL_INBOUNDS+=("$inbound")
    ask_inbound_route_mode "vless-reality-in" "VLESS-Reality" || return 1

    open_port "$port" tcp
    info "✓ VLESS-Reality | 端口:$port | 用户数:$user_count | SNI:$sni"
}

# ────── 协议 2: Hysteria2 ──────
deploy_hysteria2() {
    step "配置 Hysteria2"

    local port; ask "监听端口 (回车随机):"; read -r port
    [[ -z "$port" ]] && port=$(random_port)
    require_valid_port "$port" "监听端口" || return 1
    port=$(normalize_port "$port")
    reserve_port "$port"

    select_tls_cert_mode "TLS 证书" || return 1
    local masq_domain="$SELECTED_TLS_DOMAIN"
    local cert_path="$SELECTED_TLS_CERT_PATH"
    local key_path="$SELECTED_TLS_KEY_PATH"
    local insecure="$SELECTED_TLS_INSECURE"

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local idx=0
    for i in $(seq 1 "$user_count"); do
        local pwd; pwd=$(gen_rand_str 24)
        [[ $idx -gt 0 ]] && users_json+=","
        (( idx++ )) || true
        users_json+="{\"password\":\"${pwd}\"}"
        local ins_param=""; [[ "$insecure" == "true" ]] && ins_param="&insecure=1"
        local connect_host; connect_host=$(url_host "$CONNECT_ADDR")
        local link="hysteria2://${pwd}@${connect_host}:${port}/?sni=${masq_domain}${ins_param}#VOLSB-HY2-${i}-${port}"
        ALL_LINKS+=("$link")
        cat >> "$SB_INFO" <<INFO
  [Hysteria2 #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port} (UDP)
    密码     : ${pwd}
    SNI      : ${masq_domain}
    跳过验证 : ${insecure}
    链接     : ${link}
INFO
    done
    users_json+="]"

    local inbound
    inbound=$(jq -n \
        --argjson port  "$port" \
        --argjson users "$users_json" \
        --arg     cert  "$cert_path" \
        --arg     key   "$key_path" \
        '{type:"hysteria2",tag:"hysteria2-in",listen:"::",listen_port:$port,
           users:$users,tls:{enabled:true,alpn:["h3"],
           certificate_path:$cert,key_path:$key}}')
    ALL_INBOUNDS+=("$inbound")
    ask_inbound_route_mode "hysteria2-in" "Hysteria2" || return 1

    open_port "$port" udp
    info "✓ Hysteria2 | 端口:$port (UDP) | 用户数:$user_count"
}

# ────── 协议 2.5: Shadowsocks ──────
deploy_shadowsocks() {
    step "配置 Shadowsocks"

    local base_port; ask "监听端口 (回车随机):"; read -r base_port
    [[ -z "$base_port" ]] && base_port=$(random_port)
    require_valid_port "$base_port" "监听端口" || return 1
    base_port=$(normalize_port "$base_port")
    reserve_port "$base_port"

    ask_multi_user_count; local user_count="$USER_COUNT"
    if [[ "$user_count" -gt 1 ]]; then
        warn "Shadowsocks 分享链接无法可靠表达同端口多用户，已改为每个节点独立端口"
    fi

    local ports=("$base_port")
    local i
    for i in $(seq 2 "$user_count"); do
        ports+=("$(random_port)")
    done

    select_ss_method || return 1

    local route_tags=()
    local port
    local pwd_len=24
    case "$SS_METHOD" in
        2022-blake3-aes-128-gcm) pwd_len=16 ;;
        2022-blake3-aes-256-gcm) pwd_len=32 ;;
    esac
    for i in $(seq 1 "$user_count"); do
        port="${ports[$(( i - 1 ))]}"
        local pwd
        if [[ "$SS_METHOD" == 2022-* ]]; then
            pwd=$("$SB_BIN" generate rand --base64 "$pwd_len" 2>/dev/null || openssl rand -base64 "$pwd_len" | tr -d '\n\r')
        else
            pwd=$(gen_rand_str 24)
        fi
        local connect_host; connect_host=$(url_host "$CONNECT_ADDR")
        local userinfo="${SS_METHOD}:${pwd}"
        local link_raw link_b64 link_b64_body
        link_raw="ss://$(url_encode "$userinfo")@${connect_host}:${port}#VOLSB-SS-${i}-${port}"
        link_b64_body=$(printf "%s" "$userinfo" | base64 -w0 2>/dev/null || printf "%s" "$userinfo" | base64 | tr -d '\n')
        link_b64_body=$(printf "%s" "$link_b64_body" | tr '+/' '-_' | sed 's/=*$//')
        link_b64="ss://${link_b64_body}@${connect_host}:${port}#VOLSB-SS-${i}-${port}-b64"
        local tag="ss-in-${port}"
        route_tags+=("$tag")
        local link="$link_raw"
        ALL_LINKS+=("$link")
        ALL_LINKS+=("$link_b64")
        cat >> "$SB_INFO" <<INFO
  [Shadowsocks #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port} (TCP/UDP)
    加密方式 : ${SS_METHOD}
    密码     : ${pwd}
    链接     : ${link_raw}
    备用链接 : ${link_b64}
INFO
        local inbound
        inbound=$(jq -n \
            --argjson port  "$port" \
            --arg     tag   "$tag" \
            --arg     method "$SS_METHOD" \
            --arg     password "$pwd" \
            '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,
              method:$method,password:$password}')
        ALL_INBOUNDS+=("$inbound")
        open_port "$port" tcp
        open_port "$port" udp
    done

    ask_inbound_route_mode "${route_tags[0]}" "Shadowsocks" "${route_tags[@]:1}" || return 1

    info "✓ Shadowsocks | 首端口:${ports[0]} | 节点数:$user_count | 加密:$SS_METHOD"
}

# ────── 协议 3: VMess + WebSocket ──────
deploy_vmess_ws() {
    step "配置 VMess + WebSocket"
    local port ws_path
    ask "监听端口 (回车随机, 建议80):"; read -r port; [[ -z "$port" ]] && port=$(random_port)
    require_valid_port "$port" "监听端口" || return 1
    port=$(normalize_port "$port")
    reserve_port "$port"
    ask "WebSocket 路径 (回车随机):"; read -r ws_path
    [[ -z "$ws_path" ]] && ws_path="/$(gen_rand_hex 6)"
    [[ "${ws_path:0:1}" != "/" ]] && ws_path="/${ws_path}"

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local idx=0
    for i in $(seq 1 "$user_count"); do
        local uuid; uuid=$(gen_uuid)
        [[ $idx -gt 0 ]] && users_json+=","
        (( idx++ )) || true
        users_json+="{\"uuid\":\"${uuid}\",\"alterId\":0}"
        local vmjson="{\"v\":\"2\",\"ps\":\"VOLSB-VMess-${i}-${port}\",\"add\":\"${CONNECT_ADDR}\",\"port\":\"${port}\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"${ws_path}\",\"tls\":\"\"}"
        local b64; b64=$(echo -n "$vmjson" | base64 -w0)
        local link="vmess://${b64}"
        ALL_LINKS+=("$link")
        cat >> "$SB_INFO" <<INFO
  [VMess-WS #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port}
    UUID     : ${uuid}
    路径     : ${ws_path}
    链接     : ${link}
INFO
    done
    users_json+="]"

    local inbound
    inbound=$(jq -n \
        --argjson port  "$port" \
        --argjson users "$users_json" \
        --arg     path  "$ws_path" \
        '{type:"vmess",tag:"vmess-ws-in",listen:"::",listen_port:$port,
           users:$users,transport:{type:"ws",path:$path}}')
    ALL_INBOUNDS+=("$inbound")
    ask_inbound_route_mode "vmess-ws-in" "VMess-WS" || return 1

    open_port "$port" tcp
    info "✓ VMess-WS | 端口:$port | 路径:$ws_path | 用户数:$user_count"
}

# ────── 协议 4: Trojan + TLS ──────
deploy_trojan() {
    step "配置 Trojan + TLS"
    local port; ask "监听端口 (回车默认443):"; read -r port; [[ -z "$port" ]] && port=443
    require_valid_port "$port" "监听端口" || return 1
    port=$(normalize_port "$port")
    reserve_port "$port"
    select_tls_cert_mode "TLS 证书" || return 1
    local masq_domain="$SELECTED_TLS_DOMAIN"
    local cert_path="$SELECTED_TLS_CERT_PATH"
    local key_path="$SELECTED_TLS_KEY_PATH"
    local insecure="$SELECTED_TLS_INSECURE"

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local idx=0
    for i in $(seq 1 "$user_count"); do
        local pwd; pwd=$(gen_rand_str 24)
        [[ $idx -gt 0 ]] && users_json+=","
        (( idx++ )) || true
        users_json+="{\"password\":\"${pwd}\"}"
        local ins_param=""; [[ "$insecure" == "true" ]] && ins_param="&allowInsecure=1"
        local connect_host; connect_host=$(url_host "$CONNECT_ADDR")
        local link="trojan://${pwd}@${connect_host}:${port}?sni=${masq_domain}${ins_param}#VOLSB-Trojan-${i}-${port}"
        ALL_LINKS+=("$link")
        cat >> "$SB_INFO" <<INFO
  [Trojan #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port}
    密码     : ${pwd}
    SNI      : ${masq_domain}
    跳过验证 : ${insecure}
    链接     : ${link}
INFO
    done
    users_json+="]"

    local inbound
    inbound=$(jq -n \
        --argjson port  "$port" \
        --argjson users "$users_json" \
        --arg     cert  "$cert_path" \
        --arg     key   "$key_path" \
        '{type:"trojan",tag:"trojan-in",listen:"::",listen_port:$port,
           users:$users,tls:{enabled:true,certificate_path:$cert,key_path:$key}}')
    ALL_INBOUNDS+=("$inbound")
    ask_inbound_route_mode "trojan-in" "Trojan" || return 1

    open_port "$port" tcp
    info "✓ Trojan | 端口:$port | 用户数:$user_count"
}

# ────── 协议 4.5: TUIC ──────
deploy_tuic() {
    step "配置 TUIC"

    local port; ask "监听端口 (回车随机):"; read -r port
    [[ -z "$port" ]] && port=$(random_port)
    require_valid_port "$port" "监听端口" || return 1
    port=$(normalize_port "$port")
    reserve_port "$port"

    select_tls_cert_mode "TLS 证书" || return 1
    local masq_domain="$SELECTED_TLS_DOMAIN"
    local cert_path="$SELECTED_TLS_CERT_PATH"
    local key_path="$SELECTED_TLS_KEY_PATH"
    local insecure="$SELECTED_TLS_INSECURE"

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local idx=0
    for i in $(seq 1 "$user_count"); do
        local uuid pwd
        uuid=$(gen_uuid)
        pwd=$(gen_rand_str 24)
        [[ $idx -gt 0 ]] && users_json+=","
        (( idx++ )) || true
        users_json+=$(printf '{"name":"user%s","uuid":"%s","password":"%s"}' "$i" "$uuid" "$pwd")
        local link_host; link_host=$(url_host "$CONNECT_ADDR")
        local ins_param=""
        [[ "$insecure" == "true" ]] && ins_param="&allow_insecure=1"
        local link="tuic://${uuid}:${pwd}@${link_host}:${port}/?udp_relay_mode=native&congestion_control=bbr&alpn=h3&sni=${masq_domain}${ins_param}#VOLSB-TUIC-${i}-${port}"
        ALL_LINKS+=("$link")
        cat >> "$SB_INFO" <<INFO
  [TUIC #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port} (UDP)
    UUID     : ${uuid}
    密码     : ${pwd}
    SNI      : ${masq_domain}
    跳过验证 : ${insecure}
    链接     : ${link}
INFO
    done
    users_json+="]"

    local inbound
    inbound=$(jq -n \
        --argjson port  "$port" \
        --argjson users "$users_json" \
        --arg     cert  "$cert_path" \
        --arg     key   "$key_path" \
        '{type:"tuic",tag:"tuic-in",listen:"::",listen_port:$port,
           users:$users,congestion_control:"bbr",
           tls:{enabled:true,alpn:["h3"],certificate_path:$cert,key_path:$key}}')
    ALL_INBOUNDS+=("$inbound")
    ask_inbound_route_mode "tuic-in" "TUIC" || return 1

    open_port "$port" udp
    info "✓ TUIC | 端口:$port (UDP) | 用户数:$user_count"
}

# ────── 协议 5: ShadowTLS v3 + Shadowsocks ──────
deploy_shadowtls() {
    step "配置 ShadowTLS v3 + Shadowsocks"
    local stls_port sni
    ask "ShadowTLS 监听端口 (回车随机):"; read -r stls_port
    [[ -z "$stls_port" ]] && stls_port=$(random_port)
    require_valid_port "$stls_port" "ShadowTLS 监听端口" || return 1
    stls_port=$(normalize_port "$stls_port")
    reserve_port "$stls_port"
    echo "  推荐 SNI: www.bing.com / www.apple.com / gateway.icloud.com"
    ask "伪装 SNI [默认 www.bing.com]:"; read -r sni; [[ -z "$sni" ]] && sni="www.bing.com"

    local ss_port; ss_port=$(random_port)
    require_valid_port "$ss_port" "Shadowsocks 内层端口" || return 1
    reserve_port "$ss_port"
    ask_multi_user_count; local user_count="$USER_COUNT"
    local stls_users="["; local ss_users="["; local idx=0

    for i in $(seq 1 "$user_count"); do
        local sp; sp=$(gen_rand_str 32)
        local ssp; ssp=$(gen_rand_str 32)
        [[ $idx -gt 0 ]] && { stls_users+=","; ss_users+=","; }
        (( idx++ )) || true
        stls_users+="{\"name\":\"user${i}\",\"password\":\"${sp}\"}"
        ss_users+="{\"name\":\"user${i}\",\"password\":\"${ssp}\"}"
        cat >> "$SB_INFO" <<INFO
  [ShadowTLS v3 #${i}]
    地址         : ${CONNECT_ADDR}
    ShadowTLS 端口: ${stls_port}
    ShadowTLS 密码: ${sp}
    SS 内层密码  : ${ssp}
    SS 加密      : 2022-blake3-aes-128-gcm
    伪装 SNI     : ${sni}
    [客户端配置见: https://sing-box.sagernet.org/configuration/outbound/shadowtls/]
INFO
    done
    stls_users+="]"; ss_users+="]"

    local stls_inbound ss_inbound
    stls_inbound=$(jq -n \
        --argjson port  "$stls_port" \
        --argjson users "$stls_users" \
        --arg     sni   "$sni" \
        '{type:"shadowtls",tag:"shadowtls-in",listen:"::",listen_port:$port,
           version:3,users:$users,handshake:{server:$sni,server_port:443},
           detour:"ss-backend-in"}')
    ss_inbound=$(jq -n \
        --argjson port  "$ss_port" \
        --argjson users "$ss_users" \
        '{type:"shadowsocks",tag:"ss-backend-in",listen:"127.0.0.1",
           listen_port:$port,method:"2022-blake3-aes-128-gcm",users:$users}')
    ALL_INBOUNDS+=("$stls_inbound")
    ALL_INBOUNDS+=("$ss_inbound")
    ask_inbound_route_mode "shadowtls-in" "ShadowTLS v3" || return 1

    open_port "$stls_port" tcp
    info "✓ ShadowTLS v3 | 端口:$stls_port | 用户数:$user_count | SNI:$sni"
}

# ────── SS 链接解析（供线路机模式调用）──────
# 解析结果写入 LAND_ADDR LAND_PORT LAND_METHOD LAND_PASS
_parse_ss_link() {
    local ss_link="$1"
    local ss_body; ss_body="${ss_link#ss://}"
    ss_body="${ss_body%%#*}"   # 去掉 #备注

    if ! echo "$ss_body" | grep -q '@'; then
        err "SS 链接格式不正确，应为 ss://...@host:port"; return 1
    fi

    local userinfo hostinfo
    userinfo="${ss_body%@*}"    # method:pwd 或 base64
    hostinfo="${ss_body##*@}"   # host:port

    # 提取 host 和 port（支持 IPv6 [::1]:port）
    if echo "$hostinfo" | grep -q '^\['; then
        LAND_ADDR="${hostinfo%]*}"; LAND_ADDR="${LAND_ADDR#[}"
        LAND_PORT="${hostinfo##*]:}"
    else
        LAND_ADDR="${hostinfo%:*}"
        LAND_PORT="${hostinfo##*:}"
    fi

    # userinfo 含 : 则是明文 method:password，否则是 base64
    if echo "$userinfo" | grep -q ':'; then
        LAND_METHOD="${userinfo%%:*}"
        LAND_PASS="${userinfo#*:}"
    else
        local decoded
        decoded=$(echo "$userinfo" | base64 -d 2>/dev/null || true)
        if [[ -n "$decoded" && "$decoded" == *:* ]]; then
            LAND_METHOD="${decoded%%:*}"
            LAND_PASS="${decoded#*:}"
        else
            err "SS 链接 base64 解析失败，请检查链接"; return 1
        fi
    fi

    if [[ -z "$LAND_ADDR" || -z "$LAND_PORT" || -z "$LAND_METHOD" || -z "$LAND_PASS" ]]; then
        err "SS 链接解析失败: addr=${LAND_ADDR} port=${LAND_PORT} method=${LAND_METHOD}"
        return 1
    fi
    require_valid_port "$LAND_PORT" "SS 链接端口" || return 1
    LAND_PORT=$(normalize_port "$LAND_PORT")
    info "解析成功: ${LAND_METHOD} @ ${LAND_ADDR}:${LAND_PORT}"
}

_parse_ss_link_into() {
    local ss_link="$1" prefix="$2"
    _parse_ss_link "$ss_link" || return 1
    printf -v "${prefix}_ADDR"   '%s' "$LAND_ADDR"
    printf -v "${prefix}_PORT"   '%s' "$LAND_PORT"
    printf -v "${prefix}_METHOD" '%s' "$LAND_METHOD"
    printf -v "${prefix}_PASS"   '%s' "$LAND_PASS"
}

_ss_outbound_json() {
    local tag="$1" addr="$2" port="$3" method="$4" pass="$5"
    require_valid_port "$port" "SS 出站端口" || return 1
    local port_int; port_int=$(normalize_port "$port")
    jq -n \
        --arg tag "$tag" \
        --arg server "$addr" \
        --argjson port "$port_int" \
        --arg method "$method" \
        --arg password "$pass" \
        '{type:"shadowsocks",tag:$tag,server:$server,server_port:$port,
          method:$method,password:$password}'
}

_ai_default_items() {
    cat <<'EOF'
geosite:openai,
geosite:anthropic,
domain:openai.com,
domain:chatgpt.com,
domain:oaistatic.com,
domain:oaiusercontent.com,
domain:oaistatsig.com,
domain:chat.com,
domain:sora.com,
domain:chatgpt.livekit.cloud,
domain:host.livekit.cloud,
domain:turn.livekit.cloud,
domain:anthropic.com,
domain:claude.ai,
domain:claude.com,
domain:clau.de,
domain:anthropic.auth0.com,
domain:anthropic-com.ghost.io,
domain:anthropic.com.cdn.cloudflare.net,
domain:claudemcpclient.com,
domain:claudemcpcontent.com,
domain:claudeusercontent.com,
full:servd-anthropic-website.b-cdn.net,
domain:statsigapi.net,
full:api.statsig.com,
full:o33249.ingest.sentry.io,
full:browser-intake-datadoghq.com,
full:rum.browser-intake-datadoghq.com,
domain:perplexity.ai,
domain:grok.com,
domain:x.ai,
domain:mistral.ai,
domain:meta.ai,
domain:ai.meta.com,
domain:character.ai,
domain:poe.com,
domain:cohere.com,
domain:cohere.ai,
domain:huggingface.co,
domain:hf.co,
domain:huggingfaceusercontent.com,
domain:hf.space,
domain:aistudio.google.com,
domain:generativelanguage.googleapis.com,
domain:ai.google.dev,
domain:gemini.google.com,
domain:midjourney.com,
domain:pixpix.com
EOF
}

_ai_domains_json() {
    local raw="${ROUTE_AI_ITEMS:-$(_ai_default_items)}"
    jq -Rn --arg raw "$raw" '
      def trim: gsub("^\\s+|\\s+$"; "");
      def host:
        trim
        | sub("^https?://"; "")
        | sub("^//"; "")
        | split("/")[0]
        | split("?")[0]
        | split("#")[0]
        | sub(":[0-9]+$"; "")
        | sub("^\\*\\."; "")
        | ascii_downcase
        | trim;

      ($raw | gsub("\n"; ",") | split(",") | map(trim) | map(select(length > 0))) as $items
      | reduce $items[] as $item (
          {domains: [], suffixes: [], keywords: []};
          if ($item | ascii_downcase | startswith("geosite:")) then
            ($item | sub("^[Gg][Ee][Oo][Ss][Ii][Tt][Ee]:"; "") | trim | ascii_downcase) as $site
            | if $site == "openai" then
                .domains += ["openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com"]
                | .suffixes += [".openai.com", ".chatgpt.com", ".oaistatic.com", ".oaiusercontent.com"]
              elif $site == "anthropic" then
                .domains += ["anthropic.com", "api.anthropic.com", "cdn.anthropic.com", "console.anthropic.com", "mcp.anthropic.com", "workbench.anthropic.com", "anthropic.auth0.com", "anthropic-com.ghost.io", "servd-anthropic-website.b-cdn.net", "claude.ai", "claude.com", "clau.de", "claudemcpclient.com", "claudemcpcontent.com", "claudeusercontent.com", "sentry.io", "statsigapi.net", "api.statsig.com", "events.statsigapi.net"]
                | .suffixes += [".anthropic.com", ".api.anthropic.com", ".cdn.anthropic.com", ".console.anthropic.com", ".mcp.anthropic.com", ".workbench.anthropic.com", ".anthropic.auth0.com", ".anthropic-com.ghost.io", ".servd-anthropic-website.b-cdn.net", ".claude.ai", ".claude.com", ".clau.de", ".claudemcpclient.com", ".claudemcpcontent.com", ".claudeusercontent.com", ".sentry.io", ".statsigapi.net", ".api.statsig.com", ".events.statsigapi.net"]
                | .keywords += ["datadog", "sentry", "sift"]
              else .
              end
          elif ($item | ascii_downcase | test("^(keyword|domain_keyword|domain-keyword):")) then
            ($item
              | sub("^[Kk][Ee][Yy][Ww][Oo][Rr][Dd]:"; "")
              | sub("^[Dd][Oo][Mm][Aa][Ii][Nn][_-][Kk][Ee][Yy][Ww][Oo][Rr][Dd]:"; "")
              | trim | ascii_downcase) as $keyword
            | if $keyword == "" then . else .keywords += [$keyword] end
          elif ($item | ascii_downcase | startswith("full:")) then
            ($item | sub("^[Ff][Uu][Ll][Ll]:"; "") | host) as $domain
            | if $domain == "" then . else .domains += [$domain] end
          elif ($item | ascii_downcase | startswith("domain:")) then
            ($item | sub("^[Dd][Oo][Mm][Aa][Ii][Nn]:"; "") | host) as $domain
            | if $domain == "" then .
              else .domains += [$domain] | .suffixes += [("." + $domain)]
              end
          else
            ($item | host) as $domain
            | if $domain == "" then .
              else .domains += [$domain] | .suffixes += [("." + $domain)]
              end
          end
        )
      | {
          domains: (.domains | unique),
          suffixes: (
            (.suffixes | unique) as $suffixes
            | [ $suffixes[] as $s
                | select([ $suffixes[] as $other | select($other != $s and ($s | endswith($other))) ] | length == 0)
                | $s
              ]
          ),
          keywords: (.keywords | unique)
        }'
}

reset_route_profile() {
    ROUTE_HOME_ADDR=""; ROUTE_HOME_PORT=""; ROUTE_HOME_METHOD=""; ROUTE_HOME_PASS=""
    ROUTE_AI_ADDR=""; ROUTE_AI_PORT=""; ROUTE_AI_METHOD=""; ROUTE_AI_PASS=""
    ROUTE_AI_TAG="ss-ai"
    ROUTE_AI_ITEMS=""
    ROUTE_SS_CONFIGURED=false
    ROUTE_BASE_OUTBOUNDS_JSON=""
    ROUTE_BASE_ROUTE_JSON=""
    ROUTE_DIRECT_TAGS=()
    ROUTE_HOME_TAGS=()
    ROUTE_SPLIT_TAGS=()
    ROUTE_SPLIT_UDP_DIRECT_TAGS=()
    ROUTE_SPLIT_DIRECT_TAGS=()
}

ensure_route_ai_config() {
    $ROUTE_SS_CONFIGURED && return 0

    local ai_link="${VOLSB_AI_SS:-${VOLSB_JP_AI_SS:-${VOLSB_SS_AI_LINK:-}}}"
    while [[ -z "$ai_link" ]]; do
        ask "粘贴 AI 日本家宽 SS 链接 (ss://...):"; read -r ai_link
        [[ "$ai_link" == ss://* ]] || { err "请输入 ss:// 开头的链接"; ai_link=""; }
    done
    _parse_ss_link_into "$ai_link" "ROUTE_AI" || return 1

    local ai_extra="${VOLSB_AI_EXTRA:-${VOLSB_AI_DOMAINS:-${VOLSB_AI_RULES:-}}}"
    if [[ -n "${VOLSB_AI_SPEC:-}" ]]; then
        ROUTE_AI_ITEMS="$VOLSB_AI_SPEC"
    else
        ROUTE_AI_ITEMS="$(_ai_default_items)"
        if [[ -z "$ai_extra" ]]; then
            ask "追加 AI 域名/geosite? 逗号分隔，回车跳过:"; read -r ai_extra
        fi
        [[ -n "$ai_extra" ]] && ROUTE_AI_ITEMS="${ROUTE_AI_ITEMS},${ai_extra}"
    fi
    ROUTE_SS_CONFIGURED=true
}

ensure_route_ss_config() {
    ensure_route_ai_config || return 1

    if [[ -z "$ROUTE_HOME_ADDR" || -z "$ROUTE_HOME_PORT" || -z "$ROUTE_HOME_METHOD" || -z "$ROUTE_HOME_PASS" ]]; then
        local home_link="${VOLSB_HOME_SS:-${VOLSB_HK_HOME_SS:-${VOLSB_SS_HOME_LINK:-}}}"
        while [[ -z "$home_link" ]]; do
            ask "粘贴香港家宽默认出口 SS 链接 (ss://...):"; read -r home_link
            [[ "$home_link" == ss://* ]] || { err "请输入 ss:// 开头的链接"; home_link=""; }
        done
        _parse_ss_link_into "$home_link" "ROUTE_HOME" || return 1
    fi

    cat >> "$SB_INFO" <<INFO

  [分流系统]
    模式     : AI → 日本家宽 SS，其余 → 香港家宽 SS
    AI 出口  : ${ROUTE_AI_METHOD} @ ${ROUTE_AI_ADDR}:${ROUTE_AI_PORT} (${ROUTE_AI_TAG})
    默认出口 : ${ROUTE_HOME_METHOD} @ ${ROUTE_HOME_ADDR}:${ROUTE_HOME_PORT} (ss-home)
INFO
}

ensure_route_home_config() {
    if [[ -z "$ROUTE_HOME_ADDR" || -z "$ROUTE_HOME_PORT" || -z "$ROUTE_HOME_METHOD" || -z "$ROUTE_HOME_PASS" ]]; then
        local home_link="${VOLSB_HOME_SS:-${VOLSB_HK_HOME_SS:-${VOLSB_SS_HOME_LINK:-}}}"
        while [[ -z "$home_link" ]]; do
            ask "粘贴香港家宽 SS 链接 (ss://...):"; read -r home_link
            [[ "$home_link" == ss://* ]] || { err "请输入 ss:// 开头的链接"; home_link=""; }
        done
        _parse_ss_link_into "$home_link" "ROUTE_HOME" || return 1
    fi

    cat >> "$SB_INFO" <<INFO

  [出口系统]
    模式     : 全部流量 → SS 家宽
    默认出口 : ${ROUTE_HOME_METHOD} @ ${ROUTE_HOME_ADDR}:${ROUTE_HOME_PORT} (ss-home)
INFO
}

record_route_ai_direct_info() {
    cat >> "$SB_INFO" <<INFO

  [分流系统]
    模式     : AI → SS，其余 → VPS 直连
    AI 出口  : ${ROUTE_AI_METHOD} @ ${ROUTE_AI_ADDR}:${ROUTE_AI_PORT} (${ROUTE_AI_TAG})
    默认出口 : direct
INFO
}

record_route_ai_home_udp_direct_info() {
    cat >> "$SB_INFO" <<INFO

  [分流系统]
    模式     : AI → SS，TCP 默认 → SS 家宽，UDP 默认 → VPS 直连
    AI 出口  : ${ROUTE_AI_METHOD} @ ${ROUTE_AI_ADDR}:${ROUTE_AI_PORT} (${ROUTE_AI_TAG})
    TCP默认  : ${ROUTE_HOME_METHOD} @ ${ROUTE_HOME_ADDR}:${ROUTE_HOME_PORT} (ss-home)
    UDP默认  : direct
INFO
}

ask_inbound_route_mode() {
    local tag="$1" label="${2:-$1}"
    local mode="${VOLSB_ROUTE_MODE:-${VOLSB_ROUTE_PROFILE:-}}"
    shift 2 || true
    local tags=("$tag" "$@")

    if [[ -z "$mode" ]]; then
        echo ""
        echo "  节点出口模式: ${label}"
        echo "   1) 直连 VPS 出口"
        echo "   2) 全部 → ss-home"
        echo "   3) AI → ss-ai，其余 → ss-home"
        echo "   4) AI → ss-ai，其余 → 直连 VPS 出口"
        echo "   5) AI → ss-ai，TCP其余 → ss-home，UDP其余 → 直连 VPS 出口"
        echo "   0) 返回上一级"
        ask "选择 [0-5] 默认1:"; read -r mode
        [[ "$mode" == "0" ]] && { info "已返回上一级"; return 1; }
        is_back_choice "$mode" && { info "已返回上一级"; return 1; }
        [[ -z "$mode" ]] && mode="1"
    fi

    case "$mode" in
        2|home|ss|ss-home-all|all-ss-home|all-home)
            ensure_route_home_config || return 1
            ROUTE_HOME_TAGS+=("${tags[@]}")
            info "路由: ${label} → 全部 SS 家宽"
            ;;
        3|ai|ai-ss|ss-home|split|hk-jp)
            ensure_route_ss_config || return 1
            ROUTE_SPLIT_TAGS+=("${tags[@]}")
            info "路由: ${label} → AI 分流 / 默认 SS 家宽"
            ;;
        4|ai-direct|ai-only|split-direct)
            ensure_route_ai_config || return 1
            ROUTE_SPLIT_DIRECT_TAGS+=("${tags[@]}")
            record_route_ai_direct_info
            info "路由: ${label} → AI 转发 / 默认 VPS 直连"
            ;;
        5|ai-ss-udp-direct|udp-direct|split-udp-direct)
            ensure_route_ss_config || return 1
            ROUTE_SPLIT_UDP_DIRECT_TAGS+=("${tags[@]}")
            record_route_ai_home_udp_direct_info
            info "路由: ${label} → AI 分流 / TCP 默认 SS 家宽 / UDP 默认 VPS 直连"
            ;;
        *)
            ROUTE_DIRECT_TAGS+=("${tags[@]}")
            info "路由: ${label} → 直连 VPS 出口"
            ;;
    esac
}

_tag_exists_in_list() {
    local needle="$1"; shift || true
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

_replace_first_route_tag() {
    local old_tag="$1" new_tag="$2"
    local i
    for i in "${!ROUTE_SPLIT_TAGS[@]}"; do
        if [[ "${ROUTE_SPLIT_TAGS[$i]}" == "$old_tag" ]]; then
            ROUTE_SPLIT_TAGS[$i]="$new_tag"
            return 0
        fi
    done
    for i in "${!ROUTE_DIRECT_TAGS[@]}"; do
        if [[ "${ROUTE_DIRECT_TAGS[$i]}" == "$old_tag" ]]; then
            ROUTE_DIRECT_TAGS[$i]="$new_tag"
            return 0
        fi
    done
    for i in "${!ROUTE_HOME_TAGS[@]}"; do
        if [[ "${ROUTE_HOME_TAGS[$i]}" == "$old_tag" ]]; then
            ROUTE_HOME_TAGS[$i]="$new_tag"
            return 0
        fi
    done
    for i in "${!ROUTE_SPLIT_UDP_DIRECT_TAGS[@]}"; do
        if [[ "${ROUTE_SPLIT_UDP_DIRECT_TAGS[$i]}" == "$old_tag" ]]; then
            ROUTE_SPLIT_UDP_DIRECT_TAGS[$i]="$new_tag"
            return 0
        fi
    done
    for i in "${!ROUTE_SPLIT_DIRECT_TAGS[@]}"; do
        if [[ "${ROUTE_SPLIT_DIRECT_TAGS[$i]}" == "$old_tag" ]]; then
            ROUTE_SPLIT_DIRECT_TAGS[$i]="$new_tag"
            return 0
        fi
    done
    return 1
}

build_route_profile_json() {
    if [[ ${#ROUTE_HOME_TAGS[@]} -eq 0 && ${#ROUTE_SPLIT_TAGS[@]} -eq 0 && ${#ROUTE_SPLIT_UDP_DIRECT_TAGS[@]} -eq 0 && ${#ROUTE_SPLIT_DIRECT_TAGS[@]} -eq 0 ]]; then
        ROUTE_OUTBOUNDS_JSON='[
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ]'
        ROUTE_CONFIG_JSON='{
    "final": "direct"
  }'
        return 0
    fi

    local home_out ai_out domains_json domains suffixes keywords home_tags_json split_tags_json split_udp_direct_tags_json split_direct_tags_json direct_tags_json
    if [[ ${#ROUTE_SPLIT_TAGS[@]} -gt 0 || ${#ROUTE_SPLIT_UDP_DIRECT_TAGS[@]} -gt 0 || ${#ROUTE_SPLIT_DIRECT_TAGS[@]} -gt 0 ]]; then
        ai_out=$(_ss_outbound_json "$ROUTE_AI_TAG" "$ROUTE_AI_ADDR" "$ROUTE_AI_PORT" "$ROUTE_AI_METHOD" "$ROUTE_AI_PASS") || return 1
    fi
    if [[ ${#ROUTE_HOME_TAGS[@]} -gt 0 || ${#ROUTE_SPLIT_TAGS[@]} -gt 0 || ${#ROUTE_SPLIT_UDP_DIRECT_TAGS[@]} -gt 0 ]]; then
        home_out=$(_ss_outbound_json "ss-home" "$ROUTE_HOME_ADDR" "$ROUTE_HOME_PORT" "$ROUTE_HOME_METHOD" "$ROUTE_HOME_PASS") || return 1
    fi
    ROUTE_OUTBOUNDS_JSON=$(printf '%s\n%s\n%s\n%s\n' \
        "${ai_out:-}" "${home_out:-}" \
        '{"type":"direct","tag":"direct"}' \
        '{"type":"block","tag":"block"}' | jq -s 'map(select(type == "object"))')

    domains_json=$(_ai_domains_json)
    domains=$(echo "$domains_json" | jq '.domains')
    suffixes=$(echo "$domains_json" | jq '.suffixes')
    keywords=$(echo "$domains_json" | jq '.keywords')
    if [[ ${#ROUTE_HOME_TAGS[@]} -gt 0 ]]; then
        home_tags_json=$(printf '%s\n' "${ROUTE_HOME_TAGS[@]}" | jq -R . | jq -s 'unique')
    else
        home_tags_json="[]"
    fi
    if [[ ${#ROUTE_SPLIT_TAGS[@]} -gt 0 ]]; then
        split_tags_json=$(printf '%s\n' "${ROUTE_SPLIT_TAGS[@]}" | jq -R . | jq -s 'unique')
    else
        split_tags_json="[]"
    fi
    if [[ ${#ROUTE_SPLIT_UDP_DIRECT_TAGS[@]} -gt 0 ]]; then
        split_udp_direct_tags_json=$(printf '%s\n' "${ROUTE_SPLIT_UDP_DIRECT_TAGS[@]}" | jq -R . | jq -s 'unique')
    else
        split_udp_direct_tags_json="[]"
    fi
    if [[ ${#ROUTE_SPLIT_DIRECT_TAGS[@]} -gt 0 ]]; then
        split_direct_tags_json=$(printf '%s\n' "${ROUTE_SPLIT_DIRECT_TAGS[@]}" | jq -R . | jq -s 'unique')
    else
        split_direct_tags_json="[]"
    fi
    if [[ ${#ROUTE_DIRECT_TAGS[@]} -gt 0 ]]; then
        direct_tags_json=$(printf '%s\n' "${ROUTE_DIRECT_TAGS[@]}" | jq -R . | jq -s 'unique')
    else
        direct_tags_json="[]"
    fi
    ROUTE_CONFIG_JSON=$(jq -n \
        --arg ai_tag "$ROUTE_AI_TAG" \
        --arg final_tag "ss-home" \
        --arg split_direct_final_tag "direct" \
        --argjson domains "$domains" \
        --argjson suffixes "$suffixes" \
        --argjson keywords "$keywords" \
        --argjson home_tags "$home_tags_json" \
        --argjson split_tags "$split_tags_json" \
        --argjson split_udp_direct_tags "$split_udp_direct_tags_json" \
        --argjson split_direct_tags "$split_direct_tags_json" \
        --argjson direct_tags "$direct_tags_json" \
        '(if ($home_tags | length) > 0 then [
          {inbound:$home_tags,action:"route",outbound:$final_tag}
        ] else [] end) as $home_rules
        | (if ($split_tags | length) > 0 then [
          {inbound:$split_tags,action:"sniff",timeout:"1s"},
          {inbound:$split_tags,domain:$domains,domain_suffix:$suffixes,domain_keyword:$keywords,action:"route",outbound:$ai_tag},
          {inbound:$split_tags,action:"route",outbound:$final_tag}
        ] else [] end) as $split_ss_rules
        | (if ($split_udp_direct_tags | length) > 0 then [
          {inbound:$split_udp_direct_tags,action:"sniff",timeout:"1s"},
          {inbound:$split_udp_direct_tags,domain:$domains,domain_suffix:$suffixes,domain_keyword:$keywords,action:"route",outbound:$ai_tag},
          {inbound:$split_udp_direct_tags,network:"udp",action:"route",outbound:"direct"},
          {inbound:$split_udp_direct_tags,action:"route",outbound:$final_tag}
        ] else [] end) as $split_udp_direct_rules
        | (if ($split_direct_tags | length) > 0 then [
          {inbound:$split_direct_tags,action:"sniff",timeout:"1s"},
          {inbound:$split_direct_tags,domain:$domains,domain_suffix:$suffixes,domain_keyword:$keywords,action:"route",outbound:$ai_tag},
          {inbound:$split_direct_tags,action:"route",outbound:$split_direct_final_tag}
        ] else [] end) as $split_direct_rules
        | ($direct_tags | length) as $direct_count
        | {rules:($home_rules + $split_ss_rules + $split_udp_direct_rules + $split_direct_rules + (if $direct_count > 0 then [{inbound:$direct_tags,action:"route",outbound:"direct"}] else [] end)),
           final:"direct"}')
}

merge_route_profile_json() {
    [[ -n "$ROUTE_BASE_OUTBOUNDS_JSON" && -n "$ROUTE_BASE_ROUTE_JSON" ]] || return 0

    ROUTE_OUTBOUNDS_JSON=$(jq -n \
        --argjson old "$ROUTE_BASE_OUTBOUNDS_JSON" \
        --argjson new "$ROUTE_OUTBOUNDS_JSON" \
        'reduce (($old // []) + ($new // []))[] as $out ([];
          ($out.tag // "") as $tag
          | if $tag == "" then . + [$out]
            else [ .[] | select((.tag // "") != $tag) ] + [$out]
            end
        )') || return 1

    ROUTE_CONFIG_JSON=$(jq -n \
        --argjson old "$ROUTE_BASE_ROUTE_JSON" \
        --argjson new "$ROUTE_CONFIG_JSON" \
        '($old // {}) as $old_route
        | ($new // {}) as $new_route
        | $old_route + $new_route
        | .rules = (($old_route.rules // []) + ($new_route.rules // []))
        | .final = ($new_route.final // $old_route.final // "direct")') || return 1
}

# ════════════════════════════════════════════════════════════
#  线路机 (中转机) 模式
#  原理: VLESS-Reality 入站 → Shadowsocks 出站 → 落地机
# ════════════════════════════════════════════════════════════

deploy_relay() {
    step "线路机模式部署"
    echo ""
    warn "线路机模式: 本机接收 VLESS-Reality 流量,转发至落地机 Shadowsocks 节点"
    echo ""

    # 初始化节点信息文件
    cat > "$SB_INFO" <<INFOHEADER
==============================================
  VOLSB — 线路机节点信息
  更新时间 : $(date '+%Y-%m-%d %H:%M:%S')
==============================================
INFOHEADER
    : > "$SB_LINKS"
    secure_sensitive_files

    # ── 落地机信息 ──
    banner "落地机 (Shadowsocks) 信息"
    echo ""
    echo "  输入方式:"
    echo "   1) 粘贴 SS 链接  (ss://...)"
    echo "   2) 手动输入"
    echo "   0) 返回上一级"
    echo ""

    # 循环直到得到合法输入
    local ss_link=""
    while true; do
        ask "选择 [0/1/2]，或直接粘贴 SS 链接:"; read -r ss_input_raw
        [[ -z "$ss_input_raw" ]] && ss_input_raw="1"
        if [[ "$ss_input_raw" == "0" ]] || is_back_choice "$ss_input_raw"; then
            info "已返回上一级"; return 1
        fi

        if [[ "$ss_input_raw" == ss://* ]]; then
            # 直接粘贴了 SS 链接
            ss_link="$ss_input_raw"; break
        elif [[ "$ss_input_raw" == "1" ]]; then
            ask "粘贴 SS 链接:"; read -r ss_link
            [[ "$ss_link" == ss://* ]] && break
            err "请输入 ss:// 开头的链接"; ss_link=""
        elif [[ "$ss_input_raw" == "2" ]]; then
            ss_link=""; break   # 手动输入模式
        else
            err "无效输入，请输入 1、2 或直接粘贴 ss:// 链接"
        fi
    done

    if [[ -n "$ss_link" ]]; then
        # ── 解析 SS 链接 ──
        _parse_ss_link "$ss_link" || return 1
    else
        # ── 手动输入 ──
        ask "落地机 IP 或域名:"; read -r LAND_ADDR
        [[ -z "$LAND_ADDR" ]] && { err "落地机地址不能为空"; return 1; }
        ask "落地机 SS 端口:"; read -r LAND_PORT
        [[ -z "$LAND_PORT" ]] && { err "落地机端口不能为空"; return 1; }
        require_valid_port "$LAND_PORT" "落地机 SS 端口" || return 1
        LAND_PORT=$(normalize_port "$LAND_PORT")
        ask "落地机 SS 密码:"; read -r LAND_PASS
        [[ -z "$LAND_PASS" ]] && { err "落地机密码不能为空"; return 1; }
        echo "  加密方式:  1) 2022-blake3-aes-128-gcm (推荐)  2) aes-256-gcm  3) chacha20-ietf-poly1305"
        ask "选择 [1-3] 默认1:"; read -r enc_choice
        case "${enc_choice:-1}" in
            2) LAND_METHOD="aes-256-gcm" ;;
            3) LAND_METHOD="chacha20-ietf-poly1305" ;;
            *)  LAND_METHOD="2022-blake3-aes-128-gcm" ;;
        esac
    fi

    # ── 线路机入站 (VLESS-Reality) ──
    banner "线路机入站配置"
    ask_relay_connect_addr || return 1  # 获取线路机自身公网IP

    local in_port sni
    ask "入站端口 (回车随机):"; read -r in_port; [[ -z "$in_port" ]] && in_port=$(random_port)
    require_valid_port "$in_port" "入站端口" || return 1
    in_port=$(normalize_port "$in_port")
    reserve_port "$in_port"
    echo "  SNI 推荐: www.cloudflare.com / www.microsoft.com"
    ask "伪装 SNI [默认 www.cloudflare.com]:"; read -r sni; [[ -z "$sni" ]] && sni="www.cloudflare.com"

    local keypair; keypair=$("$SB_BIN" generate reality-keypair)
    local priv_key; priv_key=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
    local pub_key;  pub_key=$(echo  "$keypair" | awk '/PublicKey/{print $2}')

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local short_ids="["; local idx=0

    for i in $(seq 1 "$user_count"); do
        local uuid; uuid=$(gen_uuid)
        local sid; sid=$(gen_rand_hex 8)
        [[ $idx -gt 0 ]] && { users_json+=","; short_ids+=","; }
        (( idx++ )) || true
        users_json+="{\"uuid\":\"${uuid}\",\"flow\":\"xtls-rprx-vision\"}"
        short_ids+="\"${sid}\""
        local connect_host; connect_host=$(url_host "$CONNECT_ADDR")
        local link="vless://${uuid}@${connect_host}:${in_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${sid}&type=tcp#VOLSB-Relay-${i}-${in_port}"
        ALL_LINKS+=("$link")
        cat >> "$SB_INFO" <<INFO
  [线路机 VLESS-Reality #${i}]
    连接地址  : ${CONNECT_ADDR}
    端口      : ${in_port}
    UUID      : ${uuid}
    PublicKey : ${pub_key}
    ShortID   : ${sid}
    落地机    : ${LAND_ADDR}:${LAND_PORT}
    链接      : ${link}
INFO
    done
    users_json+="]"; short_ids+="]"

    # ── 写入配置 ──
    mkdir -p "$SB_CONF_DIR" || return 1
    secure_sensitive_files

    # LAND_PORT 必须是纯整数
    require_valid_port "$LAND_PORT" "落地机端口" || return 1
    local land_port_int; land_port_int=$(normalize_port "$LAND_PORT")

    local tmp_config; tmp_config=$(mktemp "${SB_CONF_DIR}/config.json.XXXXXX") || return 1
    cat > "$tmp_config" <<JSON
{
  "log": {"level": "warn", "output": "${SB_LOG}", "timestamp": true},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-relay-in",
      "listen": "::",
      "listen_port": ${in_port},
      "users": ${users_json},
      "multiplex": {
        "enabled": true,
        "padding": true
      },
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": {"server": "${sni}", "server_port": 443},
          "private_key": "${priv_key}",
          "short_id": ${short_ids}
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-land",
      "server": "${LAND_ADDR}",
      "server_port": ${land_port_int},
      "method": "${LAND_METHOD}",
      "password": "${LAND_PASS}",
      "network": "tcp"
    },
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ],
  "route": {
    "rules": [
      {"inbound": ["vless-relay-in"], "outbound": "ss-land"}
    ],
    "final": "direct"
  }
}
JSON
    chmod 600 "$tmp_config" 2>/dev/null || true

    # 校验配置
    if ! "$SB_BIN" check -c "$tmp_config" 2>/dev/null; then
        err "线路机配置校验失败:"
        "$SB_BIN" check -c "$tmp_config"
        rm -f "$tmp_config"
        return 1
    fi
    mv "$tmp_config" "$SB_CONFIG"
    secure_sensitive_files

    open_port "$in_port" tcp
    info "✓ 线路机配置完成 | 入站端口:$in_port → 落地:${LAND_ADDR}:${land_port_int}"

    # ── 生成回到落地机的一键线路机安装命令 ──
    banner "一键安装命令 (在其他线路机上执行)"
    echo ""
    echo -e "  ${C_YELLOW}以下命令可直接在其他 VPS 上运行,生成相同配置的线路机:${NC}"
    echo ""
    local script_url="$VOLSB_REPO"
    echo -e "  ${C_CYAN}bash <(curl -fsSL ${script_url}) relay \\
    --land-addr '${LAND_ADDR}' \\
    --land-port '${LAND_PORT}' \\
    --land-pass '${LAND_PASS}' \\
    --land-method '${LAND_METHOD}'${NC}"
    echo ""
}

# ════════════════════════════════════════════════════════════
#  配置组装 & 写入
# ════════════════════════════════════════════════════════════

# ────── 协议 6: AnyTLS ──────
deploy_anytls() {
    step "配置 AnyTLS"

    local port cert_path key_path masq_domain insecure="true" tls_mode="cert" link_addr=""
    local reality_priv_key="" reality_pub_key="" reality_short_ids_json="[]"

    if [[ -n "${VOLSB_PORT:-}" ]]; then
        port="$VOLSB_PORT"; info "端口 (环境变量): $port"
    else
        ask "监听端口 (回车随机):"; read -r port
        [[ -z "$port" ]] && port=$(random_port)
    fi
    require_valid_port "$port" "监听端口" || return 1
    port=$(normalize_port "$port")
    reserve_port "$port"

    echo "  TLS 模式:"
    echo "   1) 复用已有证书"
    echo "   2) 自签证书 (客户端需开 insecure)"
    echo "   3) Let's Encrypt 正式证书"
    echo "   4) Reality (无需证书,客户端需支持 AnyTLS + Reality)"
    echo "   0) 返回上一级"
    ask "选择 [0/1/2/3/4] 默认1:"; read -r cchoice
    if [[ "$cchoice" == "0" ]] || is_back_choice "$cchoice"; then
        info "已返回上一级"; return 1
    fi
    [[ -z "$cchoice" ]] && cchoice="1"

    if [[ "$cchoice" == "4" ]]; then
        tls_mode="reality"
        insecure="false"
        echo ""
        echo "  Reality SNI 用于伪装 TLS 握手,建议选目标国大型网站:"
        echo "  推荐: www.cloudflare.com / www.microsoft.com / www.apple.com / www.icloud.com"
        ask "输入 SNI [默认 www.cloudflare.com]:"; read -r masq_domain
        [[ -z "$masq_domain" ]] && masq_domain="www.cloudflare.com"
        local keypair; keypair=$("$SB_BIN" generate reality-keypair)
        reality_priv_key=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
        reality_pub_key=$(echo  "$keypair" | awk '/PublicKey/{print $2}')
    else
        case "$cchoice" in
            1|2|3) : ;;
            *) err "TLS 模式选择无效"; return 1 ;;
        esac
        select_tls_cert_mode_from_choice "$cchoice" || return 1
        masq_domain="$SELECTED_TLS_DOMAIN"
        cert_path="$SELECTED_TLS_CERT_PATH"
        key_path="$SELECTED_TLS_KEY_PATH"
        insecure="$SELECTED_TLS_INSECURE"
        link_addr="$SELECTED_TLS_LINK_ADDR"
    fi
    [[ -z "$link_addr" ]] && link_addr="$CONNECT_ADDR"

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local idx=0
    [[ "$tls_mode" == "reality" ]] && reality_short_ids_json="["

    for i in $(seq 1 "$user_count"); do
        local pwd; pwd=$(gen_rand_str 24)
        local short_id=""
        [[ $idx -gt 0 ]] && {
            users_json+=","
            [[ "$tls_mode" == "reality" ]] && reality_short_ids_json+=","
        }
        (( idx++ )) || true
        users_json+=$(printf '{"name":"user%s","password":"%s"}' "$i" "$pwd")

        if [[ "$tls_mode" == "reality" ]]; then
            short_id=$(gen_rand_hex 8)
            reality_short_ids_json+=$(printf '"%s"' "$short_id")
        fi

        local ins_param=""
        if [[ "$tls_mode" == "reality" ]]; then
            ins_param="&security=reality&fp=chrome&pbk=${reality_pub_key}&sid=${short_id}&type=tcp"
        else
            ins_param="&security=tls&type=tcp"
            [[ "$insecure" == "true" ]] && ins_param+="&insecure=1"
        fi
        local link_host; link_host=$(url_host "$link_addr")
        local link="anytls://${pwd}@${link_host}:${port}?sni=${masq_domain}${ins_param}#VOLSB-AnyTLS-${i}-${port}"
        ALL_LINKS+=("$link")
        local reality_info=""
        if [[ "$tls_mode" == "reality" ]]; then
            local client_server="$link_addr"
            case "$client_server" in
                \[*\]) client_server="${client_server#[}"; client_server="${client_server%]}" ;;
            esac
            local client_json
            client_json=$(jq -n \
                --arg tag "VOLSB-AnyTLS-${i}" \
                --arg server "$client_server" \
                --argjson port "$port" \
                --arg password "$pwd" \
                --arg sni "$masq_domain" \
                --arg public_key "$reality_pub_key" \
                --arg short_id "$short_id" \
                '{type:"anytls",tag:$tag,server:$server,server_port:$port,password:$password,
                  tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},
                  reality:{enabled:true,public_key:$public_key,short_id:$short_id}}}' 2>/dev/null)
            reality_info="    Reality  : yes
    PublicKey: ${reality_pub_key}
    ShortID  : ${short_id}
    客户端JSON:
${client_json}"
        fi

        cat >> "$SB_INFO" <<INFO
  [AnyTLS #${i}]
    地址     : ${CONNECT_ADDR}
    连接地址 : ${link_addr}
    端口     : ${port}
    密码     : ${pwd}
    SNI      : ${masq_domain}
    跳过验证 : ${insecure}
${reality_info}
    链接     : ${link}
INFO
    done
    users_json+="]"
    [[ "$tls_mode" == "reality" ]] && reality_short_ids_json+="]"

    local inbound
    if [[ "$tls_mode" == "reality" ]]; then
        inbound=$(jq -n \
            --argjson port      "$port" \
            --argjson users     "$users_json" \
            --arg     sni       "$masq_domain" \
            --arg     priv_key  "$reality_priv_key" \
            --argjson short_ids "$reality_short_ids_json" \
            '{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,
              users:$users,tls:{enabled:true,server_name:$sni,
              reality:{enabled:true,handshake:{server:$sni,server_port:443},
              private_key:$priv_key,short_id:$short_ids}}}')
    else
        inbound=$(jq -n \
            --argjson port  "$port" \
            --argjson users "$users_json" \
            --arg     cert  "$cert_path" \
            --arg     key   "$key_path" \
            '{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,
              users:$users,tls:{enabled:true,certificate_path:$cert,key_path:$key}}')
    fi
    ALL_INBOUNDS+=("$inbound")
    ask_inbound_route_mode "anytls-in" "AnyTLS" || return 1

    open_port "$port" tcp
    info "✓ AnyTLS | 端口:$port | 用户数:$user_count | TLS:${tls_mode}"
}


select_protocols() {
    clear
    echo -e "${C_BOLD}${C_CYAN}"
    cat <<'BANNER'
  ┌──────────────────────────────────────────────────────┐
  │        VOLSB — 部署机协议选择                        │
  └──────────────────────────────────────────────────────┘
BANNER
    echo -e "${NC}"
    hr
    printf "  ${C_BOLD}%-5s %-30s %-10s %s${NC}\n" "序号" "协议" "传输" "说明"
    hr
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "1)" "VLESS + XTLS-Reality"     "TCP"   "★ 推荐 | 抗审查首选,无需域名"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "2)" "Hysteria2"                "UDP"   "★ 推荐 | 高速UDP,弱网友好"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "3)" "VMess + WebSocket"        "TCP/WS" "适合套 CDN / Nginx 反代"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "4)" "Trojan + TLS"             "TCP"   "经典方案,广泛兼容"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "5)" "ShadowTLS v3 + SS"        "TCP"   "真实 TLS 握手伪装"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "6)" "AnyTLS"                   "TCP"   "TLS伪装,支持 Reality"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "7)" "Shadowsocks"              "TCP/UDP" "经典 SS 节点,直接生成 ss://"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "8)" "TUIC"                     "UDP"   "QUIC 协议,适合弱网"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "0)" "全部协议"                 "-"     "同时部署以上所有"
    hr
    echo ""
    echo -e "  支持多选: ${C_CYAN}1 2${NC}  ${C_CYAN}1 2 4${NC}  ${C_CYAN}7 8${NC}  ${C_CYAN}0${NC}(全部)"
    echo -e "  返回上一级: ${C_CYAN}b${NC}"
    echo ""
    # 支持环境变量 VOLSB_PROTO 跳过交互
    local raw_input="${VOLSB_PROTO:-}"
    if [[ -z "$raw_input" ]]; then
        ask "请选择协议 [0-8 / b返回]:"; read -r raw_input
    else
        info "协议选择 (环境变量): $raw_input"
    fi
    [[ "$raw_input" =~ ^([bBqQ]|back|BACK|返回)$ ]] && { info "已返回上一级"; return 1; }
    [[ -z "$raw_input" ]] && raw_input="1"
    [[ "$raw_input" == "0" ]] && raw_input="1 2 3 4 5 6 7 8"

    SELECTED_PROTOS=()
    for n in $raw_input; do
        case "$n" in
            1) SELECTED_PROTOS+=("vless_reality") ;;
            2) SELECTED_PROTOS+=("hysteria2") ;;
            3) SELECTED_PROTOS+=("vmess_ws") ;;
            4) SELECTED_PROTOS+=("trojan") ;;
            5) SELECTED_PROTOS+=("shadowtls") ;;
            6) SELECTED_PROTOS+=("anytls") ;;
            7) SELECTED_PROTOS+=("ss") ;;
            8) SELECTED_PROTOS+=("tuic") ;;
            *) warn "忽略无效输入: $n" ;;
        esac
    done
    [[ ${#SELECTED_PROTOS[@]} -eq 0 ]] && { warn "未选择任何协议"; return 1; }
    return 0
}

# ────── 写入配置的公共函数 ──────
_write_config() {
    # $1 = inbounds JSON array string
    local inbounds_json="$1"
    build_route_profile_json || return 1
    merge_route_profile_json || return 1
    step "写入配置文件"
    mkdir -p "$SB_CONF_DIR" || return 1
    local tmp_config; tmp_config=$(mktemp "${SB_CONF_DIR}/config.json.XXXXXX") || return 1
    cat > "$tmp_config" <<JSON
{
  "log": {
    "level": "warn",
    "output": "${SB_LOG}",
    "timestamp": true
  },
  "inbounds": ${inbounds_json},
  "outbounds": ${ROUTE_OUTBOUNDS_JSON},
  "route": ${ROUTE_CONFIG_JSON}
}
JSON
    chmod 600 "$tmp_config" 2>/dev/null || true
    # 先注入统计 API，再做最终校验，避免校验后又改动配置。
    traffic_init_api "$tmp_config" || { rm -f "$tmp_config"; return 1; }
    if "$SB_BIN" check -c "$tmp_config" 2>/dev/null; then
        mv "$tmp_config" "$SB_CONFIG"
        secure_sensitive_files
        info "配置写入完成，校验通过"
    else
        err "配置校验失败:"; "$SB_BIN" check -c "$tmp_config"; rm -f "$tmp_config"; return 1
    fi
}

# ────── 初始化节点信息头 ──────
_init_info_header() {
    mkdir -p "$SB_CONF_DIR" || return 1
    cat > "$SB_INFO" <<INFOHEADER
==============================================
  VOLSB — 节点信息
  更新时间 : $(date '+%Y-%m-%d %H:%M:%S')
  服务器   : ${CONNECT_ADDR:-$(get_public_ip)}
==============================================
INFOHEADER
    : > "$SB_LINKS"   # 清空链接文件
    secure_sensitive_files
}

# ────── 全新安装：覆盖所有入站 ──────
assemble_and_write_config() {
    if [[ ! -x "$SB_BIN" ]]; then
        err "sing-box 未安装，请先执行菜单选项 1 安装"; return 1
    fi
    ALL_INBOUNDS=(); ALL_LINKS=()
    _init_info_header
    reset_route_profile

    for proto in "${SELECTED_PROTOS[@]}"; do
        case "$proto" in
            vless_reality) deploy_vless_reality || return 1 ;;
            hysteria2)     deploy_hysteria2 || return 1 ;;
            vmess_ws)      deploy_vmess_ws || return 1 ;;
            trojan)        deploy_trojan || return 1 ;;
            shadowtls)     deploy_shadowtls || return 1 ;;
            anytls)        deploy_anytls || return 1 ;;
            ss)            deploy_shadowsocks || return 1 ;;
            tuic)          deploy_tuic || return 1 ;;
        esac
    done

    local joined; joined=$(printf '%s
' "${ALL_INBOUNDS[@]}" | jq -s '.')
    _write_config "$joined" || return 1
    printf '%s
' "${ALL_LINKS[@]}" > "$SB_LINKS"
    secure_sensitive_files
}

# ────── 追加协议：保留旧入站，合并新入站 ──────
append_and_write_config() {
    if [[ ! -x "$SB_BIN" ]]; then
        err "sing-box 未安装，请先执行菜单选项 1 安装"; return 1
    fi

    # 读出旧的入站 JSON 数组
    local old_inbounds_json="[]"
    if [[ -f "$SB_CONFIG" ]]; then
        old_inbounds_json=$(jq '.inbounds' "$SB_CONFIG" 2>/dev/null) || old_inbounds_json="[]"
    fi

    # 询问是否保留旧节点
    local keep_old=true
    if [[ "$old_inbounds_json" != "[]" && -n "$old_inbounds_json" ]]; then
        local old_count; old_count=$(echo "$old_inbounds_json" | jq 'length' 2>/dev/null || echo 0)
        echo ""
        echo -e "  ${C_BOLD}检测到已有 ${old_count} 个入站节点:${NC}"
        echo "$old_inbounds_json" | jq -r             '.[] | "  - \(.type) 端口:\(.listen_port) [\(.tag)]"' 2>/dev/null || true
        echo ""
        echo "  选项:"
        echo "   1) 保留旧节点，追加新节点（推荐）"
        echo "   2) 清除旧节点，只保留新节点"
        echo "   0) 返回上一级"
        ask "选择 [0/1/2] 默认1:"; read -r keep_choice
        [[ "$keep_choice" == "0" ]] && { info "已返回上一级"; return 1; }
        is_back_choice "$keep_choice" && { info "已返回上一级"; return 1; }
        [[ "${keep_choice:-1}" == "2" ]] && keep_old=false
    fi

    # 生成新入站
    ALL_INBOUNDS=(); ALL_LINKS=()
    local preserved_inbound_count=0

    # 若保留旧节点，先把旧入站塞进 ALL_INBOUNDS
    if $keep_old && [[ "$old_inbounds_json" != "[]" ]]; then
        # 把旧入站每个元素拆出来加入数组
        local old_count; old_count=$(echo "$old_inbounds_json" | jq 'length' 2>/dev/null || echo 0)
        local oi=0
        while [[ $oi -lt $old_count ]]; do
            local ib; ib=$(echo "$old_inbounds_json" | jq ".[$oi]" 2>/dev/null)
            ALL_INBOUNDS+=("$ib")
            (( oi++ )) || true
        done
        preserved_inbound_count="$old_count"
        # 同时保留旧链接
        if [[ -f "$SB_LINKS" ]]; then
            while IFS= read -r lnk; do
                [[ -n "$lnk" ]] && ALL_LINKS+=("$lnk")
            done < "$SB_LINKS"
        fi
        info "已保留 ${old_count} 个旧入站"
    fi

    # 重置 SB_INFO 头，但追加模式下先把旧 SB_INFO 内容（节点详情）保留
    local old_info_body=""
    if $keep_old && [[ -f "$SB_INFO" ]]; then
        # 跳过头部（前5行），保留节点详情
        old_info_body=$(tail -n +6 "$SB_INFO" 2>/dev/null || true)
    fi
    reset_route_profile
    if $keep_old && [[ -f "$SB_CONFIG" ]]; then
        ROUTE_BASE_OUTBOUNDS_JSON=$(jq '.outbounds // []' "$SB_CONFIG" 2>/dev/null || echo "[]")
        ROUTE_BASE_ROUTE_JSON=$(jq '.route // {"final":"direct"}' "$SB_CONFIG" 2>/dev/null || echo '{"final":"direct"}')
    fi
    _init_info_header
    [[ -n "$old_info_body" ]] && echo "$old_info_body" >> "$SB_INFO"

    # 部署新协议
    for proto in "${SELECTED_PROTOS[@]}"; do
        case "$proto" in
            vless_reality) deploy_vless_reality || return 1 ;;
            hysteria2)     deploy_hysteria2 || return 1 ;;
            vmess_ws)      deploy_vmess_ws || return 1 ;;
            trojan)        deploy_trojan || return 1 ;;
            shadowtls)     deploy_shadowtls || return 1 ;;
            anytls)        deploy_anytls || return 1 ;;
            ss)            deploy_shadowsocks || return 1 ;;
            tuic)          deploy_tuic || return 1 ;;
        esac
    done

    # 检查 tag 重复（同类型入站 tag 要唯一）
    local all_tags; all_tags=$(printf '%s
' "${ALL_INBOUNDS[@]}" | jq -r '.tag // ""' 2>/dev/null)
    local unique_tags; unique_tags=$(echo "$all_tags" | sort -u | wc -l | tr -d ' ')
    local total_tags; total_tags=$(echo "$all_tags" | wc -l | tr -d ' ')
    if [[ "$unique_tags" -lt "$total_tags" ]]; then
        warn "检测到重复的入站 tag，自动重命名..."
        local fixed_inbounds=()
        local seen_tags=()
        local idx=0
        for ib in "${ALL_INBOUNDS[@]}"; do
            local t; t=$(echo "$ib" | jq -r '.tag // ""' 2>/dev/null)
            local new_tag="$t"
            if [[ -n "$t" ]] && _tag_exists_in_list "$new_tag" "${seen_tags[@]}"; then
                local suffix=2
                while _tag_exists_in_list "${t}-${suffix}" "${seen_tags[@]}"; do
                    (( suffix++ )) || true
                done
                new_tag="${t}-${suffix}"
                ib=$(echo "$ib" | jq --arg nt "$new_tag" '.tag = $nt' 2>/dev/null)
                if [[ "$idx" -ge "$preserved_inbound_count" ]]; then
                    _replace_first_route_tag "$t" "$new_tag" || true
                fi
                warn "入站 tag ${t} → ${new_tag}"
            fi
            fixed_inbounds+=("$ib")
            seen_tags+=("$new_tag")
            (( idx++ )) || true
        done
        ALL_INBOUNDS=("${fixed_inbounds[@]}")
    fi

    local joined; joined=$(printf '%s
' "${ALL_INBOUNDS[@]}" | jq -s '.')
    _write_config "$joined" || return 1
    printf '%s
' "${ALL_LINKS[@]}" > "$SB_LINKS"
    secure_sensitive_files
    info "共 ${#ALL_INBOUNDS[@]} 个入站节点"
}

# ════════════════════════════════════════════════════════════
#  流量统计
# ════════════════════════════════════════════════════════════

# sing-box 启用 Clash API 后可通过 REST 查询连接/流量
# 同时使用 /proc/net 做端口连接数和网卡统计兜底

SB_STAT_API="127.0.0.1:9090"  # sing-box Clash API 监听地址

traffic_init_api() {
    # 幂等修复 Clash 兼容 API（HTTP，用于连接/流量统计）
    local config_path="${1:-$SB_CONFIG}"
    [[ -f "$config_path" ]] || return 0

    local current api_type
    current=$(jq -r '.experimental.clash_api.external_controller // ""' "$config_path" 2>/dev/null || echo "")
    api_type=$(jq -r '(.experimental.clash_api // empty) | type' "$config_path" 2>/dev/null || echo "")
    if [[ "$current" == "$SB_STAT_API" && "$api_type" == "object" ]]; then
        return 0
    fi

    local tmp; tmp=$(mktemp "${config_path}.api.XXXXXX")
    if ! jq --arg controller "$SB_STAT_API" '
        .experimental = (if (.experimental | type) == "object" then .experimental else {} end)
        | (if (.experimental.clash_api | type) == "object" then .experimental.clash_api else {} end) as $old_api
        | .experimental.clash_api = (
            $old_api + {
                "external_controller": $controller,
                "secret": ($old_api.secret // "")
            }
        )
    ' "$config_path" > "$tmp"; then
        rm -f "$tmp"
        err "Clash API 配置写入失败"
        return 1
    fi
    chmod 600 "$tmp" 2>/dev/null || true

    if [[ -x "$SB_BIN" ]] && ! "$SB_BIN" check -c "$tmp" &>/dev/null; then
        err "注入 Clash API 后配置校验失败，已保留原配置"
        "$SB_BIN" check -c "$tmp" || true
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$config_path"
    [[ "$config_path" == "$SB_CONFIG" ]] && secure_sensitive_files
    info "已启用/修复 Clash API (${SB_STAT_API})"
}

human_bytes() {
    # 清除换行/空格，强制转整数，防止 awk/jq 输出带换行导致比较报错
    local b
    b=$(echo "${1:-0}" | tr -d '[:space:]')
    b=$(( b + 0 )) 2>/dev/null || b=0
    awk -v b="$b" 'BEGIN {
        if (b >= 1073741824)      printf "%.2f GB", b / 1073741824;
        else if (b >= 1048576)    printf "%.2f MB", b / 1048576;
        else if (b >= 1024)       printf "%.2f KB", b / 1024;
        else                      printf "%d B", b;
    }'
}

# 清洗数值：去换行空格，转整数，出错返回0
clean_num() { local v; v=$(echo "${1:-0}" | tr -d '[:space:]'); echo $(( v + 0 )) 2>/dev/null || echo 0; }

traffic_api_ready() {
    local api="${1:-}"
    [[ -n "$api" ]] || return 1
    curl -fsSL --connect-timeout 1 --max-time 2 "http://${api}/version" &>/dev/null \
        || curl -fsSL --connect-timeout 1 --max-time 2 "http://${api}/connections" &>/dev/null
}

traffic_api_snapshot() {
    local api="${1:-}"
    [[ -n "$api" ]] || return 1
    curl -fsSN --connect-timeout 1 --max-time 3 "http://${api}/traffic" 2>/dev/null \
        | awk '/^[[:space:]]*\{/{line=$0} END{print line}'
}

# ════════════════════════════════════════════════════════════
#  时间同步
# ════════════════════════════════════════════════════════════

sync_time() {
    require_root
    step "强制同步系统时间"

    local current_ts; current_ts=$(date +%s)
    echo -e "  当前时间: ${C_CYAN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC} (Unix: ${current_ts})"
    echo ""

    # 尝试多种同步方式
    local synced=false

    # 方法1: systemd-timesyncd (最常见)
    if command -v timedatectl &>/dev/null; then
        echo -n "  [1] timedatectl 同步... "
        timedatectl set-ntp true 2>/dev/null || true
        systemctl restart systemd-timesyncd 2>/dev/null || true
        sleep 2
        if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
            echo -e "${C_GREEN}成功${NC}"
            synced=true
        else
            echo -e "${C_DIM}未完成${NC}"
        fi
    fi

    # 方法2: chrony
    if ! $synced && command -v chronyc &>/dev/null; then
        echo -n "  [2] chrony 强制同步... "
        chronyc makestep 2>/dev/null && synced=true && echo -e "${C_GREEN}成功${NC}" || echo -e "${C_DIM}失败${NC}"
    fi

    # 方法3: ntpdate（直接强制设置）
    if ! $synced && command -v ntpdate &>/dev/null; then
        echo -n "  [3] ntpdate 同步... "
        ntpdate -u pool.ntp.org 2>/dev/null && synced=true && echo -e "${C_GREEN}成功${NC}" || echo -e "${C_DIM}失败${NC}"
    fi

    # 方法4: date + curl 从 HTTP 头获取时间（终极兜底，不需要 ntp 工具）
    if ! $synced; then
        echo -n "  [4] 从 HTTP 时间头同步... "
        local http_date
        http_date=$(curl -fsSI --max-time 5 "https://www.cloudflare.com" 2>/dev/null             | grep -i "^date:" | sed 's/^[Dd]ate: //' | tr -d '
')
        if [[ -n "$http_date" ]]; then
            date -s "$http_date" &>/dev/null && synced=true && echo -e "${C_GREEN}成功${NC}" || echo -e "${C_DIM}失败${NC}"
        else
            echo -e "${C_DIM}失败${NC}"
        fi
    fi

    echo ""
    if $synced; then
        local new_ts; new_ts=$(date +%s)
        local drift=$(( new_ts - current_ts ))
        echo -e "  ${C_GREEN}[✓]${NC} 时间同步完成"
        echo -e "  同步后时间: ${C_GREEN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
        [[ ${drift#-} -gt 2 ]] &&             echo -e "  ${C_YELLOW}[!]${NC} 时间偏差: ${drift} 秒 (2022-blake3 系列要求偏差 < 30秒)" ||             echo -e "  偏差: ${drift} 秒 ${C_GREEN}✓${NC}"
    else
        err "所有同步方式均失败，请手动安装 ntp/chrony 后重试"
        echo "  apt install -y ntp  或  yum install -y ntp"
    fi
}


# ════════════════════════════════════════════════════════════
#  线路机连通性验证
# ════════════════════════════════════════════════════════════

verify_relay() {
    clear
    echo -e "${C_BOLD}${C_CYAN}"
    cat <<'HDR'
  ╔════════════════════════════════════════════════════╗
  ║          VOLSB — 线路机连通性验证                  ║
  ╚════════════════════════════════════════════════════╝
HDR
    echo -e "${NC}"

    local pass=0 fail=0

    _chk() {
        local label="$1" result="$2" expect="$3"
        if [[ "$result" == *"$expect"* ]]; then
            echo -e "  ${C_GREEN}[✓]${NC} ${label}"
            (( pass++ )) || true
        else
            echo -e "  ${C_RED}[✗]${NC} ${label}"
            [[ -n "$result" ]] && echo -e "      ${C_DIM}→ $result${NC}"
            (( fail++ )) || true
        fi
    }

    choose_relay_inbound_port() {
        SELECTED_VERIFY_BACK=0
        local ports=() port port_type port_tag port_listen
        while IFS='|' read -r port_type port port_tag port_listen; do
            [[ -n "$port" && "$port" != "0" ]] || continue
            [[ "$port_listen" == "127.0.0.1" ]] && continue
            ports+=("${port_type}|${port}|${port_tag}|${port_listen}")
        done < <(jq -r '.inbounds[] | [(.type//"unknown"), (.listen_port//0|tostring), (.tag//""), (.listen//"")] | join("|")' "$SB_CONFIG" 2>/dev/null)

        if [[ ${#ports[@]} -eq 0 ]]; then
            echo ""
            return 1
        fi

        echo ""
        echo "  可选入站端口:"
        local i=1 item
        for item in "${ports[@]}"; do
            IFS='|' read -r port_type port port_tag port_listen <<< "$item"
            printf "   %d) %-10s 端口:%-8s 标签:%s\n" "$i" "$port_type" "$port" "${port_tag:-无}"
            (( i++ )) || true
        done

        local choice=""
        ask "选择验证端口 [1-${#ports[@]}]，0返回，回车默认1，或直接输入端口号:"; read -r choice
        [[ -z "$choice" ]] && choice="1"
        [[ "$choice" == "0" ]] && { SELECTED_VERIFY_BACK=1; info "已返回上一级"; return 1; }
        is_back_choice "$choice" && { SELECTED_VERIFY_BACK=1; info "已返回上一级"; return 1; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ports[@]} )); then
            IFS='|' read -r port_type port port_tag port_listen <<< "${ports[$(( choice - 1 ))]}"
            SELECTED_VERIFY_PORT="$port"
            SELECTED_VERIFY_TYPE="$port_type"
            SELECTED_VERIFY_TAG="$port_tag"
            return 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && valid_port "$choice"; then
            SELECTED_VERIFY_PORT="$choice"
            SELECTED_VERIFY_TYPE="manual"
            SELECTED_VERIFY_TAG=""
            return 0
        fi

        err "端口选择无效"
        return 1
    }

    choose_relay_outbounds() {
        local outbounds=() tag addr port method passw network item
        while IFS='|' read -r tag addr port method passw network; do
            [[ -n "$addr" && -n "$port" ]] || continue
            outbounds+=("${tag}|${addr}|${port}|${method}|${passw}|${network}")
        done < <(jq -r '.outbounds[] | select(.type=="shadowsocks") |
            [(.tag//"ss-out"), (.server//""), (.server_port//0|tostring), (.method//""), (.password//""), (.network//"tcp")]
            | join("|")' "$SB_CONFIG" 2>/dev/null)

        if [[ ${#outbounds[@]} -eq 0 ]]; then
            return 1
        fi

        echo ""
        echo "  可检测出站:"
        local i=1
        for item in "${outbounds[@]}"; do
            IFS='|' read -r tag addr port method passw network <<< "$item"
            printf "   %d) %-12s %s:%s (%s)\n" "$i" "${tag:-ss-out}" "$addr" "$port" "$method"
            (( i++ )) || true
        done
        [[ ${#outbounds[@]} -gt 1 ]] && echo "   0) 全部出站"
        echo "   b) 返回上一级"

        local choice default_choice
        default_choice="1"
        [[ ${#outbounds[@]} -gt 1 ]] && default_choice="0"
        if [[ ${#outbounds[@]} -gt 1 ]]; then
            ask "选择出站 [0-${#outbounds[@]}]，0全部 / b返回，回车默认${default_choice}:"
        else
            ask "选择出站 [1-${#outbounds[@]}]，b返回，回车默认${default_choice}:"
        fi
        read -r choice
        [[ -z "$choice" ]] && choice="$default_choice"
        [[ "$choice" =~ ^([bBqQ]|back|BACK|返回)$ ]] && { info "已返回上一级"; return 1; }

        SELECTED_VERIFY_OUTBOUNDS=()
        if [[ "$choice" == "0" && ${#outbounds[@]} -gt 1 ]]; then
            SELECTED_VERIFY_OUTBOUNDS=("${outbounds[@]}")
            return 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#outbounds[@]} )); then
            SELECTED_VERIFY_OUTBOUNDS=("${outbounds[$(( choice - 1 ))]}")
            return 0
        fi

        err "出站选择无效"
        return 1
    }

    verify_one_ss_outbound() {
        local item="$1"
        local land_tag land_addr land_port land_method land_pass_test land_network
        IFS='|' read -r land_tag land_addr land_port land_method land_pass_test land_network <<< "$item"
        [[ -n "$land_tag" ]] || land_tag="ss-out"
        [[ -n "$land_network" ]] || land_network="tcp"

        echo ""
        echo -e "  ${C_BOLD}出站 ${land_tag}:${NC} ${C_CYAN}${land_addr}:${land_port}${NC} (${land_method})"

        echo -n "  TCP 连接 ... "
        if tcp_connect_test "$land_addr" "$land_port"; then
            echo -e "${C_GREEN}成功${NC}"; (( pass++ )) || true
        else
            echo -e "${C_RED}失败${NC}"
            echo -e "  ${C_DIM}→ 请检查该出站防火墙/安全组是否放行 ${land_port} 端口${NC}"
            (( fail++ )) || true
        fi

        if [[ -z "$land_pass_test" ]]; then
            echo -e "  ${C_RED}[✗]${NC} 无法读取密码"; (( fail++ )) || true
        else
            local pass_len decoded_len expected_len=16
            pass_len=${#land_pass_test}
            decoded_len=$(echo "$land_pass_test" | base64 -d 2>/dev/null | wc -c | tr -d ' ') || decoded_len=0
            [[ "$land_method" == *"256"* ]] && expected_len=32

            echo -e "  加密方式 : ${C_CYAN}${land_method}${NC}"
            echo -e "  密码长度 : ${pass_len} 字符"
            if [[ "$land_method" == "2022-"* ]]; then
                echo -e "  Base64解码: ${decoded_len} 字节 (期望 ${expected_len} 字节)"
                if [[ $decoded_len -eq $expected_len ]]; then
                    echo -e "  ${C_GREEN}[✓]${NC} 密码格式正确"
                    (( pass++ )) || true
                else
                    echo -e "  ${C_RED}[✗]${NC} 密码格式错误，2022系列需要 base64(${expected_len}字节随机数)"
                    (( fail++ )) || true
                fi
            else
                echo -e "  ${C_GREEN}[✓]${NC} 非2022系列加密，密码格式无特殊要求"
                (( pass++ )) || true
            fi
        fi

        local land_ip="$land_addr"
        if ! echo "$land_addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|:'; then
            echo -n "  解析域名 ${land_addr} ... "
            local resolved=""
            resolved=$(getent hosts "$land_addr" 2>/dev/null | awk '{print $1; exit}') || true
            [[ -z "$resolved" ]] && \
                resolved=$(nslookup "$land_addr" 2>/dev/null | awk '/^Address:/{print $2}' | grep -v '#' | head -1) || true
            if [[ -n "$resolved" ]]; then
                land_ip="$resolved"; echo -e "${C_GREEN}${land_ip}${NC}"
            else
                echo -e "${C_YELLOW}解析失败，使用域名继续${NC}"
            fi
        fi

        local land_port_int
        if ! valid_port "$land_port"; then
            echo -e "  ${C_RED}[✗]${NC} 出站端口无效: ${land_port}"
            (( fail++ )) || true
            return 0
        fi
        land_port_int=$(normalize_port "$land_port")

        local test_port=19876
        while ss -tuln 2>/dev/null | grep -q ":${test_port} "; do
            (( test_port++ )) || true
        done

        local test_cfg test_log
        test_cfg=$(mktemp /tmp/volsb_test_XXXX.json)
        local safe_tag="${land_tag//[^A-Za-z0-9_.-]/_}"
        test_log="/tmp/volsb_test_${safe_tag}_$$.log"; : > "$test_log"

        jq -n \
            --arg log "$test_log" \
            --arg server "$land_ip" \
            --arg method "$land_method" \
            --arg password "$land_pass_test" \
            --argjson listen_port "$test_port" \
            --argjson server_port "$land_port_int" \
            '{
              log: {level:"debug", output:$log},
              inbounds: [{type:"socks", tag:"test-in", listen:"127.0.0.1", listen_port:$listen_port}],
              outbounds: [
                {type:"shadowsocks", tag:"ss-out", server:$server, server_port:$server_port, method:$method, password:$password, network:"tcp"},
                {type:"direct", tag:"direct"}
              ],
              route: {rules:[{inbound:["test-in"], outbound:"ss-out"}], final:"direct"}
            }' > "$test_cfg"

        if ! "$SB_BIN" check -c "$test_cfg" 2>/dev/null; then
            echo -e "  ${C_RED}[✗]${NC} 临时配置校验失败:"
            "$SB_BIN" check -c "$test_cfg" 2>&1 | grep -v '^$' | head -5 | sed 's/^/       /'
            rm -f "$test_cfg" "$test_log"
            (( fail++ )) || true
            return 0
        fi

        echo "  启动临时测试实例 (socks5://127.0.0.1:${test_port}) ..."
        "$SB_BIN" run -c "$test_cfg" >> "$test_log" 2>&1 &
        local test_pid=$!

        local waited=0
        while ! ss -tuln 2>/dev/null | grep -q ":${test_port} " && [[ $waited -lt 8 ]]; do
            sleep 1; (( waited++ )) || true
        done

        if ! ss -tuln 2>/dev/null | grep -q ":${test_port} "; then
            echo -e "  ${C_RED}[✗]${NC} 临时实例启动失败，错误日志:"
            cat "$test_log" 2>/dev/null | grep -iE "error|fatal" | head -5 | sed 's/^/       /'
            (( fail++ )) || true
        else
            local local_ip="" relay_ip=""
            local_ip=$(curl -fsSL --max-time 6 "https://api.ipify.org" 2>/dev/null | tr -d '[:space:]') || true
            relay_ip=$(curl -fsSL --max-time 30 \
                --socks5-hostname "127.0.0.1:${test_port}" \
                "https://api.ipify.org" 2>/dev/null | tr -d '[:space:]') || true

            if [[ -n "$relay_ip" && "$relay_ip" != "$local_ip" ]]; then
                echo -e "  ${C_GREEN}[✓]${NC} 转发成功"
                echo -e "       本机 IP : ${C_DIM}${local_ip:-未知}${NC}"
                echo -e "       出口 IP : ${C_GREEN}${relay_ip}${NC}  ← ${land_tag}"
                (( pass++ )) || true
            elif [[ -n "$relay_ip" && "$relay_ip" == "$local_ip" ]]; then
                echo -e "  ${C_YELLOW}[!]${NC} 出口 IP 与本机相同，流量可能未经过 ${land_tag}"
                (( fail++ )) || true
            else
                if grep -q "outbound connection" "$test_log" 2>/dev/null; then
                    echo -e "  ${C_YELLOW}[!]${NC} SS 出站已连通，但响应超时"
                    echo -e "       ${C_DIM}→ 连接已建立：线路机 → ${land_tag} → 目标${NC}"
                    (( pass++ )) || true
                else
                    echo -e "  ${C_RED}[✗]${NC} SS 出站连接失败，诊断日志:"
                    grep -iE "error|failed|refused|timeout|reset" "$test_log" 2>/dev/null \
                        | tail -5 | sed 's/^/       /'
                    (( fail++ )) || true
                fi
            fi
        fi

        kill $test_pid 2>/dev/null; wait $test_pid 2>/dev/null
        rm -f "$test_cfg" "$test_log"
    }

    # ── Step 0: 时间偏差预检 ──
    # 用 HTTP 时间头做快速偏差检测
    local http_ts local_ts offset_sec
    http_ts=$(curl -fsSI --max-time 4 "https://www.cloudflare.com" 2>/dev/null         | grep -i "^date:" | sed "s/^[Dd]ate: //" | tr -d "
")
    if [[ -n "$http_ts" ]]; then
        local_ts=$(date +%s)
        http_ts_unix=$(date -d "$http_ts" +%s 2>/dev/null || date -j -f "%a, %d %b %Y %T %Z" "$http_ts" +%s 2>/dev/null || echo "$local_ts")
        offset_sec=$(( local_ts - http_ts_unix )); offset_sec=${offset_sec#-}
        if [[ $offset_sec -gt 30 ]]; then
            echo -e "  ${C_YELLOW}[!]${NC} 系统时间偏差 ${offset_sec} 秒，超过 2022-blake3 允许的 30 秒！"
            echo -e "       ${C_RED}这是导致 SS 连接失败的常见原因${NC}"
            echo -e "       建议先执行菜单 ${C_BOLD}16) 强制同步系统时间${NC} 再重试验证"
            echo ""
        elif [[ $offset_sec -gt 5 ]]; then
            echo -e "  ${C_YELLOW}[!]${NC} 系统时间偏差 ${offset_sec} 秒，建议同步时间（菜单16）"
        else
            echo -e "  ${C_GREEN}[✓]${NC} 系统时间偏差 ${offset_sec} 秒，正常"
        fi
    fi

    # ── Step 1: 服务运行状态 ──
    hr; echo -e "  ${C_BOLD}Step 1 — 服务状态${NC}"; hr
    if svc_active 2>/dev/null; then
        echo -e "  ${C_GREEN}[✓]${NC} sing-box 正在运行"; (( pass++ )) || true
    else
        echo -e "  ${C_RED}[✗]${NC} sing-box 未运行，请先启动"
        (( fail++ )) || true
        echo ""
        echo "  请执行: volsb start"
        return
    fi

    # ── Step 2: 读取配置 ──
    hr; echo -e "  ${C_BOLD}Step 2 — 配置读取${NC}"; hr
    if [[ ! -f "$SB_CONFIG" ]]; then
        echo -e "  ${C_RED}[✗]${NC} 找不到配置文件: $SB_CONFIG"
        return
    fi

    # 检查是否是线路机/分流配置（有 ss 出站）
    local ss_count
    ss_count=$(jq '[.outbounds[]? | select(.type=="shadowsocks")] | length' "$SB_CONFIG" 2>/dev/null | tr -d '[:space:]') || ss_count=0
    ss_count=$(( ss_count + 0 )) 2>/dev/null || ss_count=0
    local in_port
    in_port=$(jq -r '.inbounds[] | select((.listen_port // 0) > 0) | .listen_port // ""' "$SB_CONFIG" 2>/dev/null | head -1)

    if [[ $ss_count -eq 0 ]]; then
        echo -e "  ${C_YELLOW}[!]${NC} 当前不是线路机配置（无 Shadowsocks 出站）"
        echo    "      请先以线路机模式安装，或使用带 SS 分流出口的部署机配置"
        return
    fi

    echo -e "  ${C_GREEN}[✓]${NC} 配置已找到"
    if choose_relay_inbound_port; then
        echo -e "       入站端口  : ${C_CYAN}${SELECTED_VERIFY_PORT}${NC}"
        [[ -n "${SELECTED_VERIFY_TYPE:-}" ]] && echo -e "       入站类型  : ${C_CYAN}${SELECTED_VERIFY_TYPE}${NC}"
        [[ -n "${SELECTED_VERIFY_TAG:-}" ]] && echo -e "       入站标签  : ${C_CYAN}${SELECTED_VERIFY_TAG}${NC}"
    else
        [[ "${SELECTED_VERIFY_BACK:-0}" == "1" ]] && return 0
        [[ -n "$in_port" ]] || { echo -e "       入站端口  : ${C_YELLOW}未找到${NC}"; return; }
        SELECTED_VERIFY_PORT="$in_port"
        echo -e "       入站端口  : ${C_CYAN}${SELECTED_VERIFY_PORT}${NC}"
    fi

    if choose_relay_outbounds; then
        echo -e "       检测出站  : ${C_CYAN}${#SELECTED_VERIFY_OUTBOUNDS[@]} 个${NC}"
    else
        echo -e "  ${C_RED}[✗]${NC} 未读取到可检测的 Shadowsocks 出站"
        return
    fi

    # ── Step 3: 端口监听检查 ──
    hr; echo -e "  ${C_BOLD}Step 3 — 端口监听${NC}"; hr
    if ss -tuln 2>/dev/null | grep -q ":${SELECTED_VERIFY_PORT} "; then
        echo -e "  ${C_GREEN}[✓]${NC} 入站端口 ${SELECTED_VERIFY_PORT} 正在监听"; (( pass++ )) || true
    else
        echo -e "  ${C_RED}[✗]${NC} 入站端口 ${SELECTED_VERIFY_PORT} 未监听"
        (( fail++ )) || true
    fi

    # ── Step 4: 出站链路验证 ──
    hr; echo -e "  ${C_BOLD}Step 4 — 出站链路验证${NC}"; hr
    echo    "  逐个检测所选 Shadowsocks 出站的 TCP、密码格式和出口 IP..."
    local outbound_item
    for outbound_item in "${SELECTED_VERIFY_OUTBOUNDS[@]}"; do
        verify_one_ss_outbound "$outbound_item"
    done

    # ── Step 5: 日志检查 ──
    hr; echo -e "  ${C_BOLD}Step 5 — 最近错误日志${NC}"; hr
    local err_lines
    err_lines=$(journalctl -u sing-box --since "5 minutes ago" --no-pager 2>/dev/null         | grep -iE "error|failed|refused|timeout" | tail -5)
    if [[ -z "$err_lines" ]]; then
        echo -e "  ${C_GREEN}[✓]${NC} 最近5分钟无错误日志"; (( pass++ )) || true
    else
        echo -e "  ${C_YELLOW}[!]${NC} 发现错误日志:"
        echo "$err_lines" | sed "s/^/       ${C_DIM}/" | sed "s/$/${NC}/"
    fi

    # ── 汇总 ──
    hr
    echo ""
    echo -e "  验证完成: ${C_GREEN}通过 ${pass} 项${NC}  ${C_RED}失败 ${fail} 项${NC}"
    if [[ $fail -eq 0 ]]; then
        echo -e "  ${C_GREEN}${C_BOLD}✓ 线路机转发工作正常！${NC}"
    else
        echo ""
        echo -e "  ${C_YELLOW}排查建议:${NC}"
        echo    "   1. 确认失败的 SS 出站端口已在对应落地机防火墙/安全组放行"
        echo    "   2. 确认对应落地机 sing-box/SS 服务正在运行"
        echo    "   3. 检查失败出站的密码和加密方式是否与落地机一致"
        echo    "   4. 查看完整日志: volsb log"
    fi
    echo ""
}


show_traffic() {
    clear
    echo -e "${C_BOLD}${C_CYAN}"
    cat <<'HDR'
  ╔════════════════════════════════════════════════════╗
  ║              VOLSB — 流量统计                      ║
  ╚════════════════════════════════════════════════════╝
HDR
    echo -e "${NC}"

    if svc_active 2>/dev/null; then
        echo -e "  服务状态: ${C_GREEN}● 运行中${NC}"
    else
        echo -e "  服务状态: ${C_RED}● 已停止${NC}"
    fi
    echo ""

    [[ ! -f "$SB_CONFIG" ]] && { warn "配置文件不存在"; return; }

    local clash_api api_changed=0
    clash_api=$(jq -r '.experimental.clash_api.external_controller // ""' "$SB_CONFIG" 2>/dev/null)

    # ── Clash API 实时速率 ──
    # 若配置里没有 Clash API 或端口不一致，自动修复并重启
    if [[ "$clash_api" != "$SB_STAT_API" ]]; then
        info "检测到 Clash API 未配置或端口不一致，自动修复中..."
        if traffic_init_api; then
            clash_api=$(jq -r '.experimental.clash_api.external_controller // ""' "$SB_CONFIG" 2>/dev/null)
            api_changed=1
        else
            warn "Clash API 自动修复失败，将只显示 /proc 兜底统计"
        fi
    fi

    if [[ "$api_changed" -eq 1 && -n "$clash_api" ]]; then
        svc_restart 2>/dev/null || true
        sleep 2
    fi

    if traffic_api_ready "$clash_api"; then
        echo -e "  ${C_BOLD}实时速率 (Clash API):${NC}"
        hr

        local t_up=0 t_down=0 traffic_json
        traffic_json=$(traffic_api_snapshot "$clash_api")
        if [[ -n "$traffic_json" ]] && echo "$traffic_json" | jq -e . &>/dev/null; then
            t_up=$(echo   "$traffic_json" | jq -r '.up   // 0' 2>/dev/null | tr -d '[:space:]'); t_up=$(( ${t_up:-0}+0 ))
            t_down=$(echo "$traffic_json" | jq -r '.down // 0' 2>/dev/null | tr -d '[:space:]'); t_down=$(( ${t_down:-0}+0 ))
            printf "  ↑ 上行: ${C_YELLOW}%s/s${NC}   ↓ 下行: ${C_GREEN}%s/s${NC}\n" \
                "$(human_bytes "$t_up")" "$(human_bytes "$t_down")"
        else
            warn "Clash API 已连接，但 /traffic 暂无有效数据"
        fi

        # 活跃连接数
        local conns_raw conn_count
        conns_raw=$(curl -fsSL --connect-timeout 1 --max-time 2 "http://${clash_api}/connections" 2>/dev/null)
        conn_count=$(echo "$conns_raw" | jq '.connections | length' 2>/dev/null | tr -d '[:space:]') || conn_count=0
        conn_count=$(( ${conn_count:-0}+0 ))
        echo -e "  活跃连接: ${C_CYAN}${conn_count}${NC} 个"

        if [[ $conn_count -gt 0 ]]; then
            echo ""
            echo -e "  ${C_BOLD}连接详情 (最近10条):${NC}"
            echo "$conns_raw" | jq -r '
                .connections[:10][] |
                "  \(.metadata.type) \(.metadata.sourceIP):\(.metadata.sourcePort) → \(.metadata.destinationAddress // .metadata.host):\(.metadata.destinationPort)  [\(.chains[0] // "")]"
            ' 2>/dev/null | head -10 || true
        fi
        hr
    else
        warn "Clash API 暂不可用，下面继续显示 /proc 端口连接数和网卡流量"
        echo -e "  ${C_DIM}提示: 如刚更新脚本，可执行 volsb restart 后再查看实时速率${NC}"
        hr
    fi

    # ── 按端口当前连接数（/proc/net） ──
    echo ""
    echo -e "  ${C_BOLD}入站端口连接数:${NC}"
    hr
    printf "  ${C_BOLD}%-10s %-22s %-12s %-12s %s${NC}\n" "端口" "类型" "TCP" "UDP" "合计"
    hr

    local inbounds_raw
    inbounds_raw=$(jq -r '.inbounds[] |
        [(.listen_port//0|tostring), (.type//"unknown"), (.listen//"")]
        | join("|")' "$SB_CONFIG" 2>/dev/null) || inbounds_raw=""

    while IFS='|' read -r port type listen; do
        [[ -z "$port" || "$port" == "0" || "$listen" == "127.0.0.1" ]] && continue

        # 十六进制端口（大写，4位，/proc/net/tcp 格式）
        local hex_port; hex_port=$(printf "%04X" "$port" 2>/dev/null) || continue

        # /proc/net/tcp: 第2列是本地地址 "0.0.0.0:PORT" 格式为 "00000000:HEX"
        # 第4列状态 01=ESTABLISHED
        local tcp_c udp_c
        tcp_c=$(awk -v h=":${hex_port}" \
            'NR>1 && $2~h && $4=="01" {c++} END{print c+0}' \
            /proc/net/tcp /proc/net/tcp6 2>/dev/null | tr -d '[:space:]')
        tcp_c=$(( ${tcp_c:-0}+0 )) 2>/dev/null || tcp_c=0

        udp_c=$(awk -v h=":${hex_port}" \
            'NR>1 && $2~h {c++} END{print c+0}' \
            /proc/net/udp /proc/net/udp6 2>/dev/null | tr -d '[:space:]')
        udp_c=$(( ${udp_c:-0}+0 )) 2>/dev/null || udp_c=0

        local total=$(( tcp_c + udp_c ))
        printf "  ${C_CYAN}%-10s${NC} %-22s " "$port" "$type"
        if [[ $total -gt 0 ]]; then
            printf "${C_GREEN}%-12s %-12s %s${NC}\n" "$tcp_c" "$udp_c" "${total} 个"
        else
            printf "${C_DIM}%-12s %-12s %s${NC}\n" "0" "0" "无"
        fi
    done <<< "$inbounds_raw"
    hr

    # ── 网卡累计流量 + 实时速率 ──
    echo ""
    echo -e "  ${C_BOLD}网卡流量:${NC}"
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    if [[ -n "${iface:-}" ]] && [[ -f /proc/net/dev ]]; then
        local rx tx
        rx=$(awk -v i="${iface}:" '$1==i{print $2}'  /proc/net/dev 2>/dev/null | tr -d '[:space:]'); rx=$(( ${rx:-0}+0 ))
        tx=$(awk -v i="${iface}:" '$1==i{print $10}' /proc/net/dev 2>/dev/null | tr -d '[:space:]'); tx=$(( ${tx:-0}+0 ))
        printf "  接口 ${C_CYAN}%s${NC} | 累计 ↓ ${C_GREEN}%s${NC}  ↑ ${C_YELLOW}%s${NC}\n" \
            "$iface" "$(human_bytes $rx)" "$(human_bytes $tx)"

        local r1 t1 r2 t2
        r1=$(awk -v i="${iface}:" '$1==i{print $2}'  /proc/net/dev 2>/dev/null | tr -d '[:space:]'); r1=$(( ${r1:-0}+0 ))
        t1=$(awk -v i="${iface}:" '$1==i{print $10}' /proc/net/dev 2>/dev/null | tr -d '[:space:]'); t1=$(( ${t1:-0}+0 ))
        sleep 1
        r2=$(awk -v i="${iface}:" '$1==i{print $2}'  /proc/net/dev 2>/dev/null | tr -d '[:space:]'); r2=$(( ${r2:-0}+0 ))
        t2=$(awk -v i="${iface}:" '$1==i{print $10}' /proc/net/dev 2>/dev/null | tr -d '[:space:]'); t2=$(( ${t2:-0}+0 ))
        printf "  实时速率 | ↓ ${C_GREEN}%s/s${NC}  ↑ ${C_YELLOW}%s/s${NC}\n" \
            "$(human_bytes $(( r2-r1 )))" "$(human_bytes $(( t2-t1 )))"
    fi

    echo ""; hr
}


reset_traffic_log() {
    ask "确认清空流量日志? [y/N]:"; read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    : > "$SB_LOG" 2>/dev/null && info "日志已清空"
    echo "{}" > "$SB_TRAFFIC"
    secure_sensitive_files
}

# ════════════════════════════════════════════════════════════
#  快捷命令安装
# ════════════════════════════════════════════════════════════

install_shortcut() {
    install_managed_script || return 1
    write_shortcut
    info "快捷命令已安装,现在可以输入 ${C_BOLD}volsb${NC} 进入管理界面"
}

format_nodes_info() {
    local file="$1"
    awk '
        function is_route_header(line) {
            return line ~ /^  \[(出口系统|分流系统)\]/
        }
        function is_block_header(line) {
            return line ~ /^  \[/
        }
        function print_separator() {
            print "============================================================"
        }
        function print_node() {
            if (node_block == "") return
            print node_block
            if (route_block != "") {
                print ""
                print route_block
            }
            print_separator()
            node_block = ""
            route_block = ""
        }
        function flush_block() {
            if (block == "") return
            if (block_type == "route") {
                if (node_block != "") {
                    # A node can temporarily record multiple route blocks while
                    # building the final profile. Show the last one only.
                    route_block = block
                } else {
                    pending_route = block
                }
            } else {
                print_node()
                node_block = block
                route_block = pending_route
                pending_route = ""
            }
            block = ""
            block_type = ""
        }
        {
            if (is_block_header($0)) {
                flush_block()
                block = $0
                block_type = is_route_header($0) ? "route" : "node"
                next
            }
            if (block != "") {
                block = block "\n" $0
            } else {
                print
            }
        }
        END {
            flush_block()
            print_node()
        }
    ' "$file"
}

# ════════════════════════════════════════════════════════════
#  节点信息展示
# ════════════════════════════════════════════════════════════

show_nodes() {
    clear
    echo -e "${C_BOLD}${C_CYAN}"
    cat <<'HDR'
  ╔════════════════════════════════════════════════════╗
  ║              VOLSB — 节点信息总览                  ║
  ╚════════════════════════════════════════════════════╝
HDR
    echo -e "${NC}"

    # ── 从 config.json 实时读取入站端口和类型（一次性读取）──
    if [[ -f "$SB_CONFIG" ]]; then
        echo -e "  ${C_BOLD}当前运行入站:${NC}"
        hr
        local n=0
        while IFS='|' read -r ib_type ib_port ib_tag ib_listen; do
            [[ "$ib_listen" == "127.0.0.1" ]] && continue
            (( n++ )) || true
            printf "  ${C_BOLD}%-4s${NC} ${C_GREEN}%-20s${NC} 端口: ${C_CYAN}%-8s${NC} 标签: %s\n" \
                "${n})" "$ib_type" "$ib_port" "$ib_tag"
        done < <(jq -r '.inbounds[] | [(.type//"unknown"), (.listen_port//""|tostring), (.tag//""), (.listen//"")]  | join("|")' \
            "$SB_CONFIG" 2>/dev/null)
        [[ $n -eq 0 ]] && warn "未读取到入站配置"
        hr
    else
        warn "配置文件不存在，请先安装"
    fi
    # ── 展示节点详情（与当前 config.json 比对，提示陈旧数据）──
    if [[ -f "$SB_INFO" ]]; then
        echo ""
        echo -e "  ${C_BOLD}节点详情:${NC}"
        local config_ports info_ports stale=false tmp_info
        config_ports=$(jq -r '.inbounds[].listen_port | tostring' "$SB_CONFIG" 2>/dev/null | sort -u | tr '\n' ' ')
        info_ports=$(grep -oP '端口\s*:\s*\K[0-9]+' "$SB_INFO" 2>/dev/null | sort -u | tr '\n' ' ')
        for p in $info_ports; do
            if ! echo "$config_ports" | grep -qw "$p"; then
                stale=true; break
            fi
        done
        if $stale; then
            warn "节点信息含旧数据（端口 $info_ports 与当前配置 $config_ports 不完全匹配）"
            warn "已仅展示当前配置中的节点"
            echo ""
            tmp_info=$(mktemp)
            awk -v ports="$config_ports" '
                BEGIN {
                    gsub(/[[:space:]]+/, " ", ports)
                    split(ports, arr, / /)
                    for (i in arr) if (arr[i] != "") port_map[arr[i]] = 1
                }
                function is_route_header(line) {
                    return line ~ /^  \[(出口系统|分流系统)\]/
                }
                function is_block_header(line) {
                    return line ~ /^  \[/
                }
                function has_port(block,    p) {
                    for (p in port_map) {
                        if (block ~ ("端口[[:space:]]*:[[:space:]]*" p "([^0-9]|$)")) return 1
                        if (block ~ ("ShadowTLS 端口[[:space:]]*:[[:space:]]*" p "([^0-9]|$)")) return 1
                    }
                    return 0
                }
                function print_node() {
                    if (node_block == "") return
                    if (has_port(node_block)) {
                        print node_block
                        if (route_block != "") print route_block
                    }
                    node_block = ""
                    route_block = ""
                }
                function flush_block() {
                    if (block == "") return
                    if (block_type == "route") {
                        if (node_block != "") {
                            route_block = block
                        } else {
                            pending_route = block
                        }
                    } else {
                        print_node()
                        node_block = block
                        route_block = pending_route
                        pending_route = ""
                    }
                    block = ""
                    block_type = ""
                }
                {
                    if (is_block_header($0)) {
                        flush_block()
                        block = $0
                        block_type = is_route_header($0) ? "route" : "node"
                        next
                    }
                    if (block != "") {
                        block = block "\n" $0
                    } else {
                        print
                    }
                }
                END {
                    flush_block()
                    print_node()
                }
            ' "$SB_INFO" > "$tmp_info"
            format_nodes_info "$tmp_info"
            rm -f "$tmp_info"
        else
            format_nodes_info "$SB_INFO"
        fi
    fi

    # ── 展示所有分享链接（带编号和二维码）──
    local links=() link
    while IFS= read -r link; do
        [[ -n "$link" ]] && links+=("$link")
    done < <(collect_share_links)
    if [[ ${#links[@]} -gt 0 ]]; then
        hr
        echo -e "
  ${C_BOLD}分享链接:${NC}
"
        local i=0
        for link in "${links[@]}"; do
            (( i++ )) || true
            # 从链接提取协议和名称
            local proto name
            proto=$(echo "$link" | cut -d: -f1 | tr '[:lower:]' '[:upper:]')
            name=$(echo "$link" | grep -oP '(?<=#)[^#]*$' || echo "节点$i")
            echo -e "  ${C_BOLD}${C_YELLOW}[$i] ${proto} — ${name}${NC}"
            echo -e "  ${C_DIM}${link}${NC}"
            echo ""
            print_qr "$link"
        done
        echo -e "  共 ${C_BOLD}${i}${NC} 条链接，已保存: ${C_DIM}$SB_LINKS${NC}"
    else
        echo ""
        warn "暂无分享链接，请先完成安装配置"
    fi
    echo ""
}

count_active_inbounds() {
    [[ -f "$SB_CONFIG" ]] || { echo 0; return 0; }
    jq '[.inbounds[]? | select((.listen // "") != "127.0.0.1")] | length' "$SB_CONFIG" 2>/dev/null || echo 0
}

count_saved_links() {
    [[ -f "$SB_LINKS" ]] || { echo 0; return 0; }
    awk 'NF{n++} END{print n+0}' "$SB_LINKS" 2>/dev/null || echo 0
}

collect_share_links() {
    local links=() link link_port active_ports=()
    if [[ -f "$SB_CONFIG" ]]; then
        while IFS= read -r link_port; do
            [[ -n "$link_port" && "$link_port" != "0" ]] && active_ports+=("$link_port")
        done < <(jq -r '.inbounds[]? | select((.listen // "") != "127.0.0.1") | .listen_port // empty' "$SB_CONFIG" 2>/dev/null)
    fi

    _append_share_link_if_current() {
        local candidate="$1" port
        [[ -n "$candidate" ]] || return 0
        if [[ ${#active_ports[@]} -gt 0 ]]; then
            port=$(_share_link_port "$candidate")
            [[ -n "$port" ]] || return 0
            _tag_exists_in_list "$port" "${active_ports[@]}" || return 0
        fi
        links+=("$candidate")
    }

    if [[ -f "$SB_LINKS" && -s "$SB_LINKS" ]]; then
        while IFS= read -r link; do
            _append_share_link_if_current "$link"
        done < "$SB_LINKS"
    fi

    if [[ ${#links[@]} -le 0 && -f "$SB_INFO" ]]; then
        while IFS= read -r link; do
            _append_share_link_if_current "$link"
        done < <(grep -oP '(?<=链接\s*:\s*)(?:vmess|[a-z0-9+.-]+)://.*$' "$SB_INFO" 2>/dev/null || true)
    fi

    printf '%s\n' "${links[@]}"
}

_clean_info_blocks_by_port() {
    local ports_json="$1" tmp
    tmp=$(mktemp)
    awk -v ports="$ports_json" '
        BEGIN {
            gsub(/[][]/, "", ports)
            n = split(ports, arr, /,/)
            for (i = 1; i <= n; i++) {
                gsub(/"/, "", arr[i])
                gsub(/[[:space:]]/, "", arr[i])
                if (arr[i] != "") port_map[arr[i]] = 1
            }
        }
        function block_has_port(    p) {
            for (p in port_map) {
                if (block ~ ("端口[[:space:]]*:[[:space:]]*" p "([^0-9]|$)")) return 1
                if (block ~ ("ShadowTLS 端口[[:space:]]*:[[:space:]]*" p "([^0-9]|$)")) return 1
            }
            return 0
        }
        function flush_block(    keep) {
            if (block == "") return
            keep = 1
            if (block_type == "node") {
                if (block_has_port()) {
                    keep = 0
                    drop_following_route = 1
                } else {
                    drop_following_route = 0
                }
            } else if (drop_following_route) {
                keep = 0
            }
            if (keep) printf "%s", block
            block = ""
        }
        /^  \[/ {
            flush_block()
            block = $0 ORS
            block_type = ($0 ~ /^  \[(出口系统|分流系统)\]/) ? "route" : "node"
            next
        }
        {
            block = block $0 ORS
        }
        END {
            flush_block()
        }
    ' "$SB_INFO" > "$tmp" && mv "$tmp" "$SB_INFO" || { rm -f "$tmp"; return 1; }
}

_clean_links_by_port() {
    local ports_json="$1" tmp line port ports=()
    [[ -f "$SB_LINKS" ]] || return 0
    while IFS= read -r port; do
        [[ -n "$port" ]] && ports+=("$port")
    done < <(jq -r '.[]?' <<< "$ports_json" 2>/dev/null)
    [[ ${#ports[@]} -gt 0 ]] || return 0
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        port=$(_share_link_port "$line")
        if [[ -n "$port" ]] && _tag_exists_in_list "$port" "${ports[@]}"; then
            continue
        fi
        printf '%s\n' "$line"
    done < "$SB_LINKS" > "$tmp" || true
    mv "$tmp" "$SB_LINKS"
}

_b64_decode() {
    local data="$1"
    while (( ${#data} % 4 )); do data="${data}="; done
    printf '%s' "$data" | base64 -d 2>/dev/null && return 0
    printf '%s' "$data" | base64 -D 2>/dev/null
}

_b64_encode() {
    local data="$1"
    printf '%s' "$data" | base64 -w0 2>/dev/null || printf '%s' "$data" | base64 | tr -d '\n'
}

_share_link_port() {
    local link="$1" scheme body json hostinfo port
    [[ "$link" == *"://"* ]] || return 0
    scheme="${link%%://*}"
    case "$scheme" in
        vmess)
            body="${link#vmess://}"
            body="${body%%#*}"
            json=$(_b64_decode "$body" 2>/dev/null) || return 0
            printf '%s' "$json" | jq -r '.port // empty' 2>/dev/null
            ;;
        *)
            body="${link#*://}"
            body="${body%%#*}"
            body="${body%%\?*}"
            body="${body%%/*}"
            [[ "$body" == *"@"* ]] || return 0
            hostinfo="${body##*@}"
            if [[ "$hostinfo" == \[*\]:* ]]; then
                port="${hostinfo##*]:}"
            elif [[ "$hostinfo" == *:* ]]; then
                port="${hostinfo##*:}"
            else
                return 0
            fi
            [[ "$port" =~ ^[0-9]+$ ]] && printf '%s\n' "$port"
            ;;
    esac
}

_rewrite_share_link_port() {
    local link="$1" old_port="$2" new_port="$3"
    local scheme body frag="" query="" path="" userinfo hostinfo host json b64
    [[ "$link" == *"://"* ]] || { printf '%s\n' "$link"; return; }
    scheme="${link%%://*}"
    case "$scheme" in
        vmess)
            body="${link#vmess://}"
            frag=""
            if [[ "$body" == *#* ]]; then
                frag="#${body#*#}"
                body="${body%%#*}"
            fi
            json=$(_b64_decode "$body" 2>/dev/null) || { printf '%s\n' "$link"; return; }
            json=$(printf '%s' "$json" | jq -c --arg old "$old_port" --arg new "$new_port" '
                .port = $new
                | if (.ps? | type) == "string" then .ps |= gsub($old; $new) else . end
            ' 2>/dev/null) || { printf '%s\n' "$link"; return; }
            b64=$(_b64_encode "$json")
            printf 'vmess://%s%s\n' "$b64" "$frag"
            ;;
        *)
            body="${link#*://}"
            if [[ "$body" == *#* ]]; then
                frag="#${body#*#}"
                frag="${frag//$old_port/$new_port}"
                body="${body%%#*}"
            fi
            if [[ "$body" == *\?* ]]; then
                query="?${body#*\?}"
                body="${body%%\?*}"
            fi
            if [[ "$body" == */* ]]; then
                path="/${body#*/}"
                body="${body%%/*}"
            fi
            [[ "$body" == *"@"* ]] || { printf '%s\n' "$link"; return; }
            userinfo="${body%@*}"
            hostinfo="${body##*@}"
            host="${hostinfo%:*}"
            [[ -n "$host" && "$host" != "$hostinfo" ]] || { printf '%s\n' "$link"; return; }
            printf '%s://%s@%s:%s%s%s%s\n' "$scheme" "$userinfo" "$host" "$new_port" "$path" "$query" "$frag"
            ;;
    esac
}

_lookup_tsv_map() {
    local key="$1" file="$2" old new
    [[ -f "$file" ]] || return 1
    while IFS=$'\t' read -r old new; do
        [[ "$old" == "$key" ]] && { printf '%s' "$new"; return 0; }
    done < "$file"
    return 1
}

_apply_tsv_token_map() {
    local text="$1" file="$2" old new
    if [[ -f "$file" ]]; then
        while IFS=$'\t' read -r old new; do
            [[ -n "$old" ]] || continue
            text="${text//$old/$new}"
        done < "$file"
    fi
    printf '%s' "$text"
}

_rewrite_vmess_link_tokens() {
    local link="$1" token_map_file="$2" body frag="" json old new b64
    [[ "$link" == vmess://* ]] || { printf '%s\n' "$link"; return; }
    body="${link#vmess://}"
    if [[ "$body" == *#* ]]; then
        frag="#${body#*#}"
        body="${body%%#*}"
    fi
    json=$(_b64_decode "$body" 2>/dev/null) || { printf '%s\n' "$link"; return; }
    if [[ -f "$token_map_file" ]]; then
        while IFS=$'\t' read -r old new; do
            [[ -n "$old" ]] || continue
            json="${json//$old/$new}"
        done < "$token_map_file"
    fi
    json=$(printf '%s' "$json" | jq -c . 2>/dev/null || printf '%s' "$json")
    b64=$(_b64_encode "$json")
    printf 'vmess://%s%s\n' "$b64" "$frag"
}

_sync_links_after_reset() {
    local ports_json="$1" port_map_file="$2" token_map_file="$3"
    local tmp line port new_port ports=()
    [[ -f "$SB_LINKS" ]] || return 0
    while IFS= read -r port; do
        [[ -n "$port" ]] && ports+=("$port")
    done < <(jq -r '.[]?' <<< "$ports_json" 2>/dev/null)
    [[ ${#ports[@]} -gt 0 ]] || return 0

    tmp=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        port=$(_share_link_port "$line")
        if [[ -n "$port" ]] && _tag_exists_in_list "$port" "${ports[@]}"; then
            if new_port=$(_lookup_tsv_map "$port" "$port_map_file"); then
                line=$(_rewrite_share_link_port "$line" "$port" "$new_port")
            fi
            if [[ "$line" == vmess://* ]]; then
                line=$(_rewrite_vmess_link_tokens "$line" "$token_map_file")
            else
                line=$(_apply_tsv_token_map "$line" "$token_map_file")
            fi
        fi
        printf '%s\n' "$line"
    done < "$SB_LINKS" > "$tmp" || true
    mv "$tmp" "$SB_LINKS"
}

_block_has_selected_port() {
    local block="$1"; shift || true
    local p
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        if grep -Eq "(^|[[:space:]])(ShadowTLS )?端口[[:space:]]*:[[:space:]]*${p}([^0-9]|$)" <<< "$block"; then
            return 0
        fi
    done
    return 1
}

_apply_reset_maps_to_block() {
    local block="$1" port_map_file="$2" token_map_file="$3" old new
    local line prefix link link_port new_port
    if [[ -f "$port_map_file" ]]; then
        while IFS=$'\t' read -r old new; do
            [[ -n "$old" ]] || continue
            block="${block//$old/$new}"
        done < "$port_map_file"
    fi
    if [[ -f "$token_map_file" ]]; then
        while IFS=$'\t' read -r old new; do
            [[ -n "$old" ]] || continue
            block="${block//$old/$new}"
        done < "$token_map_file"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^(.*[[:space:]]:[[:space:]]*)([A-Za-z0-9+.-]+://.*)$ ]]; then
            prefix="${BASH_REMATCH[1]}"
            link="${BASH_REMATCH[2]}"
            link_port=$(_share_link_port "$link")
            if [[ -n "$link_port" ]] && new_port=$(_lookup_tsv_map "$link_port" "$port_map_file"); then
                link=$(_rewrite_share_link_port "$link" "$link_port" "$new_port")
            fi
            if [[ "$link" == vmess://* ]]; then
                link=$(_rewrite_vmess_link_tokens "$link" "$token_map_file")
            else
                link=$(_apply_tsv_token_map "$link" "$token_map_file")
            fi
            line="${prefix}${link}"
        fi
        printf '%s\n' "$line"
    done < <(printf '%s' "$block")
}

_sync_info_after_reset() {
    local ports_json="$1" port_map_file="$2" token_map_file="$3"
    local tmp line block="" ports=()
    [[ -f "$SB_INFO" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] && ports+=("$line")
    done < <(jq -r '.[]?' <<< "$ports_json" 2>/dev/null)
    [[ ${#ports[@]} -gt 0 ]] || return 0

    tmp=$(mktemp)
    _flush_reset_info_block() {
        [[ -n "$block" ]] || return 0
        if _block_has_selected_port "$block" "${ports[@]}"; then
            _apply_reset_maps_to_block "$block" "$port_map_file" "$token_map_file"
        else
            printf '%s' "$block"
        fi
        block=""
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "  ["* ]]; then
            _flush_reset_info_block
            block="${line}"$'\n'
        else
            block+="${line}"$'\n'
        fi
    done < "$SB_INFO" > "$tmp"
    _flush_reset_info_block >> "$tmp"
    mv "$tmp" "$SB_INFO"
}

_sync_metadata_after_reset() {
    local ports_json="$1" port_map_file="$2" token_map_file="$3"
    _sync_links_after_reset "$ports_json" "$port_map_file" "$token_map_file" || return 1
    _sync_info_after_reset "$ports_json" "$port_map_file" "$token_map_file" || return 1
}

delete_node() {
    require_root
    [[ -f "$SB_CONFIG" ]] || { warn "未找到配置文件"; return; }

    local items_json
    items_json=$(jq -c '[.inbounds[]? | select((.listen // "") != "127.0.0.1") | {tag:(.tag//""),type:(.type//""),port:(.listen_port//0),listen:(.listen//""),detour:(.detour//null)}]' "$SB_CONFIG" 2>/dev/null) || {
        warn "无法读取当前节点列表"; return 1
    }

    local item_count
    item_count=$(echo "$items_json" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$item_count" -le 0 ]]; then
        warn "没有可删除的节点"
        return 0
    fi

    echo ""
    echo -e "  ${C_BOLD}可删除节点:${NC}"
    echo "$items_json" | jq -r '
        to_entries[]
        | "  \(.key + 1)) \(.value.type) 端口:\(.value.port) [\(.value.tag)]\(.value.detour // "" | if . == "" then "" else " -> detour:" + . end)"
    '
    echo ""
    echo "  支持多选: 1 3 5 或 1,3,5"
    ask "输入要删除的节点序号，回车/0/b返回:"; read -r del_idx
    [[ -z "$del_idx" ]] && { info "已取消"; return 0; }
    [[ "$del_idx" == "0" ]] && { info "已返回上一级"; return 0; }
    is_back_choice "$del_idx" && { info "已返回上一级"; return 0; }

    del_idx="${del_idx//,/ }"
    local selected_indices=() seen_indices=() idx
    for idx in $del_idx; do
        [[ "$idx" =~ ^[0-9]+$ ]] || { warn "请输入有效序号"; return 1; }
        (( idx >= 1 && idx <= item_count )) || { warn "序号超出范围: $idx"; return 1; }
        if ! _tag_exists_in_list "$idx" "${seen_indices[@]}"; then
            selected_indices+=("$idx")
            seen_indices+=("$idx")
        fi
    done
    [[ ${#selected_indices[@]} -gt 0 ]] || { warn "未选择任何节点"; return 1; }

    local selected_json tags_json ports_json
    selected_json=$(printf '%s\n' "${selected_indices[@]}" | jq -R 'tonumber - 1' | jq -s .)
    tags_json=$(jq --argjson idxs "$selected_json" -r '
        [ $idxs[] as $i
          | .[$i]?
          | select(. != null)
          | (.tag, (.detour // empty))
        ] | map(select(. != "")) | unique
    ' <<< "$items_json") || return 1
    ports_json=$(jq --argjson idxs "$selected_json" -r '
        [ $idxs[] as $i
          | .[$i]?
          | select(. != null)
          | (.port | tostring)
        ] | map(select(. != "" and . != "0")) | unique
    ' <<< "$items_json") || return 1

    echo ""
    echo -e "  将删除 ${C_YELLOW}${#selected_indices[@]}${NC} 个节点:"
    jq --argjson idxs "$selected_json" -r '
        $idxs[] as $i
        | .[$i]?
        | select(. != null)
        | "  - \(.tag) 端口:\(.port)\(.detour // "" | if . == "" then "" else " -> detour:" + . end)"
    ' <<< "$items_json"
    ask "输入 DELETE 确认删除:"; read -r confirm
    [[ "$confirm" == "DELETE" ]] || { info "已取消删除"; return 0; }

    local tmp_config
    tmp_config=$(mktemp)
    jq --argjson tags "$tags_json" '
        def tag_hit($x): any($tags[]; . == $x);
        def drop_empty_inbound:
          if (.inbound? | type) == "array" then
            .inbound = [ .inbound[] | select(tag_hit(.) | not) ]
          elif (.inbound? | type) == "string" and tag_hit(.inbound) then
            .__drop = true
          else
            .
          end;
        .inbounds = [ .inbounds[]? | select(tag_hit((.tag // "")) | not) ]
        | .route.rules = (
            [.route.rules[]? | drop_empty_inbound]
            | map(select((.__drop // false) | not))
            | map(select((.inbound? | type) != "array" or (.inbound | length) > 0))
          )
      ' "$SB_CONFIG" > "$tmp_config" || { rm -f "$tmp_config"; warn "删除节点失败"; return 1; }

    if ! "$SB_BIN" check -c "$tmp_config" >/dev/null 2>&1; then
        err "删除后配置校验失败，已放弃修改"
        "$SB_BIN" check -c "$tmp_config" || true
        rm -f "$tmp_config"
        return 1
    fi

    mv "$tmp_config" "$SB_CONFIG"
    secure_sensitive_files
    _clean_links_by_port "$ports_json" || warn "分享链接文件更新失败，已继续"
    _clean_info_blocks_by_port "$ports_json" || warn "节点信息文件更新失败，已继续"

    svc_restart || { err "配置已更新，但服务重启失败"; return 1; }
    info "已删除 ${#selected_indices[@]} 个节点"
}

share_node_link() {
    require_root

    local links=() link
    while IFS= read -r link; do
        [[ -n "$link" ]] && links+=("$link")
    done < <(collect_share_links)
    if [[ ${#links[@]} -le 0 ]]; then
        warn "没有可分享的节点"
        return 0
    fi

    echo ""
    echo -e "  ${C_BOLD}可分享节点:${NC}"
    local i=1
    for link in "${links[@]}"; do
        printf "  %d) %s — %s\n" "$i" "$(share_link_proto "$link")" "$(share_link_name "$link" "节点${i}")"
        (( i++ )) || true
    done
    echo ""
    echo "  返回上一级: 0 / b"
    ask "请选择要分享的节点 [1-${#links[@]} / 0 / b]:"; read -r share_idx
    [[ -z "$share_idx" ]] && { info "已返回上一级"; return 0; }
    [[ "$share_idx" == "0" ]] && { info "已返回上一级"; return 0; }
    is_back_choice "$share_idx" && { info "已返回上一级"; return 0; }

    [[ "$share_idx" =~ ^[0-9]+$ ]] || { warn "请输入有效序号"; return 1; }
    (( share_idx >= 1 && share_idx <= ${#links[@]} )) || { warn "序号超出范围"; return 1; }

    local selected_link="${links[$(( share_idx - 1 ))]}"
    echo ""
    echo -e "  ${C_BOLD}分享链接:${NC}"
    echo -e "  ${C_CYAN}${selected_link}${NC}"
    print_qr "$selected_link"
    echo ""
}

# ════════════════════════════════════════════════════════════
#  端口 & 密码重置
# ════════════════════════════════════════════════════════════

reset_ports() {
    require_root
    [[ -f "$SB_CONFIG" ]] || { warn "未找到配置文件"; return; }

    local items_json item_count
    items_json=$(jq -c '[.inbounds[]? | select((.listen // "") != "127.0.0.1") | {tag:(.tag//""),type:(.type//""),port:(.listen_port//0),detour:(.detour//null)}]' "$SB_CONFIG" 2>/dev/null) || {
        warn "无法读取当前节点列表"; return 1
    }
    item_count=$(echo "$items_json" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$item_count" -le 0 ]]; then
        warn "没有可重置的节点"
        return 0
    fi

    echo ""
    echo -e "  ${C_BOLD}重置选项:${NC}"
    echo "   1) 仅重置端口"
    echo "   2) 仅重置密码/UUID"
    echo "   3) 同时重置端口和密码/UUID"
    echo "   0) 返回上一级"
    ask "选择 [0-3] 默认3:"; read -r reset_opt
    [[ "$reset_opt" == "0" ]] && { info "已返回上一级"; return 0; }
    is_back_choice "$reset_opt" && { info "已返回上一级"; return 0; }
    [[ -z "$reset_opt" ]] && reset_opt="3"

    echo ""
    echo -e "  ${C_BOLD}可重置节点:${NC}"
    echo "$items_json" | jq -r '
        to_entries[]
        | "  \(.key + 1)) \(.value.type) 端口:\(.value.port) [\(.value.tag)]\(.value.detour // "" | if . == "" then "" else " -> detour:" + . end)"
    '
    echo ""
    echo "  支持多选: 1 3 5 或 1,3,5"
    ask "输入要重置的节点序号，回车/0/b返回:"; read -r reset_idx
    [[ -z "$reset_idx" ]] && { info "已取消"; return 0; }
    [[ "$reset_idx" == "0" ]] && { info "已返回上一级"; return 0; }
    is_back_choice "$reset_idx" && { info "已返回上一级"; return 0; }

    reset_idx="${reset_idx//,/ }"
    local selected_indices=() seen_indices=() idx
    for idx in $reset_idx; do
        [[ "$idx" =~ ^[0-9]+$ ]] || { warn "请输入有效序号"; return 1; }
        (( idx >= 1 && idx <= item_count )) || { warn "序号超出范围: $idx"; return 1; }
        if ! _tag_exists_in_list "$idx" "${seen_indices[@]}"; then
            selected_indices+=("$idx")
            seen_indices+=("$idx")
        fi
    done
    [[ ${#selected_indices[@]} -gt 0 ]] || { warn "未选择任何节点"; return 1; }

    local selected_json selected_tags_json credential_tags_json selected_ports_json
    selected_json=$(printf '%s\n' "${selected_indices[@]}" | jq -R 'tonumber - 1' | jq -s .)
    selected_tags_json=$(jq --argjson idxs "$selected_json" -r '
        [ $idxs[] as $i | .[$i]? | select(. != null) | .tag ] | map(select(. != "")) | unique
    ' <<< "$items_json") || return 1
    selected_ports_json=$(jq --argjson idxs "$selected_json" -r '
        [ $idxs[] as $i
          | .[$i]?
          | select(. != null)
          | (.port | tostring)
        ] | map(select(. != "" and . != "0")) | unique
    ' <<< "$items_json") || return 1
    credential_tags_json=$(jq --argjson idxs "$selected_json" -r '
        [ $idxs[] as $i
          | .[$i]?
          | select(. != null)
          | (.tag, (.detour // empty))
        ] | map(select(. != "")) | unique
    ' <<< "$items_json") || return 1

    echo ""
    echo -e "  将重置 ${C_YELLOW}${#selected_indices[@]}${NC} 个节点:"
    jq --argjson idxs "$selected_json" -r '
        $idxs[] as $i
        | .[$i]?
        | select(. != null)
        | "  - \(.tag) 端口:\(.port)\(.detour // "" | if . == "" then "" else " -> detour:" + . end)"
    ' <<< "$items_json"
    ask "输入 RESET 确认重置:"; read -r confirm
    [[ "$confirm" == "RESET" ]] || { info "已取消重置"; return 0; }

    local backup; backup=$(mktemp)
    cp "$SB_CONFIG" "$backup"   # 备份原配置,失败时回滚
    local port_map_file token_map_file
    port_map_file=$(mktemp)
    token_map_file=$(mktemp)

    local updated; updated=$(cat "$SB_CONFIG")

    # ── 重置端口 ──
    if [[ "$reset_opt" == "1" || "$reset_opt" == "3" ]]; then
        step "重置入站端口"
        local selected_tag old_p new_p
        while IFS='|' read -r selected_tag old_p; do
            [[ -n "$selected_tag" && -n "$old_p" && "$old_p" != "0" ]] || continue
            local new_p; new_p=$(random_port)
            updated=$(echo "$updated" | jq --arg tag "$selected_tag" --argjson port "$new_p" '
                .inbounds |= map(if (.tag // "") == $tag then .listen_port = $port else . end)
            ') || { err "端口更新失败: $selected_tag"; cp "$backup" "$SB_CONFIG"; rm -f "$backup" "$port_map_file" "$token_map_file"; return 1; }
            printf '%s\t%s\n' "$old_p" "$new_p" >> "$port_map_file"
            info "${selected_tag}: 端口 $old_p → $new_p"
            open_port "$new_p" tcp; open_port "$new_p" udp
        done < <(jq --argjson tags "$selected_tags_json" -r '
            def hit($x): any($tags[]; . == $x);
            .inbounds[]? | select(hit(.tag // "")) | [(.tag // ""), (.listen_port // 0)] | join("|")
        ' "$SB_CONFIG")
    fi

    # ── 重置密码/UUID ──
    if [[ "$reset_opt" == "2" || "$reset_opt" == "3" ]]; then
        step "重置密码 / UUID"
        local pwd_rows old_tag old_method old_pwd
        pwd_rows=$(echo "$updated" | jq --argjson tags "$credential_tags_json" -r '
            def hit($x): any($tags[]; . == $x);
            .inbounds[]?
            | select(hit(.tag // ""))
            | (.tag // "") as $tag
            | (.method // "") as $method
            | (if (.password? // "") != "" then [$tag, $method, .password] else empty end),
              ((.users // [])[]? | select((.password? // "") != "") | [$tag, $method, .password])
            | @tsv
        ' 2>/dev/null | sort -u)
        while IFS=$'\t' read -r old_tag old_method old_pwd; do
            [[ -n "$old_pwd" ]] || continue
            local new_pwd pwd_len=24
            case "$old_method" in
                2022-blake3-aes-128-gcm) pwd_len=16 ;;
                2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) pwd_len=32 ;;
            esac
            if [[ "$old_method" == 2022-* ]]; then
                new_pwd=$("$SB_BIN" generate rand --base64 "$pwd_len" 2>/dev/null || openssl rand -base64 "$pwd_len" | tr -d '\n\r')
            else
                new_pwd=$(gen_rand_str 24)
            fi
            updated=$(printf '%s\n' "$updated" | jq --arg tag "$old_tag" --arg old "$old_pwd" --arg new "$new_pwd" '
                .inbounds |= map(
                  if (.tag // "") == $tag then
                    (if (.password? // "") == $old then .password = $new else . end)
                    | (if (.users? | type) == "array" then
                        .users |= map(if (.password? // "") == $old then .password = $new else . end)
                      else . end)
                  else . end
                )
            ') || { err "密码更新失败: $old_tag"; cp "$backup" "$SB_CONFIG"; rm -f "$backup" "$port_map_file" "$token_map_file"; return 1; }
            printf '%s\t%s\n' "$old_pwd" "$new_pwd" >> "$token_map_file"
            info "${old_tag}: 密码已更新 (${old_pwd:0:6}… → ${new_pwd:0:6}…)"
        done <<< "$pwd_rows"

        local uuid_rows old_uuid
        uuid_rows=$(echo "$updated" | jq --argjson tags "$credential_tags_json" -r '
            def hit($x): any($tags[]; . == $x);
            .inbounds[]?
            | select(hit(.tag // ""))
            | (.tag // "") as $tag
            | (if (.uuid? // "") != "" then [$tag, .uuid] else empty end),
              ((.users // [])[]? | select((.uuid? // "") != "") | [$tag, .uuid])
            | @tsv
        ' 2>/dev/null | sort -u)
        while IFS=$'\t' read -r old_tag old_uuid; do
            [[ -n "$old_uuid" ]] || continue
            local new_uuid; new_uuid=$(gen_uuid)
            updated=$(printf '%s\n' "$updated" | jq --arg tag "$old_tag" --arg old "$old_uuid" --arg new "$new_uuid" '
                .inbounds |= map(
                  if (.tag // "") == $tag then
                    (if (.uuid? // "") == $old then .uuid = $new else . end)
                    | (if (.users? | type) == "array" then
                        .users |= map(if (.uuid? // "") == $old then .uuid = $new else . end)
                      else . end)
                  else . end
                )
            ') || { err "UUID 更新失败: $old_tag"; cp "$backup" "$SB_CONFIG"; rm -f "$backup" "$port_map_file" "$token_map_file"; return 1; }
            printf '%s\t%s\n' "$old_uuid" "$new_uuid" >> "$token_map_file"
            info "${old_tag}: UUID 已更新 (${old_uuid:0:8}… → ${new_uuid:0:8}…)"
        done <<< "$uuid_rows"
    fi

    local tmp_config; tmp_config=$(mktemp)
    printf '%s\n' "$updated" > "$tmp_config"

    if "$SB_BIN" check -c "$tmp_config" &>/dev/null; then
        mv "$tmp_config" "$SB_CONFIG"
        secure_sensitive_files
        _sync_metadata_after_reset "$selected_ports_json" "$port_map_file" "$token_map_file" \
            && info "节点信息和分享链接已同步" \
            || warn "节点信息/分享链接同步失败，请重新生成节点后再导入"
        if svc_restart; then
            info "重置完成,服务已重启"
        else
            err "配置已更新，但服务重启失败"
            rm -f "$backup" "$port_map_file" "$token_map_file"
            return 1
        fi
    else
        err "配置校验失败,回滚至备份"
        cp "$backup" "$SB_CONFIG"
        "$SB_BIN" check -c "$tmp_config" || true
        rm -f "$tmp_config"
    fi
    rm -f "$backup" "$port_map_file" "$token_map_file"
}

# ════════════════════════════════════════════════════════════
#  主安装流程
# ════════════════════════════════════════════════════════════

# 结果写入全局变量 DEPLOY_MODE，避免子 shell 吞掉 read
DEPLOY_MODE="1"
select_deploy_mode() {
    clear
    echo -e "${C_BOLD}${C_CYAN}"
    cat <<'LOGO'
  ██╗   ██╗ ██████╗ ██╗     ███████╗██████╗
  ██║   ██║██╔═══██╗██║     ██╔════╝██╔══██╗
  ██║   ██║██║   ██║██║     ███████╗██████╔╝
  ╚██╗ ██╔╝██║   ██║██║     ╚════██║██╔══██╗
   ╚████╔╝ ╚██████╔╝███████╗███████║██████╔╝
    ╚═══╝   ╚═════╝ ╚══════╝╚══════╝╚═════╝
LOGO
    echo -e "  ${C_DIM}sing-box 服务端一键部署管理脚本  v${VOLSB_VER}${NC}"
    echo -e "${NC}"
    hr
    echo ""
    echo -e "  ${C_BOLD}选择部署模式:${NC}"
    echo ""
    printf "  ${C_BOLD}%-5s${NC} ${C_GREEN}%-20s${NC} %s\n" "1)" "部署机 (落地机)" "直接接收客户端流量,出口上网"
    printf "  ${C_BOLD}%-5s${NC} ${C_YELLOW}%-20s${NC} %s\n" "2)" "线路机 (中转机)" "接收客户端流量后转发至落地机"
    echo ""
    hr
    # 支持环境变量 VOLSB_MODE 跳过交互
    if [[ -n "${VOLSB_MODE:-}" ]]; then
        DEPLOY_MODE="$VOLSB_MODE"; return
    fi
    echo "   0) 返回上一级"
    ask "选择模式 [0/1/2] 默认1:"; read -r _mode
    [[ "$_mode" == "0" ]] && { info "已返回上一级"; return 1; }
    is_back_choice "$_mode" && { info "已返回上一级"; return 1; }
    [[ -z "$_mode" ]] && _mode="1"
    DEPLOY_MODE="$_mode"
}

do_install() {
    require_root
    detect_os
    detect_arch
    install_deps
    setup_dirs

    step "获取 sing-box 固定版本"
    local ver; ver=$(get_latest_version)
    if [[ -x "$SB_BIN" ]]; then
        local cur; cur=$("$SB_BIN" version 2>/dev/null | awk '{print $3}' | head -1)
        if [[ "$cur" == "$ver" ]]; then
            warn "sing-box 已固定为 v${ver}，跳过下载，继续配置"
        else
            info "当前 v${cur} → 固定 v${ver}，切换中..."
            install_binary "$ver"
        fi
    else
        install_binary "$ver"
    fi

    # 验证安装成功
    if [[ ! -x "$SB_BIN" ]]; then
        err "sing-box 安装失败，请检查网络后重试"
        return 1
    fi
    info "sing-box 就绪: $("$SB_BIN" version 2>/dev/null | head -1)"

    install_service
    install_shortcut

    # 节点信息文件由 assemble_and_write_config 统一写入，此处无需初始化

    select_deploy_mode || return 0

    if [[ "$DEPLOY_MODE" == "2" ]]; then
        # 线路机模式
        deploy_relay || return 1
        assemble_relay_check || return 1
    else
        # 部署机模式
        ask_connect_addr || return 0
        select_protocols || return 1
        assemble_and_write_config || return 1
    fi

    step "启动 sing-box 服务"
    # 用 restart 而非 start，确保重装时也能加载最新配置
    svc_restart 2>/dev/null || svc_start
    # 等待端口就绪，最多10秒
    local retry=0
    while ! svc_active 2>/dev/null && [[ $retry -lt 10 ]]; do
        sleep 1; (( retry++ )) || true
    done

    if svc_active; then
        info "sing-box 运行中 ✔  (用时 ${retry}s)"
    else
        err "启动失败! 查看日志:"
        [[ -f "$SB_LOG" ]] && tail -20 "$SB_LOG" || true
        return 1
    fi

    show_nodes
    echo ""
    info "安装完成!  输入 ${C_BOLD}volsb${NC} 进入管理界面"
}

# 线路机配置独立写入,不走 assemble_and_write_config
assemble_relay_check() {
    # 先注入 Clash API，再做最终校验
    traffic_init_api
    if "$SB_BIN" check -c "$SB_CONFIG" 2>/dev/null; then
        info "线路机配置校验通过"
    else
        err "线路机配置校验失败:"
        "$SB_BIN" check -c "$SB_CONFIG"
        return 1
    fi
    # 保存链接文件
    if [[ ${#ALL_LINKS[@]} -gt 0 ]]; then
        printf '%s
' "${ALL_LINKS[@]}" > "$SB_LINKS"
        secure_sensitive_files
        info "已保存 ${#ALL_LINKS[@]} 条节点链接"
    fi
}

do_uninstall() {
    require_root
    ask "确认完全卸载 VOLSB / sing-box? [y/N]:"; read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    svc_stop 2>/dev/null || true
    if [[ "$INIT_SYS" == "openrc" ]]; then
        rc-update del sing-box default &>/dev/null || true
        rm -f "$SB_OPENRC"
    else
        systemctl disable sing-box &>/dev/null || true
        rm -f "$SB_SYSTEMD"
        systemctl daemon-reload
    fi
    rm -f "$SB_BIN" "$VOLSB_CMD"
    rm -rf "$SB_CONF_DIR" "$SB_LOG_DIR" "$SB_DATA_DIR"
    info "卸载完成"
}

# ────── 升级 sing-box 核心 ──────
do_update_singbox() {
    require_root
    [[ -x "$SB_BIN" ]] || die "sing-box 未安装"
    detect_arch
    local cur new
    cur=$("$SB_BIN" version | awk '{print $3}' | head -1)
    new=$(get_latest_version)
    if [[ "$cur" == "$new" ]]; then
        info "sing-box 已固定为 v${cur}"; return
    fi
    info "切换 sing-box: v${cur} → 固定 v${new}"
    install_binary "$new"
    svc_restart && info "sing-box 升级完成 ✔"
}

# ────── 升级 VOLSB 脚本自身 ──────
do_update_script() {
    require_root
    step "更新 VOLSB 脚本"

    # 获取远端版本号 — 用 || true 防止 pipefail 误触发 set -e
    local remote_ver=""
    info "检查远端版本 ..."
    local raw_remote
    raw_remote=$(curl -fsSL --max-time 15 "$VOLSB_REPO" 2>/dev/null) || true

    if [[ -n "$raw_remote" ]]; then
        remote_ver=$(echo "$raw_remote" | grep -m1 'VOLSB_VER='             | sed 's/.*VOLSB_VER="\([^"]*\)".*/\1/' 2>/dev/null) || true
    fi

    if [[ -z "$remote_ver" ]]; then
        err "无法获取远端版本信息"
        err "请检查网络或仓库地址: $VOLSB_REPO"
        return 1
    fi

    info "本地版本: v${VOLSB_VER}  |  远端版本: v${remote_ver}"

    local needs_path_repair=false
    [[ -f "$VOLSB_SCRIPT" ]] || needs_path_repair=true
    if [[ ! -f "$VOLSB_CMD" ]] || ! grep -q "$VOLSB_SCRIPT" "$VOLSB_CMD" 2>/dev/null; then
        needs_path_repair=true
    fi

    if [[ "$remote_ver" == "$VOLSB_VER" && "$needs_path_repair" == "false" ]]; then
        info "VOLSB 已是最新版本 v${VOLSB_VER}"; return 0
    fi

    if [[ "$remote_ver" == "$VOLSB_VER" ]]; then
        info "版本已是最新，将修复脚本落盘路径和快捷命令"
    else
        info "发现新版本: v${VOLSB_VER} → v${remote_ver}"
    fi
    ask "确认更新? [Y/n]:"; read -r _ans
    [[ "$_ans" =~ ^[Nn]$ ]] && { info "已取消"; return 0; }

    mkdir -p "$VOLSB_LIB_DIR" || return 1
    chmod 755 "$VOLSB_LIB_DIR" 2>/dev/null || true
    local self="$VOLSB_SCRIPT"
    info "脚本路径: $self"

    local tmpfile; tmpfile=$(mktemp "${VOLSB_LIB_DIR}/volsb_update.XXXXXX")

    step "下载新版脚本"
    if ! curl -fsSL --max-time 60 -o "$tmpfile" "$VOLSB_REPO"; then
        rm -f "$tmpfile"
        err "下载失败: $VOLSB_REPO"; return 1
    fi

    # 完整性校验：必须含 VOLSB_VER= 且第一行是 bash shebang
    if ! validate_script_file "$tmpfile"; then
        rm -f "$tmpfile"
        err "下载内容校验失败,中止更新"; return 1
    fi

    # 备份当前版本
    local backup="${self}.bak.${VOLSB_VER}"
    if [[ -f "$self" ]]; then
        cp "$self" "$backup" && info "已备份至: $backup"
    fi

    # 原子替换：先写临时文件再 mv，避免写到一半进程读取
    chmod 755 "$tmpfile"
    mv "$tmpfile" "$self"
    info "脚本已替换: $self"

    # 同步更新 /usr/local/bin/volsb wrapper（重写指向 self）
    write_shortcut
    info "快捷命令已同步: $VOLSB_CMD"

    echo ""
    info "VOLSB 更新完成: v${VOLSB_VER} → v${remote_ver} ✔"
    echo ""
    info "正在重新加载新版本..."
    sleep 1
    # exec 替换当前进程，直接进入新版本菜单，无需用户手动退出重进
    exec bash "$VOLSB_SCRIPT" menu
}

# ────── 统一更新入口(菜单调用) ──────
do_update_menu() {
    echo ""
    echo -e "  ${C_BOLD}选择更新内容:${NC}"
    hr
    printf "  ${C_BOLD}%-5s${NC} %s\n" "1)" "更新 VOLSB 脚本  (当前 v${VOLSB_VER})"
    printf "  ${C_BOLD}%-5s${NC} %s\n" "2)" "升级 sing-box 核心版本"
    printf "  ${C_BOLD}%-5s${NC} %s\n" "3)" "全部更新"
    printf "  ${C_BOLD}%-5s${NC} %s\n" "0)" "返回上一级"
    hr
    ask "选择 [0-3]:"; read -r uc
    [[ "$uc" == "0" ]] && { info "已返回上一级"; return 0; }
    is_back_choice "$uc" && { info "已返回上一级"; return 0; }
    case "$uc" in
        1) do_update_script ;;
        2) do_update_singbox ;;
        3) do_update_singbox && do_update_script ;;
        *) info "已返回上一级" ;;
    esac
}

# ════════════════════════════════════════════════════════════
#  管理界面 (volsb 命令入口)
# ════════════════════════════════════════════════════════════

main_menu() {
    # 检测 INIT_SYS(管理界面直接调用时需要)
    if [[ -z "${INIT_SYS:-}" ]]; then
        [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
    fi

    while true; do
        clear
        echo -e "${C_BOLD}${C_CYAN}"
        cat <<'LOGO'
  ██╗   ██╗ ██████╗ ██╗     ███████╗██████╗
  ██║   ██║██╔═══██╗██║     ██╔════╝██╔══██╗
  ██║   ██║██║   ██║██║     ███████╗██████╔╝
  ╚██╗ ██╔╝██║   ██║██║     ╚════██║██╔══██╗
   ╚████╔╝ ╚██████╔╝███████╗███████║██████╔╝
    ╚═══╝   ╚═════╝ ╚══════╝╚══════╝╚═════╝
LOGO
        echo -e "  ${C_DIM}v${VOLSB_VER}  |  $(date '+%Y-%m-%d %H:%M:%S')  |  ${VOLSB_REPO##*/}${NC}"
        echo -e "${NC}"

        # 状态栏
        if svc_active 2>/dev/null; then
            echo -e "  状态: ${C_GREEN}${C_BOLD}● 运行中${NC}"
        elif [[ -f "$SB_SYSTEMD" || -f "$SB_OPENRC" ]]; then
            echo -e "  状态: ${C_RED}${C_BOLD}● 已停止${NC}"
        else
            echo -e "  状态: ${C_YELLOW}${C_BOLD}● 未安装${NC}"
        fi
        [[ -x "$SB_BIN" ]] && \
            echo -e "  版本: ${C_DIM}$("$SB_BIN" version 2>/dev/null | awk '{print $3}' | head -1)${NC}"
        if [[ -f "$SB_CONFIG" || -f "$SB_LINKS" ]]; then
            local node_count link_count
            node_count=$(count_active_inbounds)
            link_count=$(count_saved_links)
            echo -e "  节点: ${C_DIM}${node_count} 个入站 / ${link_count} 条链接${NC}"
        fi

        echo ""; hr
        echo -e "  ${C_BOLD}📦 安装管理${NC}"
        echo "   1) 全新安装 / 重新部署"
        echo "   2) 追加新协议"
        echo "   3) 更新 (脚本/sing-box)"
        echo "   4) 卸载"
        echo ""
        echo -e "  ${C_BOLD}⚙️  服务控制${NC}"
        echo "   5) 启动    6) 停止    7) 重启    8) 查看状态"
        echo ""
        echo -e "  ${C_BOLD}📋 节点与配置${NC}"
        echo "   9) 查看节点信息 / 删除节点"
        echo "  10) 重置端口 / 密码 / UUID"
        echo "  11) 编辑配置文件"
        echo ""
        echo -e "  ${C_BOLD}📊 流量管理${NC}"
        echo "  12) 查看流量统计"
        echo "  13) 清空流量日志"
        echo "  14) 实时日志"
        echo ""
        echo -e "  ${C_BOLD}🔍 诊断${NC}"
        echo "  15) 验证线路机转发连通性"
        echo "  16) 强制同步系统时间"
        hr
        echo "   0) 退出"
        echo ""
        ask "请选择 [0-16]:"; read -r opt

        case "$opt" in
            1)  do_install || true ;;
            2)  require_root
                if ! ask_connect_addr; then
                    info "已返回主菜单"
                elif ! select_protocols; then
                    info "已返回主菜单"
                elif append_and_write_config; then
                    svc_restart && { info "配置已更新"; show_nodes; } || true
                else
                    err "配置未更新，请根据上方错误重新操作"
                fi ;;
            3)  do_update_menu || true ;;
            4)  do_uninstall || true ;;
            5)  require_root; svc_start  && info "已启动" || true ;;
            6)  require_root; svc_stop   && info "已停止" || true ;;
            7)  require_root; svc_restart && info "已重启" || true ;;
            8)  svc_status || true ;;
            9)  show_nodes || true
                echo ""
                echo -e "  ${C_BOLD}节点管理${NC}"
                echo "   1) 删除节点"
                echo "   2) 分享节点"
                echo "   0) 返回上一级"
                echo "   b) 返回上一级"
                ask "请选择 [0/1/2/b]:"; read -r node_opt
                is_back_choice "$node_opt" && node_opt="0"
                case "$node_opt" in
                    1) delete_node || true ;;
                    2) share_node_link || true ;;
                    *) : ;;
                esac ;;
            10) reset_ports || true ;;
            11) require_root; ${EDITOR:-vi} "$SB_CONFIG"
                "$SB_BIN" check -c "$SB_CONFIG" &>/dev/null && {
                    svc_restart && info "配置已保存并重启"
                } || { err "配置有误,未重启"; "$SB_BIN" check -c "$SB_CONFIG" || true; } ;;
            12) show_traffic || true ;;
            13) reset_traffic_log || true ;;
            14) [[ -f "$SB_LOG" ]] && tail -f "$SB_LOG" || journalctl -u sing-box -f || true ;;
            15) verify_relay || true ;;
            16) sync_time || true ;;
            0)  exit 0 ;;
            *)  warn "无效选项: $opt" ;;
        esac

        echo ""; ask "按回车继续..."; read -r
    done
}

# ════════════════════════════════════════════════════════════
#  命令行入口
# ════════════════════════════════════════════════════════════

print_help() {
    cat <<HELP
VOLSB — sing-box 服务端部署管理脚本 v${VOLSB_VER}
项目地址: https://github.com/chnnic/VOLSB

用法:
  volsb [命令]

命令:
  (无参数)         进入交互式管理界面
  install          全新安装
  relay            以线路机模式安装
  add              追加协议到现有配置
  update           升级 sing-box 核心版本
  self-update      更新 VOLSB 脚本自身
  uninstall        完全卸载
  start            启动服务
  stop             停止服务
  restart          重启服务
  status           查看运行状态
  info             查看节点信息和分享链接
  traffic          查看流量统计
  log              实时日志
  sync-time        强制同步系统时间
  verify           验证线路机转发连通性
  -h, --help       显示帮助

HELP
}

# relay 模式命令行参数解析
parse_relay_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --land-addr)   LAND_ADDR="$2";   shift 2 ;;
            --land-port)   LAND_PORT="$2";   shift 2 ;;
            --land-pass)   LAND_PASS="$2";   shift 2 ;;
            --land-method) LAND_METHOD="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
}

main() {
    local cmd="${1:-menu}"; [[ $# -gt 0 ]] && shift || true

    case "$cmd" in
        install|i)        do_install ;;
        relay)
            require_root; detect_os; detect_arch; install_deps; setup_dirs
            local ver; ver=$(get_latest_version)
            install_binary "$ver"; install_service; install_shortcut
            cat > "$SB_INFO" <<HDR
==============================================
  VOLSB 线路机 — 节点信息
  安装时间 : $(date '+%Y-%m-%d %H:%M:%S')
==============================================
HDR
            secure_sensitive_files
            parse_relay_args "$@"
            ask_connect_addr || exit 0
            deploy_relay || exit 1
            assemble_relay_check || exit 1
            svc_start; sleep 2
            svc_active && info "线路机运行中 ✔" || { err "启动失败"; exit 1; }
            show_nodes
            ;;
        add)
            require_root
            [[ -f "$SB_CONFIG" ]] || die "请先安装"
            ask_connect_addr || exit 0
            select_protocols || exit 0
            if append_and_write_config; then
                svc_restart && { info "已更新并重启"; show_nodes; }
            else
                err "配置未更新，请根据上方错误重新操作"
            fi ;;
        update|upgrade)   do_update_singbox ;;
        self-update)      do_update_script ;;
        sync-time)        sync_time ;;
        verify)           verify_relay ;;
        uninstall|remove) detect_os; do_uninstall ;;
        start)            require_root
                          [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
                          svc_start ;;
        stop)             require_root
                          [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
                          svc_stop ;;
        restart|r)        require_root
                          [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
                          svc_restart ;;
        status|s)         [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
                          svc_status ;;
        info|node)        show_nodes ;;
        traffic|stats)    show_traffic ;;
        log|logs)         [[ -f "$SB_LOG" ]] && tail -f "$SB_LOG" \
                              || journalctl -u sing-box -f ;;
        menu|"")          main_menu ;;
        -h|--help|help)   print_help ;;
        *)                err "未知命令: $cmd"; print_help; exit 1 ;;
    esac
}

main "$@"
