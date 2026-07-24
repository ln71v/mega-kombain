#!/bin/bash

# ================================================================
#  АДМИНСКИЙ КОМБАЙН (WARP + Amnezia) — STABLE MASTER EDITION
# ================================================================

set -euo pipefail

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

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

get_amnezia_container() {
    if ! command -v docker &>/dev/null; then
        return
    fi
    docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | \
    grep -iE 'amnezia|awg|wireguard|openvpn|xray' || true | \
    grep -v 'Exited' || true | \
    awk '{print $1}' | \
    head -n1
}

check_amnezia() {
    local cont
    cont=$(get_amnezia_container)
    if [[ -n "$cont" ]]; then
        echo -e "${GREEN}✅ $cont запущен${NC}"
    else
        echo -e "${RED}❌ Не найден / Отключен${NC}"
    fi
}

check_warp() {
    if ip link show warp &>/dev/null; then
        local rx_bytes tx_bytes
        rx_bytes=$(wg show warp transfer 2>/dev/null | grep -oP 'received \K[0-9.]+ [KMG]?i?B' || echo "0 B")
        tx_bytes=$(wg show warp transfer 2>/dev/null | grep -oP 'sent \K[0-9.]+ [KMG]?i?B' || echo "0 B")

        if curl -s --interface warp --max-time 3 https://1.1.1.1 &>/dev/null; then
            echo -e "${GREEN}✅ Активен (↓${rx_bytes} ↑${tx_bytes})${NC}"
        else
            echo -e "${YELLOW}⚠️  Поднят, но нет трафика (↓${rx_bytes} ↑${tx_bytes})${NC}"
        fi
    else
        echo -e "${RED}❌ Не активен${NC}"
    fi
}

show_warp_stats() {
    if ip link show warp &>/dev/null; then
        echo -e "\n${CYAN}--- Производительность WARP ---${NC}"
        
        local rx1 tx1 rx2 tx2
        rx1=$(cat /sys/class/net/warp/statistics/rx_bytes 2>/dev/null || echo 0)
        tx1=$(cat /sys/class/net/warp/statistics/tx_bytes 2>/dev/null || echo 0)
        sleep 0.5
        rx2=$(cat /sys/class/net/warp/statistics/rx_bytes 2>/dev/null || echo 0)
        tx2=$(cat /sys/class/net/warp/statistics/tx_bytes 2>/dev/null || echo 0)
        
        local rx_rate=$(( (rx2 - rx1) * 2 / 1024 ))
        local tx_rate=$(( (tx2 - tx1) * 2 / 1024 ))
        
        local latency
        latency=$(curl -s --interface warp --max-time 3 -w '%{time_connect}' -o /dev/null https://1.1.1.1 2>/dev/null || echo "0")
        if [[ "$latency" != "0" ]]; then
            latency=$(awk -v l="$latency" 'BEGIN {printf "%.1f", l * 1000}')
            latency="${latency} ms"
        else
            latency="N/A"
        fi
        
        local loss=0 success=0
        for i in {1..5}; do
            if curl -s --interface warp --max-time 2 https://1.1.1.1 &>/dev/null; then
                ((success++))
            else
                ((loss++))
            fi
        done
        local loss_percent=$(( loss * 20 ))

        echo -e "  Скорость:     ↓${rx_rate} KB/s  ↑${tx_rate} KB/s"
        echo -e "  Задержка:     ${latency}"
        echo -e "  Потери:       ${loss_percent}% (${success}/5 ok)"
        
        local rx_bars=$(( rx_rate / 50 ))
        local tx_bars=$(( tx_rate / 50 ))
        [[ $rx_bars -gt 20 ]] && rx_bars=20
        [[ $tx_bars -gt 20 ]] && tx_bars=20
        
        local rx_str="" tx_str=""
        [[ $rx_bars -gt 0 ]] && rx_str=$(printf '#%.0s' $(seq 1 $rx_bars))
        [[ $tx_bars -gt 0 ]] && tx_str=$(printf '#%.0s' $(seq 1 $tx_bars))
        
        printf "  ↓ [%-20s]\n" "$rx_str"
        printf "  ↑ [%-20s]\n" "$tx_str"
    fi
}

get_latest_wgcf_version() {
    local version
    version=$(curl -s --max-time 5 https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep tag_name | cut -d '"' -f4)
    echo "$version"
}

test_endpoints() {
    local endpoints=(
        "162.159.192.1:2408"
        "162.159.193.1:2408"
        "162.159.195.1:2408"
        "engage.cloudflareclient.com:2408"
        "162.159.192.7:9443"
    )
    
    local best_endpoint="162.159.192.1:2408"
    local best_latency=999.0
    
    for ep in "${endpoints[@]}"; do
        local ip port
        ip=$(echo "$ep" | cut -d: -f1)
        port=$(echo "$ep" | cut -d: -f2)
        
        if nc -z -w 1 "$ip" "$port" 2>/dev/null; then
            local lat
            lat=$(ping -c 1 -W 1 "$ip" 2>/dev/null | \
                  awk -F'time=' '/time=/ {split($2, a, " "); print a[1]}' || echo "")
            
            if [[ -n "$lat" ]]; then
                local is_better
                is_better=$(awk -v l1="$lat" -v l2="$best_latency" 'BEGIN {print (l1+0 < l2+0) ? "1" : "0"}')
                
                if [[ "$is_better" == "1" ]]; then
                    best_latency="$lat"
                    best_endpoint="$ep"
                fi
            fi
        fi
    done
    
    echo "$best_endpoint"
}

install_deps() {
    local pkgs=("wireguard-tools" "curl" "wget" "iptables" "qrencode" "netcat-openbsd")
    local to_install=()
    
    for pkg in "${pkgs[@]}"; do
        if ! dpkg -l "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        fi
    done
    
    if [[ ${#to_install[@]} -gt 0 ]]; then
        echo -e "${YELLOW}→ Установка пакетов: ${to_install[*]}...${NC}"
        apt-get update -y && apt-get install -y "${to_install[@]}" 2>/dev/null || true
    fi
    
    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}→ Установка Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
    fi
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

    install_deps

    echo -e "${YELLOW}→ Загрузка wgcf...${NC}"
    local latest_version
    latest_version=$(get_latest_wgcf_version)
    [[ -z "$latest_version" ]] && latest_version="2.2.22"
    
    wget -qO /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/${latest_version}/wgcf_${latest_version}_linux_amd64"
    chmod +x /usr/local/bin/wgcf

    mkdir -p /etc/wireguard
    cd /etc/wireguard
    rm -f wgcf-account.toml wgcf-profile.conf warp.wg.conf

    echo -e "${YELLOW}→ Регистрация профиля WARP...${NC}"
    timeout 30 wgcf register --accept-tos >/dev/null 2>&1 || true
    wgcf generate >/dev/null

    local priv endpoint warp_ip
    priv=$(grep PrivateKey wgcf-profile.conf | awk '{print $3}')
    
    echo -e "${YELLOW}→ Поиск быстрейшего эндпоинта...${NC}"
    endpoint=$(test_endpoints)
    echo -e "${GREEN}✅ Выбран эндпоинт: $endpoint${NC}"

    warp_ip=$(grep -oP 'Address\s*=\s*\K[0-9.]+' wgcf-profile.conf | head -1)
    echo "WARP_IP=${warp_ip:-172.16.0.2}" > /etc/wireguard/warp.env

    cat > /etc/wireguard/warp.wg.conf << EOF
[Interface]
PrivateKey = $priv
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
PersistentKeepalive = 25
EOF

    cat > /etc/logrotate.d/warp << 'EOF'
/var/log/warp.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0644 root root
}
EOF

    cat > /usr/local/bin/warp-healthcheck.sh << 'HEALTHCHECK'
#!/bin/bash
LOCK_FILE="/var/run/warp-healthcheck.lock"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    exit 0
fi

if ! ip link show warp &>/dev/null; then
    echo "[$(date)] WARP интерфейс не найден, рестарт..." >> /var/log/warp.log
    systemctl restart warp.service
elif ! curl -s --interface warp --max-time 3 https://1.1.1.1 &>/dev/null; then
    sleep 2
    if ! curl -s --interface warp --max-time 3 https://1.1.1.1 &>/dev/null; then
        echo "[$(date)] Потеряна связь через WARP, рестарт..." >> /var/log/warp.log
        systemctl restart warp.service
    fi
fi
HEALTHCHECK
    chmod +x /usr/local/bin/warp-healthcheck.sh

    cat > /etc/systemd/system/warp-watchdog.service << 'EOF'
[Unit]
Description=WARP Watchdog Service
After=network.target warp.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-healthcheck.sh
EOF

    cat > /etc/systemd/system/warp-watchdog.timer << 'EOF'
[Unit]
Description=WARP Watchdog Timer (every 5 min)

[Timer]
OnCalendar=*:0/5
Unit=warp-watchdog.service

[Install]
WantedBy=timers.target
EOF

    # --- Скрипт запуска (warp-up.sh) ---
    cat > /usr/local/bin/warp-up.sh << 'WARPSH'
#!/bin/bash
set -euo pipefail

readonly MARK=51820
readonly TABLE=51820
readonly WARP_CONF="/etc/wireguard/warp.wg.conf"
readonly WARP_PROFILE="/etc/wireguard/wgcf-profile.conf"
readonly LOCK_FILE="/var/run/warp-up.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/warp.log; }

validate_config() {
    local errors=0
    if [[ ! -f "$WARP_CONF" ]]; then
        log "❌ Отсутствует файл $WARP_CONF"
        ((errors++))
    else
        grep -q '\[Interface\]' "$WARP_CONF" || { log "❌ Нет [Interface]"; ((errors++)); }
        grep -q '\[Peer\]' "$WARP_CONF" || { log "❌ Нет [Peer]"; ((errors++)); }
        grep -q 'PrivateKey' "$WARP_CONF" || { log "❌ Нет PrivateKey"; ((errors++)); }
    fi
    [[ ! -f "$WARP_PROFILE" ]] && { log "❌ Отсутствует $WARP_PROFILE"; ((errors++)); }
    [[ $errors -gt 0 ]] && return 1
    return 0
}

if [[ -f /var/log/warp.log ]] && [[ $(stat -c%s /var/log/warp.log 2>/dev/null || echo 0) -gt 10485760 ]]; then
    mv /var/log/warp.log "/var/log/warp.log.$(date +%Y%m%d)"
    gzip "/var/log/warp.log.$(date +%Y%m%d)" &
fi

if [[ -f "$LOCK_FILE" ]]; then
    log "⚠️ WARP уже запускается (PID $(cat $LOCK_FILE 2>/dev/null || echo '??'))"
    exit 1
fi

echo $$ > "$LOCK_FILE"
trap 'rm -f $LOCK_FILE' EXIT

get_vpn_port() {
    local cont="$1"
    local env_port
    env_port=$(docker inspect "$cont" 2>/dev/null | grep -oP '"PORT=\K[0-9]+' | head -1)
    [[ -n "$env_port" ]] && { echo "$env_port"; return; }
    
    local ports
    ports=$(docker port "$cont" 2>/dev/null | grep -E 'udp|tcp' | awk -F ':' '{print $NF}' | sort -u)
    for p in 443 8443 35201 51820 1194 1080; do
        if echo "$ports" | grep -q "^${p}$"; then
            echo "$p"
            return
        fi
    done
    echo "$ports" | head -1
}

get_host_interface() {
    local cont_name="$1"
    local network_mode
    network_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cont_name" 2>/dev/null)
    [[ "$network_mode" == "host" ]] && { log "⚠️ Контейнер в host-сети, WARP не нужен"; exit 0; }
    
    local net_name
    net_name=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$cont_name" 2>/dev/null)
    [[ "$net_name" == "bridge" ]] && { echo "docker0"; return; }
    
    local net_id
    net_id=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$v.NetworkID}}{{end}}' "$cont_name" 2>/dev/null)
    if [[ -n "$net_id" ]]; then
        local iface
        iface=$(ip -br link | grep -E "^br-${net_id:0:12}" | awk '{print $1}')
        [[ -n "$iface" ]] && { echo "$iface"; return; }
    fi
    
    local fallback
    fallback=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{if eq $k "amnezia"}}amn0{{else}}br-{{printf "%.12s" $v.NetworkID}}{{end}}{{end}}' "$cont_name" 2>/dev/null)
    echo "${fallback:-amn0}"
}

wait_for_container() {
    local max_attempts=30 attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        local cont
        cont=$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | \
               grep -iE 'amnezia|awg|wireguard|openvpn|xray' || true | \
               grep -v 'Exited' || true | \
               awk '{print $1}' | head -n1)
        
        if [[ -n "$cont" ]]; then
            log "✅ Найден контейнер: $cont"
            echo "$cont"
            return 0
        fi
        sleep 2
        ((attempt++))
    done
    log "❌ Контейнер не найден за $max_attempts попыток"
    return 1
}

main() {
    log "=== Запуск WARP ==="
    validate_config || exit 1
    
    ip link delete warp 2>/dev/null || true
    ip link add warp type wireguard || { log "❌ Не удалось создать интерфейс warp"; exit 1; }
    
    wg setconf warp "$WARP_CONF"
    
    local warp_ip
    [[ -f /etc/wireguard/warp.env ]] && source /etc/wireguard/warp.env
    warp_ip="${WARP_IP:-172.16.0.2}"
    
    ip addr add "${warp_ip}/32" dev warp
    
    if grep -q ":" "$WARP_PROFILE" 2>/dev/null; then
        local ipv6_addr
        ipv6_addr=$(grep -oP 'Address\s*=\s*\K[0-9a-f:]+/[0-9]+' "$WARP_PROFILE" 2>/dev/null | tail -1 || true)
        [[ -n "$ipv6_addr" ]] && ip addr add "$ipv6_addr" dev warp 2>/dev/null || true
    fi

    ip link set mtu 1280 up dev warp
    
    local cont
    cont=$(wait_for_container) || exit 1
    
    local iface port
    iface=$(get_host_interface "$cont")
    port=$(get_vpn_port "$cont")
    port="${port:-35201}"
    
    log "Интерфейс: $iface, Порт: $port"
    
    while iptables -t mangle -D PREROUTING -m mark --mark "$MARK" -j RETURN 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -o warp -m mark --mark "$MARK" -j MASQUERADE 2>/dev/null; do :; done
    ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
    ip route flush table "$TABLE" 2>/dev/null || true
    
    iptables -t mangle -A PREROUTING -i "$iface" -p udp --sport "$port" -j RETURN
    iptables -t mangle -A PREROUTING -i "$iface" -j MARK --set-mark "$MARK"
    
    ip rule add fwmark "$MARK" table "$TABLE"
    ip route add default dev warp table "$TABLE"
    
    iptables -t nat -A POSTROUTING -o warp -m mark --mark "$MARK" -j MASQUERADE
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    
    if curl -s --interface warp --max-time 5 https://1.1.1.1 &>/dev/null; then
        log "✅ WARP успешно поднят!"
    else
        log "⚠️ WARP поднят, но сетевой тест провален"
    fi
}

main "$@"
WARPSH
    chmod +x /usr/local/bin/warp-up.sh

    cat > /usr/local/bin/warp-down.sh << 'WARPDOWN'
#!/bin/bash
set -euo pipefail

readonly MARK=51820
readonly TABLE=51820

ACTIVE_CONNS=$(ss -tnp state established 2>/dev/null | grep -c "warp" || echo 0)
if [[ "$ACTIVE_CONNS" -gt 0 ]]; then
    echo "⚠️  Обнаружено $ACTIVE_CONNS активных соединений через WARP"
    echo "Ожидание завершения (макс 10 сек)..."
    for i in {1..10}; do
        ACTIVE_CONNS=$(ss -tnp state established 2>/dev/null | grep -c "warp" || echo 0)
        [[ "$ACTIVE_CONNS" -eq 0 ]] && break
        sleep 1
    done
fi

while iptables -t mangle -D PREROUTING -m mark --mark "$MARK" -j RETURN 2>/dev/null; do :; done
while iptables -t nat -D POSTROUTING -o warp -m mark --mark "$MARK" -j MASQUERADE 2>/dev/null; do :; done

iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || true
ip route flush table "$TABLE" 2>/dev/null || true

sleep 0.5

ip link set warp down 2>/dev/null || true
ip link delete warp 2>/dev/null || true

echo "✅ WARP опущен."
WARPDOWN
    chmod +x /usr/local/bin/warp-down.sh

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
    systemctl enable warp.service warp-watchdog.timer
    
    echo -e "${YELLOW}→ Запуск службы WARP...${NC}"
    (systemctl start warp.service warp-watchdog.timer) &
    spinner $!

    echo -e "${GREEN}✅ WARP и Watchdog успешно запущены!${NC}"
}

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}============================================================${NC}"
        echo -e "${YELLOW}   АДМИНСКИЙ КОМБАЙН (WARP + Amnezia) — MASTER EDITION  ${NC}"
        echo -e "${CYAN}============================================================${NC}"
        echo -n "  Amnezia: "
        check_amnezia
        echo -n "  WARP:    "
        check_warp
        show_warp_stats
        echo -e "${CYAN}============================================================${NC}"
        echo -e "  ${GREEN}1.${NC} Управление WARP (поднять / опустить / статус)"
        echo -e "  ${GREEN}2.${NC} Резервное копирование и восстановление"
        echo -e "  ${GREEN}3.${NC} Полная зачистка системы от WARP"
        echo -e "  ${CYAN}D.${NC} Полная диагностика сети и логов"
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
                            echo -e "${YELLOW}→ Перезапуск WARP...${NC}"
                            (systemctl restart warp.service) &
                            spinner $!
                            echo -e "${GREEN}Готово!${NC}"
                        fi
                        ;;
                    2)
                        if [[ ! -f /usr/local/bin/warp-down.sh ]]; then
                            echo -e "${RED}❌ Утилита не установлена.${NC}"
                        else
                            echo -e "${YELLOW}→ Остановка WARP...${NC}"
                            (systemctl stop warp.service) &
                            spinner $!
                            echo -e "${GREEN}Готово!${NC}"
                        fi
                        ;;
                    3)
                        if [[ ! -f /usr/local/bin/warp-up.sh ]]; then
                            echo -e "${RED}❌ WARP не настроен.${NC}"
                        else
                            echo -n "Текущее состояние: "
                            check_warp
                            if ip link show warp &>/dev/null; then
                                wg show warp
                                echo -e "${CYAN}Внешний IP через туннель:${NC} $(curl -s --interface warp --max-time 5 ifconfig.me 2>/dev/null || echo 'не получен')"
                            fi
                        fi
                        ;;
                    *) echo "Неверный выбор." ;;
                esac
                read -p "Нажми Enter для продолжения..." _
                ;;
            2)
                echo -e "\n${CYAN}=== Резервное копирование WARP ===${NC}"
                echo "1) Создать бэкап конфигурации"
                echo "2) Восстановить из бэкапа"
                read -p "Выбери: " backup_choice
                
                case $backup_choice in
                    1)
                        BACKUP_DIR="/root/warp_backup_$(date +%Y%m%d_%H%M%S)"
                        mkdir -p "$BACKUP_DIR"
                        cp /etc/wireguard/wgcf-account.toml "$BACKUP_DIR/" 2>/dev/null || true
                        cp /etc/wireguard/wgcf-profile.conf "$BACKUP_DIR/" 2>/dev/null || true
                        cp /etc/wireguard/warp.wg.conf "$BACKUP_DIR/" 2>/dev/null || true
                        cp /etc/wireguard/warp.env "$BACKUP_DIR/" 2>/dev/null || true
                        echo -e "${GREEN}✅ Бэкап создан в: $BACKUP_DIR${NC}"
                        ;;
                    2)
                        echo "Доступные бэкапы:"
                        ls -d /root/warp_backup_* 2>/dev/null || echo "Бэкапов не найдено"
                        read -p "Введите полный путь к бэкапу: " restore_path
                        if [[ -d "$restore_path" ]]; then
                            cp "$restore_path"/* /etc/wireguard/ 2>/dev/null || true
                            echo -e "${GREEN}✅ Конфигурация восстановлена!${NC}"
                            echo -e "${YELLOW}Не забудьте перезапустить WARP (Пункт 1 -> 1)${NC}"
                        else
                            echo -e "${RED}❌ Бэкап не найден${NC}"
                        fi
                        ;;
                    *) echo "Неверный выбор." ;;
                esac
                read -p "Нажми Enter для продолжения..." _
                ;;
            3)
                echo -e "\n${RED}Выполняется полная очистка WARP...${NC}"
                systemctl stop warp-watchdog.timer 2>/dev/null || true
                systemctl disable warp-watchdog.timer 2>/dev/null || true
                systemctl stop warp.service 2>/dev/null || true
                systemctl disable warp.service 2>/dev/null || true
                /usr/local/bin/warp-down.sh 2>/dev/null || true
                rm -f /etc/systemd/system/warp.service /etc/systemd/system/warp-watchdog.* /etc/logrotate.d/warp /var/log/warp.log*
                systemctl daemon-reload
                rm -f /usr/local/bin/warp-up.sh /usr/local/bin/warp-down.sh /usr/local/bin/warp-healthcheck.sh /usr/local/bin/wgcf
                rm -rf /etc/wireguard/warp.wg.conf /etc/wireguard/warp.env
                echo -e "${GREEN}✅ Зачистка завершена!${NC}"
                read -p "Нажми Enter для продолжения..." _
                ;;
            [Dd])
                echo -e "\n${CYAN}=== Диагностика системы ===${NC}"
                echo "--- Сетевые интерфейсы ---"
                ip -br addr
                echo -e "\n--- Таблицы маршрутизации ---"
                ip rule show
                echo -e "\n--- Правила iptables (mangle/nat) ---"
                iptables -t mangle -L PREROUTING -n -v 2>/dev/null || true
                iptables -t nat -L POSTROUTING -n -v 2>/dev/null || true
                echo -e "\n--- Лог WARP (последние 10 строк) ---"
                tail -n 10 /var/log/warp.log 2>/dev/null || echo "Лог пуст или отсутствует"
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
