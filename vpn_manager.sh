#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Проверка sudo прав
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        print_warning "Для настройки VPN нужны права sudo"
    fi
}

# Проверка интернет-соединения
check_internet() {
    if ! curl -s --max-time 5 google.com > /dev/null; then
        print_error "Нет интернет-соединения"
        return 1
    fi
}

# Установка sing-box (если не установлен)
install_sing_box() {
    if command -v sing-box &> /dev/null; then
        print_status "sing-box уже установлен: $(which sing-box)"
        return 0
    fi
    
    print_status "Установка sing-box..."
    
    # Проверяем интернет
    check_internet || return 1
    
    # Определяем архитектуру
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) print_error "Неподдерживаемая архитектура: $ARCH"; return 1 ;;
    esac
    
    # Получаем последнюю версию
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    
    if [ -z "$VERSION" ]; then
        VERSION="v1.8.0"
    fi
    
    print_status "Скачивание sing-box версии $VERSION..."
    
    # Скачиваем и устанавливаем
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${ARCH}.tar.gz"
    
    if ! wget -O sing-box.tar.gz "$DOWNLOAD_URL"; then
        print_error "Ошибка скачивания sing-box"
        return 1
    fi
    
    tar -xzf sing-box.tar.gz
    
    # Находим и устанавливаем исполняемый файл
    SING_BOX_BINARY=$(find . -name "sing-box" -type f -executable | head -1)
    if [ -z "$SING_BOX_BINARY" ]; then
        print_error "Исполняемый файл sing-box не найден"
        return 1
    fi
    
    sudo cp "$SING_BOX_BINARY" /usr/local/bin/sing-box
    sudo chmod +x /usr/local/bin/sing-box
    
    # Очищаем временные файлы
    rm -rf sing-box*
    
    print_success "sing-box установлен"
}

# Парсинг VLESS URL
parse_vless_url() {
    local url="$1"
    
    if [[ ! "$url" =~ ^vless:// ]]; then
        print_error "Некорректный VLESS URL"
        return 1
    fi
    
    # Убираем префикс vless://
    url=${url#vless://}
    
    # Разделяем на компоненты
    IFS='@' read -r uuid_part server_part <<< "$url"
    IFS='?' read -r server_port params <<< "$server_part"
    IFS=':' read -r server port <<< "$server_port"
    
    # Убираем фрагмент из параметров
    params=${params%%#*}
    
    # Парсим параметры
    declare -A param_map
    IFS='&' read -ra PARAMS <<< "$params"
    for param in "${PARAMS[@]}"; do
        IFS='=' read -r key value <<< "$param"
        param_map[$key]="$value"
    done
    
    # Экспортируем переменные
    export VLESS_SERVER="$server"
    export VLESS_PORT="$port"
    export VLESS_UUID="$uuid_part"
    export VLESS_SECURITY="${param_map[security]:-none}"
    export VLESS_SNI="${param_map[sni]}"
    export VLESS_PBK="${param_map[pbk]}"
    export VLESS_SID="${param_map[sid]}"
    export VLESS_FP="${param_map[fp]:-chrome}"
    
    print_status "Сервер: $VLESS_SERVER:$VLESS_PORT"
    print_status "UUID: $VLESS_UUID"
    print_status "SNI: $VLESS_SNI"
}

# Создание конфигурации
create_config() {
    print_status "Создание конфигурации sing-box..."
    
    mkdir -p ~/.config/sing-box
    
    # Создаем JSON конфигурацию
    cat > ~/.config/sing-box/config.json << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 1080
    },
    {
      "type": "http",
      "tag": "http-in",
      "listen": "127.0.0.1",
      "listen_port": 8080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "${VLESS_SERVER}",
      "server_port": ${VLESS_PORT},
      "uuid": "${VLESS_UUID}",
      "tls": {
        "enabled": true,
        "server_name": "${VLESS_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "${VLESS_FP}"
        },
        "reality": {
          "enabled": true,
          "public_key": "${VLESS_PBK}",
          "short_id": "${VLESS_SID}"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "domain_suffix": ["localhost"],
        "outbound": "direct"
      },
      {
        "ip_cidr": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "${VLESS_SERVER}/32"
        ],
        "outbound": "direct"
      }
    ],
    "final": "vless-out"
  }
}
EOF

    print_success "Конфигурация создана"
}

# Создание systemd сервиса
create_service() {
    local sing_box_path=$(which sing-box)
    
    print_status "Создание systemd сервиса..."
    
    sudo tee /etc/systemd/system/sing-box.service > /dev/null << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$sing_box_path run -c $HOME/.config/sing-box/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable sing-box
    
    print_success "Systemd сервис создан"
}

# Функции управления VPN
start_vpn() {
    print_status "Запуск VPN..."
    
    if ! sudo systemctl start sing-box; then
        print_error "Ошибка запуска VPN"
        return 1
    fi
    
    sleep 3
    
    if sudo systemctl is-active --quiet sing-box; then
        print_success "VPN запущен"
        print_status "SOCKS5 прокси: 127.0.0.1:1080"
        print_status "HTTP прокси: 127.0.0.1:8080"
    else
        print_error "VPN не запустился"
        sudo journalctl -u sing-box --no-pager -n 10
        return 1
    fi
}

stop_vpn() {
    print_status "Остановка VPN..."
    sudo systemctl stop sing-box
    print_success "VPN остановлен"
}

restart_vpn() {
    print_status "Перезапуск VPN..."
    sudo systemctl restart sing-box
    sleep 3
    
    if sudo systemctl is-active --quiet sing-box; then
        print_success "VPN перезапущен"
    else
        print_error "Ошибка перезапуска VPN"
        sudo journalctl -u sing-box --no-pager -n 10
        return 1
    fi
}

# Проверка статуса VPN
status_vpn() {
    echo -e "${BLUE}=== Статус VPN ===${NC}"
    
    if sudo systemctl is-active --quiet sing-box; then
        print_success "VPN активен"
        echo -e "${BLUE}Прокси адреса:${NC}"
        echo "  SOCKS5: 127.0.0.1:1080"
        echo "  HTTP: 127.0.0.1:8080"
    else
        print_error "VPN неактивен"
    fi
    
    echo ""
    echo -e "${BLUE}Systemd статус:${NC}"
    sudo systemctl status sing-box --no-pager -l
}

# Тест соединения
test_connection() {
    print_status "Тестирование соединения..."
    
    echo -e "${BLUE}Прямое соединение (без VPN):${NC}"
    DIRECT_IP=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "IP: $DIRECT_IP"
    
    echo -e "${BLUE}Через SOCKS5 прокси:${NC}"
    SOCKS_IP=$(curl -s --max-time 10 --proxy socks5://127.0.0.1:1080 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "IP: $SOCKS_IP"
    
    echo -e "${BLUE}Через HTTP прокси:${NC}"
    HTTP_IP=$(curl -s --max-time 10 --proxy http://127.0.0.1:8080 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "IP: $HTTP_IP"
    
    echo ""
    if [ "$SOCKS_IP" != "ошибка" ] && [ "$SOCKS_IP" != "$DIRECT_IP" ]; then
        print_success "✅ SOCKS5 прокси работает!"
    else
        print_warning "⚠️ Проблема с SOCKS5 прокси"
    fi
    
    if [ "$HTTP_IP" != "ошибка" ] && [ "$HTTP_IP" != "$DIRECT_IP" ]; then
        print_success "✅ HTTP прокси работает!"
    else
        print_warning "⚠️ Проблема с HTTP прокси"
    fi
    
    echo ""
    echo -e "${BLUE}Использование:${NC}"
    echo "  curl ifconfig.me                                    # прямое соединение"
    echo "  curl --proxy socks5://127.0.0.1:1080 ifconfig.me   # через SOCKS5"
    echo "  curl --proxy http://127.0.0.1:8080 ifconfig.me     # через HTTP"
}

# Просмотр логов
show_logs() {
    echo -e "${BLUE}=== Логи VPN (последние 20 строк) ===${NC}"
    sudo journalctl -u sing-box --no-pager -n 20
    echo ""
    echo -e "${BLUE}Для просмотра логов в реальном времени:${NC}"
    echo "sudo journalctl -u sing-box -f"
}

# Функция установки с URL
install_with_url() {
    local vless_url="$1"
    
    if [ -z "$vless_url" ]; then
        print_error "Не указан VLESS URL"
        echo "Использование: $0 install <vless://url>"
        return 1
    fi
    
    echo -e "${GREEN}=================================================="
    echo "         Установка VLESS VPN (sing-box)"
    echo "==================================================${NC}"
    
    # Установка зависимостей
    if command -v apt &> /dev/null; then
        sudo apt update && sudo apt install -y curl wget
    fi
    
    # Проверяем и устанавливаем sing-box
    install_sing_box || return 1
    
    # Парсим URL и создаем конфигурацию
    parse_vless_url "$vless_url" || return 1
    create_config || return 1
    
    # Проверяем конфигурацию
    if ! sing-box check -c ~/.config/sing-box/config.json; then
        print_error "Ошибка в конфигурации"
        return 1
    fi
    
    print_success "Конфигурация корректна"
    
    # Создаем сервис
    create_service || return 1
    
    echo ""
    print_success "🎉 VPN успешно установлен!"
    echo ""
    echo -e "${BLUE}Управление VPN:${NC}"
    echo "  $0 start          # запустить VPN"
    echo "  $0 stop           # остановить VPN"
    echo "  $0 restart        # перезапустить VPN"
    echo "  $0 status         # показать статус"
    echo "  $0 test           # тест соединения"
    echo "  $0 logs           # показать логи"
    echo ""
    echo -e "${BLUE}Использование прокси:${NC}"
    echo "  curl --proxy socks5://127.0.0.1:1080 ifconfig.me"
    echo "  curl --proxy http://127.0.0.1:8080 ifconfig.me"
    echo ""
    echo -e "${YELLOW}Для запуска VPN выполните: $0 start${NC}"
}

# Главная функция
main() {
    check_sudo
    
    case "${1:-help}" in
        install)
            install_with_url "$2"
            ;;
        start)
            start_vpn
            ;;
        stop)
            stop_vpn
            ;;
        restart)
            restart_vpn
            ;;
        status)
            status_vpn
            ;;
        test)
            test_connection
            ;;
        logs)
            show_logs
            ;;
        help|*)
            echo -e "${GREEN}🚀 VPN Manager для sing-box${NC}"
            echo ""
            echo "Использование: $0 <команда> [параметры]"
            echo ""
            echo -e "${BLUE}Команды:${NC}"
            echo "  install <vless://url>  # установить VPN"
            echo "  start                  # запустить VPN"
            echo "  stop                   # остановить VPN"
            echo "  restart                # перезапустить VPN"
            echo "  status                 # показать статус VPN"
            echo "  test                   # тест соединения"
            echo "  logs                   # показать логи"
            echo "  help                   # показать эту справку"
            echo ""
            echo -e "${YELLOW}Примеры:${NC}"
            echo "  $0 install 'vless://uuid@server:port?params'"
            echo "  $0 start"
            echo "  $0 test"
            echo "  $0 stop"
            echo ""
            echo -e "${BLUE}Использование прокси:${NC}"
            echo "  curl ifconfig.me                                    # прямое соединение"
            echo "  curl --proxy socks5://127.0.0.1:1080 ifconfig.me   # через SOCKS5"
            echo "  curl --proxy http://127.0.0.1:8080 ifconfig.me     # через HTTP"
            echo ""
            echo -e "${BLUE}Для удобства можно создать alias:${NC}"
            echo "  alias curl-vpn='curl --proxy http://127.0.0.1:8080'"
            echo "  curl-vpn ifconfig.me"
            ;;
    esac
}

# Запуск
main "$@"