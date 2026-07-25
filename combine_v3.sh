#!/usr/bin/env bash
#
# warp-amnezia-combine.sh
#
# Админский комбайн: чистый WireGuard-туннель до Cloudflare WARP
# (без warp-cli — обходит все грабли с меняющимся синтаксисом CLI),
# уживается рядом с Amnezia (проверяется как отдельный Docker-контейнер).
#
# WARP поднимается с "Table = off" — интерфейс wg-warp создаётся,
# но НЕ трогает системную таблицу маршрутов и default route.
# Как использовать конкретно этот туннель (policy routing / отдельные
# приложения) — решается отдельно, скрипт только поднимает канал.
#
# Регистрация в Cloudflare выполняется автоматически (как это делает
# wgcf): генерируется локальная пара ключей WireGuard, публичный ключ
# отправляется на api.cloudflareclient.com, в ответ прилетает
# персональный адрес (172.16.0.x/32 + IPv6) — без этого шага
# сервер Cloudflare просто не узнает ваш приватный ключ и хендшейк
# не пройдёт.

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

WARP_IFACE="wg-warp"
WARP_CONF="/etc/wireguard/${WARP_IFACE}.conf"
WARP_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_ENDPOINT="162.159.192.1:2408"
# Версия API периодически меняется у Cloudflare (u wgcf это тоже
# всплывающая проблема) — если регистрация вернёт 4xx, проверьте
# актуальную версию в проекте github.com/ViRb3/wgcf.
API_VERSION="v0a884"
API_BASE="https://api.cloudflareclient.com/${API_VERSION}"

if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root (sudo bash $0)" >&2
  exit 1
fi

check_status() {
    clear
    echo "============================================================"
    echo "   АДМИНСКИЙ КОМБАЙН (WARP + Amnezia) — MASTER EDITION   "
    echo "============================================================"

    AMNEZIA_CONTAINER=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -i amnezia | head -n 1)
    if [ -n "$AMNEZIA_CONTAINER" ]; then
        echo -e "  Amnezia: ${GREEN}✅ $AMNEZIA_CONTAINER${NC}"
    else
        echo -e "  Amnezia: ${RED}❌ Не найден / Отключен${NC}"
    fi

    if ip link show "$WARP_IFACE" &>/dev/null; then
        echo -e "  WARP:    ${GREEN}🟢 Активен (${WARP_IFACE})${NC}"
    elif [ -f "$WARP_CONF" ]; then
        echo -e "  WARP:    ${YELLOW}⚠️  Установлен, но выключен${NC}"
    else
        echo -e "  WARP:    ${RED}❌ Не установлен${NC}"
    fi
    echo "============================================================"
}

register_warp() {
    # Возвращает 0 и печатает готовый конфиг-файл в WARP_CONF при успехе.
    echo "→ Генерация ключевой пары WireGuard..."
    local privkey pubkey now_ts resp

    privkey="$(wg genkey)"
    pubkey="$(echo "$privkey" | wg pubkey)"
    now_ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

    echo "→ Регистрация устройства в Cloudflare WARP..."
    resp="$(curl -fsSL -X POST "${API_BASE}/reg" \
        -H "Content-Type: application/json" \
        -H "User-Agent: okhttp/3.12.1" \
        -d "{\"key\":\"${pubkey}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"${now_ts}\",\"type\":\"Android\",\"locale\":\"en_US\"}" \
        2>/dev/null)"

    if [[ -z "$resp" ]]; then
        echo -e "${RED}Регистрация не удалась: пустой ответ от API.${NC}" >&2
        echo "Проверь сеть/доступность api.cloudflareclient.com или актуальность API_VERSION (${API_VERSION})." >&2
        return 1
    fi

    local addr_v4 addr_v6
    addr_v4="$(echo "$resp" | jq -r '.config.interface.addresses.v4 // empty')"
    addr_v6="$(echo "$resp" | jq -r '.config.interface.addresses.v6 // empty')"

    if [[ -z "$addr_v4" ]]; then
        echo -e "${RED}Регистрация вернула ответ без адреса. Ответ API:${NC}" >&2
        echo "$resp" >&2
        return 1
    fi

    mkdir -p /etc/wireguard
    cat > "$WARP_CONF" << EOF
[Interface]
PrivateKey = ${privkey}
Address = ${addr_v4}/32
$( [[ -n "$addr_v6" ]] && echo "Address = ${addr_v6}/128" )
DNS = 1.1.1.1
Table = off

[Peer]
PublicKey = ${WARP_PUBKEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${WARP_ENDPOINT}
PersistentKeepalive = 25
EOF

    chmod 600 "$WARP_CONF"
    echo -e "${GREEN}Конфиг сгенерирован и зарегистрирован: ${addr_v4}${NC}"
    return 0
}

install_warp() {
    echo "→ Установка зависимостей..."
    apt-get update -qq && apt-get install -y -qq wireguard-tools curl jq

    if [[ ! -f "$WARP_CONF" ]]; then
        if ! register_warp; then
            echo -e "${RED}❌ Установка прервана из-за ошибки регистрации.${NC}"
            read -r -p "Нажми Enter..."
            return 1
        fi
    else
        echo -e "${GREEN}Конфигурация уже существует, пропускаем регистрацию.${NC}"
    fi

    echo "→ Запуск службы WARP..."
    systemctl enable "wg-quick@${WARP_IFACE}" >/dev/null 2>&1
    systemctl restart "wg-quick@${WARP_IFACE}" >/dev/null 2>&1

    if ip link show "$WARP_IFACE" &>/dev/null; then
        echo -e "${GREEN}✓ WARP успешно поднят!${NC}"
    else
        echo -e "${RED}❌ Не удалось поднять интерфейс.${NC}"
        echo "Смотри: journalctl -u wg-quick@${WARP_IFACE} -n 30 --no-pager"
    fi
    read -r -p "Нажми Enter..."
}

down_warp() {
    systemctl stop "wg-quick@${WARP_IFACE}" >/dev/null 2>&1
    echo -e "${YELLOW}✓ WARP остановлен${NC}"
    read -r -p "Нажми Enter..."
}

purge_warp() {
    systemctl stop "wg-quick@${WARP_IFACE}" >/dev/null 2>&1
    systemctl disable "wg-quick@${WARP_IFACE}" >/dev/null 2>&1
    rm -f "$WARP_CONF"
    echo -e "${RED}✓ WARP полностью удален${NC}"
    read -r -p "Нажми Enter..."
}

while true; do
    check_status
    echo "  1. Установить / Запустить WARP"
    echo "  2. Остановить WARP"
    echo "  3. Полная зачистка WARP"
    echo "  0. Выйти"
    echo "============================================================"
    read -r -p "Твой выбор, начальник: " choice
    case "$choice" in
        1) install_warp ;;
        2) down_warp ;;
        3) purge_warp ;;
        0) exit 0 ;;
        *) echo -e "${YELLOW}Не понял выбор, попробуй ещё раз.${NC}"; sleep 1 ;;
    esac
done
