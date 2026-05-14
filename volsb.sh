#!/bin/bash

# 颜色设置
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 核心路径
SB_CONF="/etc/sing-box/config.json"
SB_BIN="/usr/local/bin/sing-box"
LINK_LOG="/etc/sing-box/nodes.txt"

# 检查 Root
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请以 root 用户运行！${PLAIN}" && exit 1

# --- 环境准备 ---
install_env() {
    echo -e "${YELLOW}正在配置运行环境...${PLAIN}"
    apt update && apt install -y curl jq openssl uuid-runtime wget tar
    
    # 安装最新的 Sing-box
    local latest_ver=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    local arch=$(uname -m)
    [[ "$arch" == "x86_64" ]] && arch="amd64" || arch="arm64"
    
    wget -O sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz"
    tar -zxvf sb.tar.gz && cp sing-box-*/sing-box $SB_BIN && chmod +x $SB_BIN
    rm -rf sb.tar.gz sing-box-*
    
    mkdir -p /etc/sing-box
    init_config
    setup_service
    echo -e "${GREEN}Sing-box $latest_ver 安装成功！${PLAIN}"
}

# --- 初始化 JSON 配置 ---
init_config() {
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
}

setup_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
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

# --- 批量节点生成逻辑 ---
add_nodes_batch() {
    echo -e "${YELLOW}1. VLESS-Reality  2. Hysteria2  3. TUIC v5${PLAIN}"
    read -p "选择协议类型: " p_type
    read -p "需要生成的节点数量: " count
    read -p "起始端口: " s_port
    
    local ip=$(curl -s ip.sb)
    
    for ((i=0; i<count; i++)); do
        local port=$((s_port + i))
        local uuid=$(uuidgen)
        local tag="Node-$port"
        
        if [[ "$p_type" == "1" ]]; then
            # Reality 逻辑
            local keys=$($SB_BIN generate reality-keypair)
            local priv=$(echo "$keys" | grep "Private" | awk '{print $3}')
            local pub=$(echo "$keys" | grep "Public" | awk '{print $3}')
            local sid=$(openssl rand -hex 8)
            
            jq ".inbounds += [{
                \"type\": \"vless\", \"tag\": \"$tag\", \"listen\": \"::\", \"listen_port\": $port,
                \"users\": [{ \"uuid\": \"$uuid\", \"flow\": \"xtls-rprx-vision\" }],
                \"tls\": { \"enabled\": true, \"server_name\": \"www.apple.com\",
                \"reality\": { \"enabled\": true, \"handshake\": { \"server\": \"www.apple.com\", \"server_port\": 443 },
                \"private_key\": \"$priv\", \"short_id\": [\"$sid\"] } }
            }]" $SB_CONF > tmp.json && mv tmp.json $SB_CONF
            echo "vless://$uuid@$ip:$port?security=reality&sni=www.apple.com&fp=chrome&pbk=$pub&sid=$sid&type=grpc#$tag" >> $LINK_LOG

        elif [[ "$p_type" == "2" ]]; then
            # Hy2 逻辑 (自签名)
            openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/sing-box/node.key -out /etc/sing-box/node.crt -days 3650 -subj "/CN=bing.com"
            jq ".inbounds += [{
                \"type\": \"hysteria2\", \"tag\": \"$tag\", \"listen_port\": $port,
                \"users\": [{ \"password\": \"$uuid\" }],
                \"tls\": { \"enabled\": true, \"certificate_path\": \"/etc/sing-box/node.crt\", \"key_path\": \"/etc/sing-box/node.key\" }
            }]" $SB_CONF > tmp.json && mv tmp.json $SB_CONF
            echo "hysteria2://$uuid@$ip:$port?insecure=1&sni=bing.com#$tag" >> $LINK_LOG
        fi
    done
    
    systemctl restart sing-box
    echo -e "${GREEN}批量节点已生成，链接已保存至 $LINK_LOG${PLAIN}"
}

# --- 线路机中转功能 ---
setup_relay() {
    echo -e "${YELLOW}--- 线路机中转配置 (Reality 入站 -> 落地机 SS 出站) ---${PLAIN}"
    read -p "线路机本地监听端口: " l_port
    read -p "落地机 IP: " r_ip
    read -p "落地机 SS 端口: " r_port
    read -p "落地机 SS 密码: " r_pw
    read -p "落地机 SS 加密 (aes-256-gcm): " r_method
    
    # 添加出口
    jq ".outbounds = [{
        \"type\": \"shadowsocks\", \"tag\": \"relay-out\",
        \"server\": \"$r_ip\", \"server_port\": $r_port,
        \"method\": \"$r_method\", \"password\": \"$r_pw\"
    }] + .outbounds" $SB_CONF > tmp.json && mv tmp.json $SB_CONF
    
    # 添加中转入站
    local keys=$($SB_BIN generate reality-keypair)
    local priv=$(echo "$keys" | grep "Private" | awk '{print $3}')
    local uuid=$(uuidgen)
    
    jq ".inbounds += [{
        \"type\": \"vless\", \"tag\": \"Relay-In\", \"listen_port\": $l_port,
        \"users\": [{ \"uuid\": \"$uuid\" }],
        \"tls\": { \"enabled\": true, \"reality\": { \"enabled\": true, \"private_key\": \"$priv\", \"short_id\": [\"$(openssl rand -hex 8)\"], \"handshake\": { \"server\": \"www.google.com\", \"server_port\": 443 } } }
    }]" $SB_CONF > tmp.json && mv tmp.json $SB_CONF
    
    systemctl restart sing-box
    echo -e "${GREEN}中转配置完成！中转 UUID: $uuid${PLAIN}"
}

# --- 流量管理面板 ---
show_stats() {
    echo -e "${YELLOW}--- 实时流量统计 (MB) ---${PLAIN}"
    local data=$(curl -s http://127.0.0.1:6789/stats)
    if [[ -z "$data" ]]; then
        echo "无法获取 API 数据，请检查服务状态"
    else
        echo "$data" | jq -r '.inbounds[] | "节点: \(.tag) | ⬆️ \((.up / 1048576) | tonumber | round) | ⬇️ \((.down / 1048576) | tonumber | round)"'
    fi
}

# --- 菜单循环 ---
while true; do
    echo -e "
${GREEN}Sing-box 自动化管理脚本${PLAIN}
---
1. 安装 / 重置环境
2. 批量生成多节点 (Reality/Hy2)
3. 配置线路机中转 (Reality -> SS)
4. 查看实时流量统计
5. 查看节点分享链接
0. 退出
"
    read -p "请输入选项: " opt
    case $opt in
        1) install_env ;;
        2) add_nodes_batch ;;
        3) setup_relay ;;
        4) show_stats ;;
        5) [[ -f $LINK_LOG ]] && cat $LINK_LOG || echo "暂无链接" ;;
        0) exit 0 ;;
    esac
done
