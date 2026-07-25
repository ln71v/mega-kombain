#!/usr/bin/env bash
#
# route-amnezia-via-warp.sh
#
# Заворачивает трафик от клиентов AmneziaWG в туннель wg-warp
# (WireGuard до Cloudflare WARP), так что внешние сайты видят
# IP Cloudflare вместо реального IP VPS.
#
# ЧТО ОСТАЁТСЯ БЕЗ ИЗМЕНЕНИЙ:
#   - основной default route хоста (SSH и весь трафик самого
#     сервера продолжают идти как раньше — иначе легко потерять
#     доступ по SSH)
#   - AmneziaWG как таковой не трогается
#
# ЧТО ДЕЛАЕТ СКРИПТ:
#   1. Находит Amnezia-контейнер и определяет режим сети (host/bridge)
#   2. Определяет исходную подсеть VPN-клиентов Amnezia
#   3. Создаёт отдельную таблицу маршрутизации с default route
#      через wg-warp
#   4. Добавляет ip rule: только пакеты ИЗ этой подсети идут по
#      отдельной таблице (весь остальной трафик хоста не затронут)
#   5. Добавляет MASQUERADE на wg-warp для этой подсети
#
# ВАЖНО: если автоопределение подсети ошибётся — поправьте
# переменную MANUAL_SUBNET ниже и перезапустите скрипт.

set -uo pipefail

WARP_IFACE="wg-warp"
RT_TABLE_NUM="200"
RT_TABLE_NAME="warp-out"

# Если знаете подсеть клиентов Amnezia точно — впишите сюда,
# например "10.8.0.0/24", и автоопределение будет пропущено.
MANUAL_SUBNET=""

if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root (sudo bash $0)" >&2
  exit 1
fi

if ! ip link show "$WARP_IFACE" &>/dev/null; then
  echo "Интерфейс ${WARP_IFACE} не найден. Сначала поднимите WARP." >&2
  exit 1
fi

echo "→ Поиск контейнера Amnezia..."
AMNEZIA_CID="$(docker ps --format '{{.ID}}\t{{.Names}}' 2>/dev/null | grep -i amnezia | head -n1 | awk '{print $1}')"

if [[ -z "$AMNEZIA_CID" ]]; then
  echo "Контейнер Amnezia не найден через 'docker ps'. Запустите сначала его." >&2
  exit 1
fi

echo "→ Найден контейнер: ${AMNEZIA_CID}"

NETWORK_MODE="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$AMNEZIA_CID")"
echo "→ Режим сети контейнера: ${NETWORK_MODE}"

detect_subnet() {
  if [[ -n "$MANUAL_SUBNET" ]]; then
    echo "$MANUAL_SUBNET"
    return 0
  fi

  if [[ "$NETWORK_MODE" == "host" ]]; then
    # В host-режиме подсеть VPN-клиентов определяется внутри
    # самого контейнера — смотрим на его WireGuard-интерфейс(ы).
    local subnet
    subnet="$(docker exec "$AMNEZIA_CID" sh -c "ip -4 addr show 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}'" \
      | grep -vE '^(127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[0-1]\.)' \
      | head -n1)"
    if [[ -n "$subnet" ]]; then
      # Приводим конкретный IP-адрес интерфейса к подсети /24
      # (обычно так и раздаёт Amnezia клиентам)
      echo "$subnet" | awk -F. '{split($0,a,"."); print a[1]"."a[2]"."a[3]".0/24"}' \
        | sed 's#/24/[0-9]*#/24#'
    fi
  else
    # Bridge/NAT: берём подсеть docker-сети, к которой подключен контейнер
    docker inspect --format '{{range $net,$conf := .NetworkSettings.Networks}}{{$conf.IPAMConfig}}{{end}}' "$AMNEZIA_CID" >/dev/null 2>&1
    local netname subnet
    netname="$(docker inspect --format '{{range $net,$conf := .NetworkSettings.Networks}}{{$net}}{{end}}' "$AMNEZIA_CID" | head -n1)"
    subnet="$(docker network inspect "$netname" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)"
    echo "$subnet"
  fi
}

SUBNET="$(detect_subnet)"

if [[ -z "$SUBNET" ]]; then
  echo -e "\nНе удалось автоматически определить подсеть клиентов Amnezia." >&2
  echo "Впишите её вручную в переменную MANUAL_SUBNET в начале скрипта и перезапустите." >&2
  echo "Проверить руками можно так:" >&2
  echo "  docker exec ${AMNEZIA_CID} ip addr        # если host network" >&2
  echo "  docker network inspect <имя_сети>          # если bridge" >&2
  exit 1
fi

echo -e "\n→ Определена подсеть клиентов Amnezia: ${SUBNET}"
read -r -p "Верно? Продолжить настройку policy routing через ${WARP_IFACE}? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Отменено пользователем."
  exit 0
fi

echo "→ Настройка отдельной таблицы маршрутизации (${RT_TABLE_NAME}, ${RT_TABLE_NUM})"
if ! grep -q "^${RT_TABLE_NUM}[[:space:]]\+${RT_TABLE_NAME}$" /etc/iproute2/rt_tables 2>/dev/null; then
  echo "${RT_TABLE_NUM} ${RT_TABLE_NAME}" >> /etc/iproute2/rt_tables
fi

# default route в отдельной таблице — только через wg-warp
ip route replace default dev "$WARP_IFACE" table "$RT_TABLE_NAME"

# правило: пакеты с исходным адресом из подсети Amnezia идут по этой таблице
# (остальной трафик хоста, включая SSH, таблицу не затрагивает)
if ! ip rule show | grep -q "from ${SUBNET} lookup ${RT_TABLE_NAME}"; then
  ip rule add from "$SUBNET" table "$RT_TABLE_NAME" priority 100
fi

echo "→ Настройка MASQUERADE на ${WARP_IFACE} для подсети ${SUBNET}"
if ! iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$WARP_IFACE" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$WARP_IFACE" -j MASQUERADE
fi

# ip_forward должен быть включен, иначе пересылка пакетов не работает вообще
if [[ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]]; then
  echo "→ Включение net.ipv4.ip_forward"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf \
    && sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf \
    || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

cat <<EOF

Готово.

Трафик из подсети ${SUBNET} (клиенты Amnezia) теперь маршрутизируется
через ${WARP_IFACE} и выходит наружу под IP Cloudflare.
SSH и весь остальной трафик хоста продолжают идти через обычный default route.

Проверка с клиента, подключённого к Amnezia:
  curl https://2ip.ru
  # или
  curl https://www.cloudflare.com/cdn-cgi/trace/   # ищите "warp=on"

Это правило не переживёт перезагрузку сервера — если нужно, чтобы оно
применялось автоматически при старте, скажите, добавлю systemd unit
или строку в rc.local / netplan post-up.
EOF
