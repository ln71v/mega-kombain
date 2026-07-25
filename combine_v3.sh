#!/usr/bin/env bash
#
# setup-warp-amnezia.sh
#
# ГЛОБАЛЬНАЯ схема: весь исходящий трафик VPS заворачивается в
# Cloudflare WARP через mark-based policy routing, КРОМЕ:
#   - ответов SSH (чтобы не потерять доступ к серверу)
#   - ответов самого AmneziaWG (чтобы не сломать тоннель router↔VPS —
#     иначе роутер увидит handshake-ответы с IP Cloudflare вместо
#     реального IP VPS и попытается "роумингово" переключиться на
#     несуществующий обратный путь)
#
# Автоматическая регистрация в Cloudflare (без warp-cli), автозапуск
# через systemd (wg-quick@wg-warp enabled) — поднимается сам после
# reboot вместе со всеми PostUp-правилами.
#
# Что делает автоматически:
#   1. Ставит зависимости (wireguard-tools, curl, jq)
#   2. Регистрирует устройство в Cloudflare WARP через API,
#      получает персональный адрес (без этого хендшейк не пройдёт)
#   3. Находит контейнер Amnezia, определяет его UDP-порт (через
#      "wg show ... listen-port" внутри контейнера) и текущий порт SSH
#   4. Пишет /etc/wireguard/wg-warp.conf с Table = off и
#      PostUp/PostDown на основе fwmark: весь трафик мимо WARP,
#      кроме SSH и Amnezia
#   5. Включает net.ipv4.ip_forward постоянно
#   6. Включает и запускает wg-quick@wg-warp через systemd

set -uo pipefail

WARP_IFACE="wg-warp"
WARP_CONF="/etc/wireguard/${WARP_IFACE}.conf"
WARP_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_ENDPOINT="162.159.192.1:2408"
RT_TABLE_NUM="200"
API_VERSION="v0a884"
API_BASE="https://api.cloudflareclient.com/${API_VERSION}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "\n==> $*"; }
err() { echo -e "${RED}$*${NC}" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "Запусти от root (sudo bash $0)"
  exit 1
fi

# --- 1. Зависимости ---------------------------------------------------

log "Установка зависимостей..."
apt-get update -qq
apt-get install -y -qq wireguard-tools curl jq

# --- 2. Регистрация в Cloudflare WARP ----------------------------------

register_warp() {
  log "Генерация ключевой пары WireGuard..."
  local privkey pubkey now_ts resp addr_v4 addr_v6

  privkey="$(wg genkey)"
  pubkey="$(echo "$privkey" | wg pubkey)"
  now_ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

  log "Регистрация устройства в Cloudflare WARP..."
  resp="$(curl -fsSL -X POST "${API_BASE}/reg" \
      -H "Content-Type: application/json" \
      -H "User-Agent: okhttp/3.12.1" \
      -d "{\"key\":\"${pubkey}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"${now_ts}\",\"type\":\"Android\",\"locale\":\"en_US\"}" \
      2>/dev/null)"

  if [[ -z "$resp" ]]; then
    err "Регистрация не удалась: пустой ответ от API."
    err "Проверьте сеть или актуальность API_VERSION (${API_VERSION}) — см. github.com/ViRb3/wgcf."
    return 1
  fi

  addr_v4="$(echo "$resp" | jq -r '.config.interface.addresses.v4 // empty')"
  addr_v6="$(echo "$resp" | jq -r '.config.interface.addresses.v6 // empty')"

  if [[ -z "$addr_v4" ]]; then
    err "Регистрация вернула ответ без адреса. Ответ API:"
    echo "$resp" >&2
    return 1
  fi

  echo "${privkey}|${addr_v4}|${addr_v6}"
  return 0
}

if [[ -f "$WARP_CONF" ]]; then
  log "Конфиг ${WARP_CONF} уже существует — регистрацию пропускаем, только обновим routing-хуки."
  PRIVKEY="$(grep -oP '(?<=PrivateKey = ).*' "$WARP_CONF" | head -n1)"
  ADDR_V4="$(grep -oP '(?<=Address = ).*(?=/32)' "$WARP_CONF" | head -n1)"
  ADDR_V6="$(grep -oP '(?<=Address = ).*(?=/128)' "$WARP_CONF" | head -n1)"
else
  REG_RESULT="$(register_warp)" || exit 1
  PRIVKEY="$(echo "$REG_RESULT" | cut -d'|' -f1)"
  ADDR_V4="$(echo "$REG_RESULT" | cut -d'|' -f2)"
  ADDR_V6="$(echo "$REG_RESULT" | cut -d'|' -f3)"
  log "Зарегистрировано: ${ADDR_V4}"
fi

# --- 3. Определение критичных портов, которые НЕЛЬЗЯ заворачивать в WARP -

log "Поиск контейнера Amnezia..."
AMNEZIA_CID="$(docker ps --format '{{.ID}}\t{{.Names}}' 2>/dev/null | grep -i amnezia | head -n1 | awk '{print $1}')"

if [[ -z "$AMNEZIA_CID" ]]; then
  err "Контейнер Amnezia не найден через 'docker ps'. Запустите его сначала."
  exit 1
fi

log "Контейнер: ${AMNEZIA_CID}"

# Впишите вручную, если автоопределение не сработает.
MANUAL_AMNEZIA_PORT=""
MANUAL_SSH_PORT=""

detect_amnezia_port() {
  if [[ -n "$MANUAL_AMNEZIA_PORT" ]]; then
    echo "$MANUAL_AMNEZIA_PORT"
    return 0
  fi

  local iface port
  # Самый надёжный способ — спросить у самого wg внутри контейнера,
  # на каком порту слушает интерфейс.
  iface="$(docker exec "$AMNEZIA_CID" wg show interfaces 2>/dev/null | awk '{print $1}' | head -n1)"
  if [[ -n "$iface" ]]; then
    port="$(docker exec "$AMNEZIA_CID" wg show "$iface" listen-port 2>/dev/null)"
  fi

  if [[ -z "$port" ]]; then
    # Фолбэк: опубликованный docker-порт (актуально в bridge-режиме)
    port="$(docker port "$AMNEZIA_CID" 2>/dev/null | grep -oP '^\d+(?=/udp)' | head -n1)"
  fi

  echo "$port"
}

detect_ssh_port() {
  if [[ -n "$MANUAL_SSH_PORT" ]]; then
    echo "$MANUAL_SSH_PORT"
    return 0
  fi
  local port
  port="$(grep -iE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1)"
  echo "${port:-22}"
}

AMNEZIA_PORT="$(detect_amnezia_port)"
SSH_PORT="$(detect_ssh_port)"

if [[ -z "$AMNEZIA_PORT" ]]; then
  err "Не удалось автоматически определить UDP-порт AmneziaWG."
  err "Впишите его в переменную MANUAL_AMNEZIA_PORT в начале скрипта и перезапустите."
  err "Проверить руками: docker exec ${AMNEZIA_CID} wg show"
  exit 1
fi

log "Обнаружено: SSH порт = ${SSH_PORT}, AmneziaWG порт (UDP) = ${AMNEZIA_PORT}"
echo -e "${YELLOW}ВАЖНО: это глобальная схема — ВЕСЬ остальной трафик VPS пойдёт через WARP,"
echo -e "кроме ответов SSH (tcp/${SSH_PORT}) и ответов самого AmneziaWG (udp/${AMNEZIA_PORT}).${NC}"
read -r -p "Порты верны? Продолжить и записать конфиг wg-warp? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Отменено пользователем. Поправьте MANUAL_SSH_PORT / MANUAL_AMNEZIA_PORT и запустите снова."
  exit 0
fi

# --- 4. Запись конфига с policy routing в PostUp/PostDown --------------

log "Запись ${WARP_CONF}..."
mkdir -p /etc/wireguard

{
  echo "[Interface]"
  echo "PrivateKey = ${PRIVKEY}"
  echo "Address = ${ADDR_V4}/32"
  [[ -n "${ADDR_V6:-}" ]] && echo "Address = ${ADDR_V6}/128"
  # MTU 1280 — официальная рекомендация Cloudflare/wgcf для WARP.
  # Без явного MTU wg-quick ставит ~1420, а на многих сетях крупные
  # пакеты в туннель до Cloudflare молча теряются (ICMP "Fragmentation
  # Needed" по пути фильтруется) — маленькие пакеты (хендшейк, curl)
  # при этом проходят нормально, что маскирует проблему на первый взгляд.
  echo "MTU = 1280"
  # Table = off остаётся: без него wg-quick сам пропишет свой default
  # route в main-таблицу, и тот будет конфликтовать с нашим ручным
  # исключением SSH/Amnezia через "table main" ниже. Разруливаем
  # маршрутизацию полностью вручную через fwmark.
  echo "Table = off"
  echo ""
  echo "# --- глобальная схема: всё через WARP, кроме SSH и самого Amnezia ---"
  echo "PostUp = ip route replace default dev ${WARP_IFACE} table ${RT_TABLE_NUM}"
  echo "PostUp = ip rule add ipproto tcp sport ${SSH_PORT} table main priority 50 || true"
  echo "PostUp = ip rule add ipproto udp sport ${AMNEZIA_PORT} table main priority 51 || true"
  echo "PostUp = ip rule add fwmark 1 table ${RT_TABLE_NUM} priority 100 || true"
  echo "PostUp = iptables -t mangle -A OUTPUT -j MARK --set-mark 1"
  echo "PostUp = iptables -t mangle -A OUTPUT -p tcp --sport ${SSH_PORT} -j MARK --set-mark 0"
  echo "PostUp = iptables -t mangle -A OUTPUT -p udp --sport ${AMNEZIA_PORT} -j MARK --set-mark 0"
  echo "PostUp = iptables -t nat -A POSTROUTING -o ${WARP_IFACE} -j MASQUERADE"
  echo ""
  echo "PostDown = iptables -t nat -D POSTROUTING -o ${WARP_IFACE} -j MASQUERADE || true"
  echo "PostDown = iptables -t mangle -D OUTPUT -p udp --sport ${AMNEZIA_PORT} -j MARK --set-mark 0 || true"
  echo "PostDown = iptables -t mangle -D OUTPUT -p tcp --sport ${SSH_PORT} -j MARK --set-mark 0 || true"
  echo "PostDown = iptables -t mangle -D OUTPUT -j MARK --set-mark 1 || true"
  echo "PostDown = ip rule del fwmark 1 table ${RT_TABLE_NUM} priority 100 || true"
  echo "PostDown = ip rule del ipproto udp sport ${AMNEZIA_PORT} table main priority 51 || true"
  echo "PostDown = ip rule del ipproto tcp sport ${SSH_PORT} table main priority 50 || true"
  echo "PostDown = ip route flush table ${RT_TABLE_NUM} || true"
  echo ""
  echo "[Peer]"
  echo "PublicKey = ${WARP_PUBKEY}"
  echo "AllowedIPs = 0.0.0.0/0"
  echo "Endpoint = ${WARP_ENDPOINT}"
  echo "PersistentKeepalive = 25"
} > "$WARP_CONF"

chmod 600 "$WARP_CONF"

# --- 5. ip_forward постоянно -------------------------------------------

log "Проверка net.ipv4.ip_forward..."
if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
fi
if grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null; then
  sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

# --- 6. Автозапуск через systemd ---------------------------------------

log "Включение автозапуска и старт wg-quick@${WARP_IFACE}..."
systemctl enable "wg-quick@${WARP_IFACE}" >/dev/null 2>&1
systemctl restart "wg-quick@${WARP_IFACE}"

sleep 2

if ip link show "$WARP_IFACE" &>/dev/null; then
  echo -e "${GREEN}✓ WARP поднят и добавлен в автозапуск (systemctl enable уже сделан).${NC}"
else
  err "❌ Интерфейс не поднялся. Смотрите: journalctl -u wg-quick@${WARP_IFACE} -n 30 --no-pager"
  exit 1
fi

cat <<EOF

Готово. При перезагрузке сервера ${WARP_IFACE} поднимется сам вместе
со всеми PostUp-правилами (systemd unit уже enabled).

Это ГЛОБАЛЬНАЯ схема: весь исходящий трафик VPS теперь идёт через
WARP, кроме ответов SSH (tcp/${SSH_PORT}) и ответов самого AmneziaWG
(udp/${AMNEZIA_PORT}).

Проверка внешнего IP самого сервера:
  curl https://2ip.ru
  curl https://www.cloudflare.com/cdn-cgi/trace/   # ищите "warp=on"

Проверка, что SSH и Amnezia не сломались — переподключитесь заново
(в отдельном окне, не закрывая текущую сессию) и убедитесь, что
клиенты Amnezia по-прежнему видят интернет.

Проверка хендшейка WARP на самом VPS:
  wg show ${WARP_IFACE}

Если порт SSH или Amnezia изменится — впишите новое значение в
MANUAL_SSH_PORT / MANUAL_AMNEZIA_PORT и запустите скрипт ещё раз.
EOF
