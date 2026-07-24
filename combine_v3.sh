#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_status() {
    clear
    echo "============================================================"
    echo "   АДМИНСКИЙ КОМБАЙН (WARP + Amnezia) — MASTER EDITION   "
    echo "============================================================"
    
    # Проверка Amnezia
    AMNEZIA_CONTAINER=$(docker ps --format "{{.Names}}\t{{.Status}}" 2>/dev/null | grep -i amnezia | head -n 1)
    if [ -n "$AMNEZIA_CONTAINER" ]; then
        echo -e "  Amnezia: ${GREEN}✅ $AMNEZIA_CONTAINER${NC}"
    else
        echo -e "  Amnezia: ${RED}❌ Не найден / Отключен${NC}"
    fi

    # Проверка WARP
    if ip link show wg-warp &>/dev/null; then
        echo -e "  WARP:    ${GREEN}🟢 Активен и работает (wg-warp)${NC}"
    elif [ -f /etc/wireguard/wg-warp.conf ]; then
        echo -e "  WARP:    ${YELLOW}⚠️  Установлен, но выключен${NC}"
    else
        echo -e "  WARP:    ${RED}❌ Не установлен${NC}"
    fi
    echo "============================================================"
}

install_warp() {
    echo "→ Установка и настройка WARP..."
    apt-get update -qq && apt-get install -y -qq wireguard-tools qrencode wget curl

    # Скачивание wgcf
    if [ ! -f /usr/local/bin/wgcf ]; then
        echo "→ Загрузка wgcf (v2.2.22)..."
        wget -q --show-progress -O /usr/local/bin/wgcf https://github.com/ViRb38/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64
        chmod +x /usr/local/bin/wgcf
    fi

    mkdir -p /etc/wireguard/warp
    cd /etc/wireguard/warp

    if [ ! -f wgcf-account.toml ]; then
        echo "→ Регистрация аккаунта WARP..."
        yes | /usr/local/bin/wgcf register --accept-tos
        sleep 2
    fi

    if [ ! -f wgcf-profile.conf ]; then
        echo "→ Генерация конфига WARP..."
        /usr/local/bin/wgcf generate
    fi

    if [ ! -f wgcf-profile.conf ]; then
        echo -e "${RED}❌ Ошибка генерации профиля. Cloudflare заблокировал запрос.${NC}"
        read -p "Нажми Enter для продолжения..."
        return
    fi

    # Подготовка WG интерфейса
    cp wgcf-profile.conf /etc/wireguard/wg-warp.conf
    sed -i 's/Table = auto/Table = off/g' /etc/wireguard/wg-warp.conf 2>/dev/null || true

    echo "→ Включение автозагрузки и запуск wg-warp..."
    systemctl enable wg-quick@wg-warp 2>/dev/null
    systemctl restart wg-quick@wg-warp

    if ip link show wg-warp &>/dev/null; then
        echo -e "${GREEN}✓ WARP успешно поднят!${NC}"
    else
        echo -e "${RED}❌ Ошибка запуска. Интерфейс не поднялся.${NC}"
    fi
    read -p "Нажми Enter для продолжения..."
}

down_warp() {
    echo "→ Остановка WARP..."
    systemctl stop wg-quick@wg-warp 2>/dev/null || true
    echo -e "${YELLOW}✓ WARP остановлен${NC}"
    read -p "Нажми Enter для продолжения..."
}

purge_warp() {
    echo "→ Полная очистка WARP..."
    systemctl stop wg-quick@wg-warp 2>/dev/null || true
    systemctl disable wg-quick@wg-warp 2>/dev/null || true
    rm -rf /etc/wireguard/wg-warp.conf /etc/wireguard/warp /usr/local/bin/wgcf
    echo -e "${GREEN}✓ WARP полностью удален${NC}"
    read -p "Нажми Enter для продолжения..."
}

diagnostics() {
    echo "=== Диагностика системы ==="
    echo "--- Сетевые интерфейсы ---"
    ip -brief address
    echo -e "\n--- Таблицы маршрутизации ---"
    ip rule show
    echo -e "\n--- Лог службы WARP ---"
    systemctl status wg-quick@wg-warp --no-pager || echo "Служба не найдена"
    read -p "Нажми Enter для продолжения..."
}

while true; do
    check_status
    echo "  1. Управление WARP (поднять / опустить / статус)"
    echo "  2. Резервное копирование и восстановление"
    echo "  3. Полная зачистка системы от WARP"
    echo "  D. Полная диагностика сети и логов"
    echo "  0. Выйти"
    echo "============================================================"
    read -p "Твой выбор, начальник: " choice

    case $choice in
        1)
            echo -e "\n--- Управление WARP ---"
            echo "1) Поднять / Установить WARP"
            echo "2) Насильно опустить WARP"
            echo "3) Проверить статус"
            read -p "Выбери подпункт: " subchoice
            case $subchoice in
                1) install_warp ;;
                2) down_warp ;;
                3) systemctl status wg-quick@wg-warp --no-pager; wg show wg-warp 2>/dev/null; read -p "Нажми Enter..." ;;
            esac
            ;;
        3) purge_warp ;;
        D|d) diagnostics ;;
        0) exit 0 ;;
    esac
done
