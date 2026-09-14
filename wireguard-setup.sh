#!/bin/bash

# WireGuard Server 安裝及 Client 配置生成腳本
# 適用於 Ubuntu，VPN IPv4 網段固定使用 /24

set -euo pipefail
umask 077

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WG_CONFIG="/etc/wireguard/wg0.conf"
DNSMASQ_CONFIG="/etc/dnsmasq.d/wireguard.conf"

show_step() {
    echo ""
    echo -e "${GREEN}=== $1 ===${NC}"
}

show_info() {
    echo -e "${BLUE}$1${NC}"
}

show_warning() {
    echo -e "${YELLOW}$1${NC}"
}

show_error() {
    echo -e "${RED}錯誤: $1${NC}" >&2
    exit 1
}

# 檢查執行環境
check_environment() {
    if [ "$EUID" -ne 0 ]; then
        show_error "請使用 sudo bash wireguard-setup.sh 執行"
    fi

    OUTPUT_USER="${SUDO_USER:-root}"
    OUTPUT_HOME=$(getent passwd "$OUTPUT_USER" | cut -d: -f6)

    if [ -z "$OUTPUT_HOME" ]; then
        show_error "找不到 $OUTPUT_USER 的家目錄"
    fi

    CLIENT_DIR="$OUTPUT_HOME/wireguard-client"

    exec 9>/run/lock/wireguard-client.lock
    if ! flock -n 9; then
        show_error "另一份 WireGuard 腳本正在執行"
    fi

    if [ -L "$WG_CONFIG" ] || [ -L "$CLIENT_DIR" ]; then
        show_error "配置及輸出目錄不可使用符號連結"
    fi
}

# 安裝文章需要的依賴
install_dependencies() {
    show_step "安裝 WireGuard 與 dnsmasq"
    apt-get update
    apt-get install -y wireguard dnsmasq
}

# 嘗試取得 Server 公網 IPv4；沒有 curl 時留空讓使用者輸入
detect_endpoint() {
    DETECTED_ENDPOINT=""

    if command -v curl >/dev/null 2>&1; then
        DETECTED_ENDPOINT=$(curl -4fsS --connect-timeout 3 --max-time 8 https://api.ipify.org || true)
    fi

    if ! [[ "$DETECTED_ENDPOINT" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        DETECTED_ENDPOINT=""
    fi
}

# Endpoint 每次詢問，不保存上一次輸入
ask_endpoint() {
    read -r -p "Server 公網 IP／網域 [$DETECTED_ENDPOINT]: " ENDPOINT
    ENDPOINT="${ENDPOINT:-$DETECTED_ENDPOINT}"

    if ! [[ "$ENDPOINT" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        show_error "請輸入 IPv4 或網域，不包含協定及 Port"
    fi
}

# VPN IPv4 網段使用 x.x.x.0/24
set_vpn_network() {
    local network_address="${1%/24}"
    local first second third fourth

    if [ "$1" = "$network_address" ]; then
        show_error "VPN IPv4 網段必須使用 /24"
    fi

    IFS=. read -r first second third fourth <<< "$network_address"

    for octet in "$first" "$second" "$third" "$fourth"; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]] || [ "$((10#$octet))" -gt 255 ]; then
            show_error "VPN IPv4 網段格式錯誤"
        fi
    done

    first=$((10#$first))
    second=$((10#$second))
    third=$((10#$third))
    fourth=$((10#$fourth))

    if [ "$fourth" -ne 0 ]; then
        show_error "請輸入 /24 網段位址，例如 10.66.66.0/24"
    fi

    VPN_NETWORK="$first.$second.$third.0/24"
    VPN_PREFIX="$first.$second.$third."
    SERVER_IP="${VPN_PREFIX}1"
}

# 首次執行時詢問 Server 設定
ask_server_settings() {
    show_step "設定 WireGuard Server"

    read -r -p "UDP Port [51820]: " WG_PORT
    WG_PORT="${WG_PORT:-51820}"

    if ! [[ "$WG_PORT" =~ ^[0-9]{1,5}$ ]]; then
        show_error "UDP Port 必須是 1–65535"
    fi

    WG_PORT=$((10#$WG_PORT))

    if [ "$WG_PORT" -lt 1 ] || [ "$WG_PORT" -gt 65535 ]; then
        show_error "UDP Port 必須是 1–65535"
    fi

    DEFAULT_INTERFACE=$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    read -r -p "公網出口介面 [$DEFAULT_INTERFACE]: " WAN_INTERFACE
    WAN_INTERFACE="${WAN_INTERFACE:-$DEFAULT_INTERFACE}"

    if ! [[ "$WAN_INTERFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] || ! ip link show dev "$WAN_INTERFACE" >/dev/null 2>&1; then
        show_error "找不到網路介面 $WAN_INTERFACE"
    fi

    read -r -p "VPN IPv4 網段 [10.66.66.0/24]: " VPN_NETWORK
    set_vpn_network "${VPN_NETWORK:-10.66.66.0/24}"

    if ip -4 route show | grep -Fq "${VPN_PREFIX}0/24"; then
        show_error "$VPN_NETWORK 已存在於路由表"
    fi
}

# 讀取既有 wg0 設定，新增 Peer 時沿用
load_server_settings() {
    show_step "偵測到 wg0.conf，進入新增 Peer mode"
    show_info "沿用既有 UDP Port、VPN IPv4 網段與 Server 金鑰"

    SERVER_IP=$(sed -nE 's/^Address[[:space:]]*=[[:space:]]*([0-9.]+)\/24,[[:space:]]*fd66:66:66::1\/64[[:space:]]*$/\1/p' "$WG_CONFIG")
    WG_PORT=$(sed -nE 's/^ListenPort[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$WG_CONFIG")
    SERVER_PRIVATE_KEY=$(sed -nE 's/^PrivateKey[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$WG_CONFIG")

    if [ -z "$SERVER_IP" ] || [ -z "$WG_PORT" ] || [ -z "$SERVER_PRIVATE_KEY" ]; then
        show_error "無法讀取既有 wg0 的 Address、ListenPort 或 PrivateKey"
    fi

    configured_server_ip="$SERVER_IP"
    set_vpn_network "${SERVER_IP%.*}.0/24"

    if [ "$configured_server_ip" != "$SERVER_IP" ]; then
        show_error "既有 wg0 的 Server IPv4 必須是 /24 網段的 .1"
    fi
}

# 建立 Server、DNS 及轉送設定
create_server() {
    show_step "建立 wg0"

    install -d -m 700 /etc/wireguard
    SERVER_PRIVATE_KEY=$(wg genkey)

    cat > "$WG_CONFIG" <<EOF
[Interface]
Address = $SERVER_IP/24, fd66:66:66::1/64
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s $VPN_NETWORK -o $WAN_INTERFACE -j MASQUERADE; ip6tables -I FORWARD 1 -i %i -j REJECT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s $VPN_NETWORK -o $WAN_INTERFACE -j MASQUERADE; ip6tables -D FORWARD -i %i -j REJECT
EOF

    chmod 600 "$WG_CONFIG"

    show_step "設定 IPv4 Forwarding"
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
    sysctl --system

    show_step "設定 dnsmasq"

    cat > "$DNSMASQ_CONFIG" <<EOF
interface=wg0
listen-address=$SERVER_IP
bind-dynamic
filter-AAAA
server=1.1.1.1
EOF

    dnsmasq --test
    systemctl enable --now wg-quick@wg0
    systemctl enable dnsmasq
    systemctl restart dnsmasq

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        show_step "開放 WireGuard UDP Port"
        ufw allow "$WG_PORT/udp"
    fi
}

# 詢問並檢查 Client 名稱
ask_client_names() {
    read -r -p "Client 名稱（空格分隔，例如 mac iphone ipad）: " CLIENT_NAMES_INPUT
    read -r -a CLIENT_NAMES <<< "$CLIENT_NAMES_INPUT"

    if [ "${#CLIENT_NAMES[@]}" -eq 0 ]; then
        show_error "至少輸入一個 Client 名稱"
    fi

    declare -A used_names

    for client_name in "${CLIENT_NAMES[@]}"; do
        if ! [[ "$client_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}$ ]]; then
            show_error "$client_name 不是有效名稱；只可使用英數字、底線及連字號"
        fi

        lowercase_name="${client_name,,}"

        if [ -n "${used_names[$lowercase_name]+yes}" ]; then
            show_error "Client 名稱重複：$client_name"
        fi

        used_names[$lowercase_name]=1

        if [ -e "$CLIENT_DIR/$client_name.conf" ] || [ -L "$CLIENT_DIR/$client_name.conf" ]; then
            show_error "$client_name.conf 已存在"
        fi

        if grep -Eiq "^#[[:space:]]*$client_name[[:space:]]*$" "$WG_CONFIG"; then
            show_error "wg0.conf 已有 Client：$client_name"
        fi
    done
}

# 收集足夠的可用 Client IP
find_available_ips() {
    CLIENT_IPS=()

    for host_number in {2..254}; do
        client_ip="${VPN_PREFIX}${host_number}"

        if ! grep -Fq "$client_ip/32" "$WG_CONFIG"; then
            CLIENT_IPS+=("$client_ip")
        fi

        if [ "${#CLIENT_IPS[@]}" -eq "${#CLIENT_NAMES[@]}" ]; then
            return
        fi
    done

    show_error "$VPN_NETWORK 沒有足夠的 Client IP"
}

# 備份 Server 設定並移除 SaveConfig
prepare_server_config() {
    local backup_file

    backup_file=$(mktemp /etc/wireguard/wg0.conf.backup.XXXXXX)
    cp -p "$WG_CONFIG" "$backup_file"
    sed -i '/^SaveConfig[[:space:]]*=/d' "$WG_CONFIG"

    show_info "Server 配置已備份至 $backup_file"
}

# 逐個生成 Client conf，並將 Peer 加到 wg0.conf 尾部
create_clients() {
    show_step "生成 Client 配置"

    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
    install -d -m 700 -o "$OUTPUT_USER" "$CLIENT_DIR"

    for index in "${!CLIENT_NAMES[@]}"; do
        client_name="${CLIENT_NAMES[$index]}"
        client_ip="${CLIENT_IPS[$index]}"
        host_number="${client_ip##*.}"
        client_private_key=$(wg genkey)
        client_public_key=$(echo "$client_private_key" | wg pubkey)

        show_info "建立 $client_name ($client_ip)"

        cat >> "$WG_CONFIG" <<EOF

[Peer]
# $client_name
PublicKey = $client_public_key
AllowedIPs = $client_ip/32, fd66:66:66::$host_number/128
EOF

        cat > "$CLIENT_DIR/$client_name.conf" <<EOF
# $client_name
[Interface]
PrivateKey = $client_private_key
Address = $client_ip/32, fd66:66:66::$host_number/128
DNS = $SERVER_IP
MTU = 1280

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $ENDPOINT:$WG_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

        chmod 600 "$CLIENT_DIR/$client_name.conf"
        chown "$OUTPUT_USER" "$CLIENT_DIR/$client_name.conf"
    done

    chmod 600 "$WG_CONFIG"
}

restart_services() {
    show_step "重啟服務"
    systemctl enable dnsmasq
    systemctl restart dnsmasq
    systemctl enable wg-quick@wg0
    systemctl restart wg-quick@wg0
}

show_result() {
    echo ""
    echo -e "${GREEN}WireGuard 配置完成！${NC}"
    echo ""
    echo "Client 配置檔案："

    for client_name in "${CLIENT_NAMES[@]}"; do
        echo "  $CLIENT_DIR/$client_name.conf"
    done

    echo ""
    echo -e "${BLUE}下一步：${NC}"
    echo "1. 在各 Client 下載屬於自己的 .conf 檔案。"
    echo "2. 開啟 Client 端的 WireGuard 軟件。"
    echo "3. 選擇「Import tunnel(s) from file」，匯入對應的 .conf 檔案。"
    echo "4. 每台 Client 必須使用各自的配置，不要共用同一個 .conf。"
    echo ""
    show_warning "請確認雲端 Security Group 已允許 UDP $WG_PORT"
}

main() {
    check_environment
    detect_endpoint

    if [ -f "$WG_CONFIG" ]; then
        load_server_settings
    else
        install_dependencies
        ask_server_settings
        create_server
    fi

    ask_endpoint
    ask_client_names
    find_available_ips
    prepare_server_config
    create_clients
    restart_services
    show_result
}

main
