cat > mega_kombain.sh << 'EOF'
#!/bin/bash

# ================================================================
#  АДМИНСКИЙ КОМБАЙН (WARP + Amnezia) – минималистичная версия
#  Управление WARP, статус Amnezia, автозагрузка
#  Версия: 1.0 – с динамической загрузкой последней версии wgcf
# ================================================================

set -euo pipefail

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Проверка root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Запускай от root (sudo).${NC}"
        exit 1
    fi
}

# ---- Находим контейнер Amnezia ----
get_amnezia_container() {
    docker ps --format '{{.Names}}' | grep -iE 'amnezia-awg2|amnezia-awg|amnezia-wg' | head -n1
}

# ---- Шапка: статус Amnezia ----
check_amnezia() {
    local cont=$(get_amnezia_container)
    if [[ -n "$cont" ]]; then
        echo -e "${GREEN}✅ $cont запущен${NC}"
    else
        echo -e "${RED}❌ Контейнер не найден${NC}"
    fi
}

# ---- Шапка: статус WARP ----
check_warp() {
    if wg show warp 2>/dev/null | grep -q "latest handshake"; then
        echo -e "${GREEN}✅ WARP активен${NC}"
    else
        echo -e "${RED}❌ WARP не активен${NC}"
    fi
}

# ---- Определение bridge-интерфейса контейнера ----
get_host_interface() {
    local cont_name="$1"
    local net_name
    net_name=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$cont_name" 2>/dev/null)
    if [[ "$net_name" == "bridge" ]]; then
        echo "docker0"
        return
    fi
    local net_id
    net_id=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$v.NetworkID}}{{end}}' "$cont_name" 2>/dev/null)
    if [[ -z "$net_id" ]]; then
        echo "amn0"
        return
    fi
    local iface
    iface=$(ip -br link | grep -E "^br-${net_id:0:12}" | awk '{print $1}')
    if [[ -n "$iface" ]]; then
        echo "$iface"
    else
        iface=$(ip -br link | grep -E "^br-${net_id}" | awk '{print $1}')
        [[ -n "$iface" ]] && echo "$iface" || echo "amn0"
    fi
}

# ---- Получение последней версии wgcf (динамически) ----
get_latest_wgcf_version() {
    curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep tag_name | cut -d '"' -f4
}

# ---- Установка WARP (создаёт warp-up.sh и warp-down.sh) ----
setup_warp() {
    if [[ -f /usr/local/bin/warp-up.sh ]]; then
        echo -e "${YELLOW}WARP уже установлен. Переустановить? (y/n)${NC}"
        read -p "Выбери: " ans
        if [[ "$ans" != "y" ]]; then
            echo -e "${YELLOW}Отмена.${NC}"
            return 0
        fi
    fi

    echo -e "${YELLOW}→ Установка WARP...${NC}"

    # Устанавливаем зависимости
    apt install -y wireguard-tools curl wget iptables qrencode 2>/dev/null || true

    # Получаем последнюю версию wgcf
    echo -e "${YELLOW}→ Загрузка последней версии wgcf...${NC}"
    LATEST_VERSION=$(get_latest_wgcf_version)
    if [[ -z "$LATEST_VERSION" ]]; then
        echo -e "${RED}❌ Не удалось получить последнюю версию wgcf. Использую фиксированную 2.2.22${NC}"
        LATEST_VERSION="2.2.22"
    fi
    wget -qO /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/${LATEST_VERSION}/wgcf_${LATEST_VERSION}_linux_amd64"
    chmod +x /usr/local/bin/wgcf

    mkdir -p /etc/wireguard
    cd /etc/wireguard
    rm -f wgcf-account.toml wgcf-profile.conf

    # Регистрация и генерация
    timeout 30 wgcf register --accept-tos >/dev/null 2>&1
    wgcf generate >/dev/null

    local priv=$(grep PrivateKey wgcf-profile.conf | awk '{print $3}')
    local warp_ip=$(grep Address wgcf-profile.conf | awk '{print $3}' | head -1 | cut -d/ -f1)
    local endpoint=$(grep Endpoint wgcf-profile.conf | awk '{print $3}')
    [[ -z "$endpoint" ]] && endpoint="162.159.192.1:2408"

    cat > warp.wg.conf << EOJ
[Interface]
PrivateKey = $priv
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
PersistentKeepalive = 25
EOJ

    # Создаём warp-up.sh
    cat > /usr/local/bin/warp-up.sh << 'WARPSH'
#!/bin/bash
set -e

get_host_interface() {
    local cont_name="$1"
    local net_name=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$cont_name" 2>/dev/null)
    [[ "$net_name" == "bridge" ]] && { echo "docker0"; return; }
    local net_id=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$v.NetworkID}}{{end}}' "$cont_name" 2>/dev/null)
    [[ -z "$net_id" ]] && { echo "amn0"; return; }
    local iface=$(ip -br link | grep -E "^br-${net_id:0:12}" | awk '{print $1}')
    [[ -n "$iface" ]] && echo "$iface" || echo "amn0"
}

wait_for_container() {
    for i in {1..30}; do
        local cont=$(docker ps --format '{{.Names}}' | grep -iE 'amnezia-awg2|amnezia-awg|amnezia-wg' | head -n1)
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

    # warp-down.sh
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

    # systemd
    cat > /etc/systemd/system/warp.service << EOJ
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
EOJ
    systemctl daemon-reload
    systemctl enable warp.service
    systemctl start warp.service

    echo -e "${GREEN}✅ WARP установлен и настроен (версия wgcf: $LATEST_VERSION).${NC}"
    return 0
}

# ---- Основное меню ----
main_menu() {
    while true; do
        clear
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${YELLOW}   АДМИНСКИЙ КОМБАЙН (WARP + Amnezia)  ${NC}"
        echo -e "${CYAN}============================================================${NC}"
        echo -e "  Amnezia: $(check_amnezia)"
        echo -e "  WARP:    $(check_warp)"
        echo -e "${CYAN}============================================================${NC}"
        echo -e "  ${GREEN}1.${NC} Управление WARP (поднять/опустить/статус)"
        echo -e "  ${GREEN}2.${NC} Полная зачистка WARP"
        echo -e "  ${RED}0.${NC} Выйти"
        echo -e "${CYAN}============================================================${NC}"
        read -p "Твой выбор, начальник: " choice

        case $choice in
            1)
                echo -e "\n${CYAN}--- Управление WARP ---${NC}"
                echo "1) Поднять WARP"
                echo "2) Опустить WARP"
                echo "3) Показать статус"
                read -p "Выбери: " sub
                case $sub in
                    1)
                        if [[ ! -f /usr/local/bin/warp-up.sh ]]; then
                            echo -e "${YELLOW}WARP не установлен. Выполняем установку...${NC}"
                            setup_warp
                            if [[ $? -ne 0 ]]; then
                                echo -e "${RED}❌ Установка WARP не удалась.${NC}"
                                read -p "Жми Enter..."
                                continue
                            fi
                        fi
                        /usr/local/bin/warp-up.sh
                        ;;
                    2)
                        if [[ ! -f /usr/local/bin/warp-down.sh ]]; then
                            echo -e "${RED}❌ WARP не установлен. Сначала поднимите.${NC}"
                        else
                            /usr/local/bin/warp-down.sh
                        fi
                        ;;
                    3)
                        if [[ ! -f /usr/local/bin/warp-up.sh ]]; then
                            echo -e "${RED}❌ WARP не установлен.${NC}"
                        else
                            if wg show warp 2>/dev/null | grep -q "latest handshake"; then
                                echo -e "${GREEN}✅ WARP активен.${NC}"
                                wg show warp
                                echo -e "IP: $(curl -s --interface warp ifconfig.me 2>/dev/null || echo 'не получен')"
                            else
                                echo -e "${RED}❌ WARP не активен.${NC}"
                            fi
                        fi
                        ;;
                    *) echo "Неверно." ;;
                esac
                read -p "Жми Enter..."
                ;;
            2)
                echo -e "\n${RED}Полная зачистка WARP...${NC}"
                /usr/local/bin/warp-down.sh 2>/dev/null || true
                systemctl stop warp.service 2>/dev/null || true
                systemctl disable warp.service 2>/dev/null || true
                rm -f /etc/systemd/system/warp.service
                systemctl daemon-reload
                rm -f /etc/wireguard/warp.wg.conf /etc/wireguard/wgcf-account.toml /etc/wireguard/wgcf-profile.conf
                iptables -t mangle -F PREROUTING 2>/dev/null || true
                iptables -t nat -D POSTROUTING -o warp -j MASQUERADE 2>/dev/null || true
                ip rule del fwmark 51820 table 51820 2>/dev/null || true
                ip route flush table 51820 2>/dev/null || true
                echo -e "${GREEN}✅ WARP очищен.${NC}"
                read -p "Жми Enter..."
                ;;
            0)
                echo -e "\n${GREEN}Давай, бывай!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Неверный выбор.${NC}"
                sleep 1
                ;;
        esac
    done
}

# --- Запуск ---
check_root
main_menu
EOF

chmod +x mega_kombain.sh

echo -e "${GREEN}✅ Скрипт создан. Запускай: ./mega_kombain.sh${NC}"
