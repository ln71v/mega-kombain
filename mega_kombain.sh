#!/bin/bash

# ================================================================
#  АДМИНСКИЙ КОМБАЙН (WARP + Amnezia)
#  Управление WARP, статус Amnezia, автозагрузка через systemd
# ================================================================

set -euo pipefail

# --- Цвета для вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Этот скрипт необходимо запускать от root (sudo).${NC}"
        exit 1
    fi
}

get_amnezia_container() {
    docker ps --format '{{.Names}}' | grep -iE 'amnezia-awg2|amnezia-awg|amnezia-wg' | head -n1
}

check_amnezia() {
    local cont
    cont=$(get_amnezia_container)
    if [[ -n "$cont" ]]; then
        echo -e "${GREEN}✅ $cont запущен${NC}"
    else
        echo -e "${RED}❌ Контейнер не найден${NC}"
    fi
}

check_warp() {
    if wg show warp 2>/dev/null | grep -q "latest handshake"; then
        echo -e "${GREEN}✅ WARP активен${NC}"
    else
        echo -e "${RED}❌ WARP не активен${NC}"
    fi
}

get_latest_wgcf_version() {
    local version
    version=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep tag_name | cut -d '"' -f4)
    echo "$version"
}

setup_warp() {
    if [[ -f /usr/local/bin/warp-up.sh ]]; then
        echo -e "${YELLOW}WARP уже установлен. Переустановить? (y/n)${NC}"
        read -p "Выбери: " ans
        if [[ "$ans" != "y" ]]; then
            echo -e "${YELLOW}Отмена установки.${NC}"
            return 0
        fi
    fi

    echo -e "${YELLOW}→ Установка зависимостей...${NC}"
    apt-get update -y && apt-get install -y wireguard-tools curl wget iptables qrencode docker.io 2>/dev/null || true

    echo -e "${YELLOW}→ Загрузка последней версии wgcf...${NC}"
    local latest_version
    latest_version=$(get_latest_wgcf_version)
    if [[ -z "$latest_version" ]]; then
        echo -e "${RED}❌ Не удалось получить версию wgcf. Использую дефолтную 2.2.22${NC}"
        latest_version="2.2.22"
    fi
    
    wget -qO /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/${latest_version}/wgcf_${latest_version}_linux_amd64"
    chmod +x /usr/local/bin/wgcf

    mkdir -p /etc/wireguard
    cd /etc/wireguard
    rm -f wgcf-account.toml wgcf-profile.conf

    echo -e "${YELLOW}→ Регистрация профиля Cloudflare WARP...${NC}"
    timeout 30 wgcf register --accept-tos >/dev/null 2>&1 || true
    wgcf generate >/dev/null

    local priv
    priv=$(grep PrivateKey wgcf-profile.conf | awk '{print $3}')
    local endpoint
    endpoint=$(grep Endpoint wgcf-profile.conf | awk '{print $3}')
    [[ -z "$endpoint" ]] && endpoint="162.159.192.1:2408"

    cat > /etc/wireguard/warp.wg.conf << EOF
[Interface]
PrivateKey = $priv
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
PersistentKeepalive = 25
EOF

    # --- Скрипт запуска туннеля ---
    cat > /usr/local/bin/warp-up.sh << 'WARPSH'
#!/bin/bash
set -e

get_host_interface() {
    local cont_name="$1"
    local net_name
    net_name=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$cont_name" 2>/dev/null)
    [[ "$net_name" == "bridge" ]] && { echo "docker0"; return; }
    
    local net_id
    net_id=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$v.NetworkID}}{{end}}' "$cont_name" 2>/dev/null)
    [[ -z "$net_id" ]] && { echo "amn0"; return; }
    
    local iface
    iface=$(ip -br link | grep -E "^br-${net_id:0:12}" | awk '{print $1}')
    [[ -n "$iface" ]] && echo "$iface" || echo "amn0"
}

wait_for_container() {
    for i in {1..30}; do
        local cont
        cont=$(docker ps --format '{{.Names}}' | grep -iE 'amnezia-awg2|amnezia-awg|amnezia-wg' | head -n1)
        [[ -n "$cont" ]] && { echo "$cont"; return 0; }
        sleep 2
    done
    return 1
}

ip link delete warp 2>/dev/null || true
ip link add warp type wireguard
wg setconf warp /etc/wireguard/warp.wg.conf

WARP_IP=$(grep Address /etc/wireguard/wgcf-profile.conf 2>/dev/null | awk '{print $3}' | head -1 | cut -d/ -f1)
[[ -z "$WARP_IP" ]] && WARP_IP="172.16.0.2"
ip addr add ${WARP_IP}/32 dev warp
ip link set mtu 1280 up dev warp

cont=$(wait_for_container)
if [[ -z "$cont" ]]; then
    echo "❌ Контейнер Amnezia не найден."
    exit 1
fi

iface=$(get_host_interface "$cont")
port=$(docker port "$cont" 2>/dev/null | grep udp | head -1 | awk -F ':' '{print $NF}')
[[ -z "$port" ]] && port="35201"

iptables -t mangle -F PREROUTING 2>/dev/null || true
iptables -t nat -D POSTROUTING -o warp -j MASQUERADE 2>/dev/null || true
ip rule del fwmark 51820 table 51820 2>/dev/null || true
ip route flush table 51820 2>/dev/null || true

iptables -t mangle -A PREROUTING -i "$iface" -p udp --sport "$port" -j RETURN 2>/dev/null || true
iptables -t mangle -A PREROUTING -i "$iface" -j MARK --set-mark 51820 2>/dev/null || true
ip rule add fwmark 51820 table 51820 2>/dev/null || true
ip route add default dev warp table 51820 2>/dev/null || true
iptables -t nat -A POSTROUTING -o warp -j MASQUERADE 2>/dev/null || true
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "✅ WARP поднят!"
wg show warp
WARPSH
    chmod +x /usr/local/bin/warp-up.sh

    # --- Скрипт остановки туннеля ---
    cat > /usr/local/bin/warp-down.sh << 'WARPDOWN'
#!/bin/bash
iptables -t mangle -F PREROUTING 2>/dev/null || true
iptables -t nat -D POSTROUTING -o warp -j MASQUERADE 2>/dev/null || true
ip rule del fwmark 51820 table 51820 2>/dev/null || true
ip route flush table 51820 2>/dev/null || true
ip link set warp down 2>/dev/null || true
ip link delete warp 2>/dev/null || true
echo "✅ WARP опущен."
WARPDOWN
    chmod +x /usr/local/bin/warp-down.sh

    # --- Системный демон ---
    cat > /etc/systemd/system/warp.service << EOF
[Unit]
Description=WARP Tunnel for Amnezia
After=network.target docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-up.sh
ExecStop=/usr/local/bin/warp-down.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable warp.service
    systemctl start warp.service

    echo -e "${GREEN}✅ WARP установлен и успешно запущен.${NC}"
}

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${YELLOW}   АДМИНСКИЙ КОМБАЙН (WARP + Amnezia)  ${NC}"
        echo -e "${CYAN}============================================================${NC}"
        echo -e "  Amnezia: $(check_amnezia)"
        echo -e "  WARP:    $(check_warp)"
        echo -e "${CYAN}============================================================${NC}"
        echo -e "  ${GREEN}1.${NC} Управление WARP (поднять / опустить / статус)"
        echo -e "  ${GREEN}2.${NC} Полная зачистка системы от WARP"
        echo -e "  ${RED}0.${NC} Выйти"
        echo -e "${CYAN}============================================================${NC}"
        read -p "Твой выбор, начальник: " choice

        case $choice in
            1)
                echo -e "\n${CYAN}--- Управление WARP ---${NC}"
                echo "1) Поднять / Установить WARP"
                echo "2) Насильно опустить WARP"
                echo "3) Проверить статус и внешний IP"
                read -p "Выбери подпункт: " sub
                case $sub in
                    1)
                        if [[ ! -f /usr/local/bin/warp-up.sh ]]; then
                            setup_warp
                        else
                            systemctl start warp.service || /usr/local/bin/warp-up.sh
                        fi
                        ;;
                    2)
                        if [[ ! -f /usr/local/bin/warp-down.sh ]]; then
                            echo -e "${RED}❌ Утилита не установлена.${NC}"
                        else
                            systemctl stop warp.service || /usr/local/bin/warp-down.sh
                        fi
                        ;;
                    3)
                        if [[ ! -f /usr/local/bin/warp-up.sh ]]; then
                            echo -e "${RED}❌ WARP не настроен.${NC}"
                        else
                            if wg show warp 2>/dev/null | grep -q "latest handshake"; then
                                echo -e "${GREEN}✅ WARP активен.${NC}"
                                wg show warp
                                echo -e "${CYAN}Внешний IP через туннель:${NC} $(curl -s --interface warp ifconfig.me 2>/dev/null || echo 'не получен')"
                            else
                                echo -e "${RED}❌ WARP не активен.${NC}"
                            fi
                        fi
                        ;;
                    *) echo "Неверный выбор." ;;
                esac
                read -p "Нажми Enter для продолжения..." _
                ;;
            2)
                echo -e "\n${RED}Выполняется полная очистка WARP...${NC}"
                systemctl stop warp.service 2>/dev/null || true
                systemctl disable warp.service 2>/dev/null || true
                /usr/local/bin/warp-down.sh 2>/dev/null || true
                rm -f /etc/systemd/system/warp.service
                systemctl daemon-reload
                rm -f /usr/local/bin/warp-up.sh /usr/local/bin/warp-down.sh /usr/local/bin/wgcf
                rm -rf /etc/wireguard/warp.wg.conf /etc/wireguard/wgcf-account.toml /etc/wireguard/wgcf-profile.conf
                echo -e "${GREEN}✅ Зачистка завершена!${NC}"
                read -p "Нажми Enter для продолжения..." _
                ;;
            0)
                echo -e "\n${GREEN}Удачи!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Неверный ввод.${NC}"
                sleep 1
                ;;
        esac
    done
}

check_root
main_menu
