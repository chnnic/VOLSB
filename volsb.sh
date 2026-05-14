cat << 'EOF' > sb.sh
#!/bin/bash

# ==========================================
# Sing-box 综合管理脚本 (Full Version)
# ==========================================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 路径
SB_CONF="/etc/sing-box/config.json"
SB_BIN="/usr/local/bin/sing-box"
LINK_FILE="/etc/sing-box/links.txt"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 运行${PLAIN}" && exit 1

# --- 基础安装 ---
install_env() {
    echo -e "${YELLOW}正在安装依赖和 Sing-box...${PLAIN}"
    apt update && apt install -y curl jq openssl uuid-runtime wget tar
    
    # 获取最新版
    local latest_ver=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    local arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac
    
    wget -O sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz"
    tar -zxvf sb.tar.gz
    cp sing-box-*/sing-box $SB_BIN && chmod +x $SB_BIN
    rm -rf sb.tar.gz sing-box-*
    
    mkdir -p /etc/sing-box
    echo -e "${GREEN}安装完成，当前版本: $latest_ver${PLAIN}"
}

# --- 初始化基础配置 ---
init_conf() {
    cat > $SB_CONF <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "experimental": {
    "control": { "address": "127.0.0.1:6789" }
  },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "blocked", "tag": "block" }
  ]
}
EOF
    systemctl stop sing-box 2>/dev/null
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
}

# --- 批量添加 Reality 节点 ---
add_reality_batch() {
    read -p "生成数量: " count
    read -p "起始端口: " start_port
    local server_ip=$(curl -s ip.sb)
    
    local keys=$($SB_BIN generate reality-keypair)
    local priv=$(echo "$keys" | grep "Private key" | awk '{print $3}')
    local pub=$(echo "$keys" | grep "Public key" | awk '{print $3}')
    local sid=$(openssl rand -hex 8)

    for ((i=0; i<count; i++)); do
        local port=$((start_port + i))
        local uuid=$(uuidgen)
        local tag="Reality-$port"
        
        jq ".inbounds += [{
            \"type\": \"vless\",
            \"tag\": \"$tag\",
            \"listen\": \"::\",
            \"listen_port\": $port,
            \"users\": [{ \"uuid\": \"$uuid\", \"flow\": \"xtls-rprx-vision\" }],
            \"tls\": {
                \"enabled\": true,
                \"server_name\": \"www.microsoft.com\",
                \"reality\": {
                    \"enabled\": true,
                    \"handshake\": { \"server\": \"www.microsoft.com\", \"server_port\": 443 },
                    \"private_key\": \"$priv\",
                    \"short_id\": [ \"$sid\" ]
                }
            }
        }]" $SB_CONF > tmp.json && mv tmp.json $SB_CONF
        
        echo "vless://$uuid@$server_ip:$port?security=reality&sni=www.microsoft.com&fp=chrome&pbk=$pub&sid=$sid&type=grpc#$tag" >> $LINK_FILE
    done
    systemctl restart sing-box
    echo -e "${GREEN}成功生成 $count 个节点，链接已存入 $LINK_FILE${PLAIN}"
}

# --- 添加 Hysteria2 节点 ---
add_hy2() {
    read -p "端口: " port
    local uuid=$(uuidgen)
    local server_ip=$(curl -s ip.sb)
    
    # 生成自签名证书
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/sing-box/hy2.key -out /etc/sing-box/hy2.crt -days 3650 -subj "/CN=bing.com"
    
    jq ".inbounds += [{
        \"type\": \"hysteria2\",
        \"tag\": \"Hy2-$port\",
        \"listen\": \"::\",
        \"listen_port\": $port,
        \"users\": [{ \"password\": \"$uuid\" }],
        \"tls\": {
            \"enabled\": true,
            \"certificate_path\": \"/etc/sing-box/hy2.crt\",
            \"key_path\": \"/etc/sing-box/hy2.key\"
        }
    }]" $SB_CONF > tmp.json && mv tmp.json $SB_CONF
    
    echo "hysteria2://$uuid@$server_ip:$port?insecure=1&sni=bing.com#Hy2-$port" >> $LINK_FILE
    systemctl restart sing-box
    echo -e "${GREEN}Hy2 节点已添加${PLAIN}"
}

# --- 流量统计 ---
show_stats() {
    echo -e "${YELLOW}--- 实时流量概览 ---${PLAIN}"
    local data=$(curl -s http://127.0.0.1:6789/stats)
    if [[ -z "$data" ]]; then
        echo "无法获取数据，请确保服务已启动并开启 API"
    else
        echo "$data" | jq -r '.inbounds[] | "[\(.tag)] 上行: \((.up / 1024 / 1024 | tonumber)) MB | 下行: \((.down / 1024 / 1024 | tonumber)) MB"'
    fi
}

# --- 中转方案 (线路机) ---
setup_relay() {
    read -p "线路机本地入口端口: " l_port
    read -p "落地机 IP: " r_ip
    read -p "落地机 SS 端口: " r_port
    read -p "落地机 SS 密码: " r_pw
    read -p "落地机 SS 加密方式 (如 aes-256-gcm): " r_method

    # 1. 增加到落地机的 Outbound
    jq ".outbounds = [{
        \"type\": \"shadowsocks\",
        \"tag\": \"relay-out\",
        \"server\": \"$r_ip\",
        \"server_port\": $r_port,
        \"method\": \"$r_method\",
        \"password\": \"$r_pw\"
    }] + .outbounds" $SB_CONF > tmp.json && mv tmp.json $SB_CONF

    # 2. 增加 Reality 入口并路由到该 Outbound
    local keys=$($SB_BIN generate reality-keypair)
    local priv=$(echo "$keys" | grep "Private key" | awk '{print $3}')
    
    jq ".inbounds += [{
        \"type\": \"vless\",
        \"tag\": \"Relay-In\",
        \"listen_port\": $l_port,
        \"users\": [{ \"uuid\": \"$(uuidgen)\" }],
        \"tls\": { \"enabled\": true, \"reality\": { \"enabled\": true, \"private_key\": \"$priv\", \"short_id\": [\"$(openssl rand -hex 8)\"], \"handshake\": { \"server\": \"www.google.com\", \"server_port\": 443 } } }
    }]" $SB_CONF > tmp.json && mv tmp.json $SB_CONF
    
    systemctl restart sing-box
    echo -e "${GREEN}中转配置完成！流量将经由 Reality 端口 $l_port 转发至落地机 SS${PLAIN}"
}

# --- 主菜单 ---
while true; do
    echo -e "
${GREEN}Sing-box 自动化部署工具${PLAIN}
---
${YELLOW}1.${PLAIN} 安装/更新 Sing-box
${YELLOW}2.${PLAIN} 批量生成 Reality 节点
${YELLOW}3.${PLAIN} 添加 Hysteria2 节点
${YELLOW}4.${PLAIN} 配置线路机中转 (Reality -> SS)
${YELLOW}5.${PLAIN} 查看流量统计
${YELLOW}6.${PLAIN} 查看所有节点链接
${YELLOW}7.${PLAIN} 重置并清空所有配置
${YELLOW}0.${PLAIN} 退出
"
    read -p "选择操作: " menu_choice
    case $menu_choice in
        1) install_env && init_conf ;;
        2) add_reality_batch ;;
        3) add_hy2 ;;
        4) setup_relay ;;
        5) show_stats ;;
        6) cat $LINK_FILE ;;
        7) init_conf && echo "" > $LINK_FILE ;;
        0) exit 0 ;;
    esac
done
EOF

chmod +x sb.sh
./sb.sh
