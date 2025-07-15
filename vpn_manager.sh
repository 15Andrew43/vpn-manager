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

# Установка sing-box (если не установлен)
install_sing_box() {
    if command -v sing-box &> /dev/null; then
        print_status "sing-box уже установлен: $(which sing-box)"
        return 0
    fi
    
    print_status "Установка sing-box..."
    
    # Определяем архитектуру
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) print_error "Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
    esac
    
    # Получаем последнюю версию
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    
    if [ -z "$VERSION" ]; then
        VERSION="v1.8.0"
    fi
    
    print_status "Скачивание sing-box версии $VERSION..."
    
    # Скачиваем и устанавливаем
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${ARCH}.tar.gz"
    wget -O sing-box.tar.gz "$DOWNLOAD_URL"
    tar -xzf sing-box.tar.gz
    
    # Находим и устанавливаем исполняемый файл
    SING_BOX_BINARY=$(find . -name "sing-box" -type f -executable | head -1)
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
        exit 1
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

# Создание конфигурации для глобального VPN
create_global_config() {
    print_status "Создание конфигурации для глобального VPN..."
    
    mkdir -p ~/.config/sing-box
    
    # Создаем JSON файл с правильной подстановкой переменных
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
      "listen": "0.0.0.0",
      "listen_port": 1080
    },
    {
      "type": "http",
      "tag": "http-in",
      "listen": "0.0.0.0",
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

# Создание простой конфигурации (SOCKS5 + HTTP)
create_simple_config() {
    print_status "Создание простой конфигурации (SOCKS5 + HTTP)..."
    
    mkdir -p ~/.config/sing-box
    
    # Создаем JSON файл с правильной подстановкой переменных
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
    }
  ],
  "route": {
    "final": "vless-out"
  }
}
EOF

    print_success "Простая конфигурация создана"
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

# Настройка глобального прокси через переменные окружения
setup_global_proxy() {
    print_status "Настройка глобального прокси..."
    
    # Полностью удаляем старые настройки прокси из bashrc
    sed -i '/# VPN Global Proxy Settings/,+8d' ~/.bashrc 2>/dev/null || true
    sed -i '/# VPN Simple Mode Settings/,+8d' ~/.bashrc 2>/dev/null || true
    sed -i '/alias curl=/d' ~/.bashrc 2>/dev/null || true
    
    # Добавляем новые настройки в bashrc
    cat >> ~/.bashrc << 'EOF'

# VPN Global Proxy Settings
export http_proxy=http://127.0.0.1:8080
export https_proxy=http://127.0.0.1:8080
export HTTP_PROXY=http://127.0.0.1:8080
export HTTPS_PROXY=http://127.0.0.1:8080
export all_proxy=socks5://127.0.0.1:1080
export ALL_PROXY=socks5://127.0.0.1:1080
export no_proxy=localhost,127.0.0.1,::1
EOF
    
    # Применяем настройки к текущей сессии ПРИНУДИТЕЛЬНО
    export http_proxy=http://127.0.0.1:8080
    export https_proxy=http://127.0.0.1:8080
    export HTTP_PROXY=http://127.0.0.1:8080
    export HTTPS_PROXY=http://127.0.0.1:8080
    export all_proxy=socks5://127.0.0.1:1080
    export ALL_PROXY=socks5://127.0.0.1:1080
    export no_proxy=localhost,127.0.0.1,::1
    
    # Настройка для системных команд
    sudo tee /etc/environment > /dev/null << 'EOF'
http_proxy=http://127.0.0.1:8080
https_proxy=http://127.0.0.1:8080
HTTP_PROXY=http://127.0.0.1:8080
HTTPS_PROXY=http://127.0.0.1:8080
all_proxy=socks5://127.0.0.1:1080
ALL_PROXY=socks5://127.0.0.1:1080
no_proxy=localhost,127.0.0.1,::1
EOF
    
    # Настройка для apt (если система Ubuntu/Debian)
    if command -v apt &> /dev/null; then
        sudo tee /etc/apt/apt.conf.d/95proxies > /dev/null << 'EOF'
Acquire::http::Proxy "http://127.0.0.1:8080";
Acquire::https::Proxy "http://127.0.0.1:8080";
EOF
    fi
    
    # Создаем wrapper для curl
    sudo tee /usr/local/bin/curl-vpn > /dev/null << 'EOF'
#!/bin/bash
http_proxy=http://127.0.0.1:8080 https_proxy=http://127.0.0.1:8080 /usr/bin/curl "$@"
EOF
    sudo chmod +x /usr/local/bin/curl-vpn
    
    # Создаем alias для curl
    echo 'alias curl="http_proxy=http://127.0.0.1:8080 https_proxy=http://127.0.0.1:8080 /usr/bin/curl"' >> ~/.bashrc
    
    print_success "Глобальный прокси настроен"
    print_status "Переменные окружения применены к текущей сессии"
    print_status "Создан wrapper curl-vpn для принудительного использования прокси"
}

# Настройка простого режима (БЕЗ глобального прокси)
setup_simple_mode() {
    print_status "Настройка простого режима..."
    
    # Полностью удаляем настройки прокси из bashrc
    sed -i '/# VPN Global Proxy Settings/,+8d' ~/.bashrc 2>/dev/null || true
    sed -i '/# VPN Simple Mode Settings/,+8d' ~/.bashrc 2>/dev/null || true
    sed -i '/alias curl=/d' ~/.bashrc 2>/dev/null || true
    
    # Добавляем настройки простого режима (ОТКЛЮЧАЕМ все прокси)
    cat >> ~/.bashrc << 'EOF'

# VPN Simple Mode Settings - NO AUTO PROXY
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
EOF
    
    # Удаляем переменные из текущей сессии
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    
    # Создаем чистый /etc/environment
    sudo tee /etc/environment > /dev/null << 'EOF'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
EOF
    
    # Удаляем системные настройки прокси
    sudo rm -f /etc/apt/apt.conf.d/95proxies
    sudo rm -f /usr/local/bin/curl-vpn
    
    print_success "Простой режим настроен - прокси отключены"
    print_status "Переменные прокси удалены из текущей сессии"
}

# Отключение глобального прокси
disable_global_proxy() {
    print_status "Отключение глобального прокси..."
    
    # Удаляем настройки из bashrc
    sed -i '/# VPN Global Proxy Settings/,+8d' ~/.bashrc 2>/dev/null || true
    sed -i '/# VPN Simple Mode Settings/,+8d' ~/.bashrc 2>/dev/null || true
    sed -i '/alias curl=/d' ~/.bashrc 2>/dev/null || true
    
    # Удаляем системные настройки
    sudo rm -f /etc/environment
    sudo rm -f /etc/apt/apt.conf.d/95proxies
    sudo rm -f /usr/local/bin/curl-vpn
    
    # Создаем чистый /etc/environment
    sudo tee /etc/environment > /dev/null << 'EOF'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
EOF
    
    # Удаляем переменные из текущей сессии
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    
    print_success "Глобальный прокси отключен"
}

# Полная очистка переменных прокси
clear_proxy_vars() {
    print_status "Очистка переменных прокси в текущей сессии..."
    
    # Удаляем все переменные прокси из текущей сессии
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    
    print_success "Переменные прокси очищены"
    print_status "Теперь curl будет работать напрямую (без VPN)"
}

# Функции управления VPN
start_vpn() {
    print_status "Запуск VPN..."
    sudo systemctl start sing-box
    sleep 3
    
    if sudo systemctl is-active --quiet sing-box; then
        print_success "VPN запущен"
        return 0
    else
        print_error "Ошибка запуска VPN"
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
    fi
}

# Проверка статуса VPN
status_vpn() {
    echo -e "${BLUE}=== Статус VPN ===${NC}"
    
    if sudo systemctl is-active --quiet sing-box; then
        print_success "VPN активен"
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
    
    echo -e "${BLUE}Ваш текущий IP (прямое соединение):${NC}"
    # Принудительно отключаем прокси для этого теста
    CURRENT_IP=$(unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY; curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "$CURRENT_IP"
    
    echo ""
    echo -e "${BLUE}Проверка через SOCKS5 прокси:${NC}"
    PROXY_IP=$(curl -s --max-time 10 --proxy socks5://127.0.0.1:1080 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "$PROXY_IP"
    
    echo ""
    echo -e "${BLUE}Проверка через HTTP прокси:${NC}"
    HTTP_IP=$(curl -s --max-time 10 --proxy http://127.0.0.1:8080 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "$HTTP_IP"
    
    echo ""
    if [ "$PROXY_IP" != "ошибка" ] && [ "$PROXY_IP" != "$CURRENT_IP" ]; then
        print_success "SOCKS5 прокси работает корректно!"
    else
        print_warning "Проблема с SOCKS5 прокси"
    fi
    
    if [ "$HTTP_IP" != "ошибка" ] && [ "$HTTP_IP" != "$CURRENT_IP" ]; then
        print_success "HTTP прокси работает корректно!"
    else
        print_warning "Проблема с HTTP прокси"
    fi
}

# Переключение в глобальный режим
switch_to_global() {
    print_status "Переключение в глобальный режим..."
    
    # Проверяем, что переменные установлены, если нет - устанавливаем из сохраненных значений
    if [ -z "$VLESS_SERVER" ]; then
        # Пытаемся извлечь данные из существующей конфигурации
        if [ -f ~/.config/sing-box/config.json ]; then
            VLESS_SERVER=$(grep '"server":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_PORT=$(grep '"server_port":' ~/.config/sing-box/config.json | grep -o '[0-9]\+')
            VLESS_UUID=$(grep '"uuid":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_SNI=$(grep '"server_name":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_PBK=$(grep '"public_key":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_SID=$(grep '"short_id":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_FP="chrome"
            
            export VLESS_SERVER VLESS_PORT VLESS_UUID VLESS_SNI VLESS_PBK VLESS_SID VLESS_FP
        else
            print_error "Конфигурация не найдена. Сначала выполните установку."
            return 1
        fi
    fi
    
    # Останавливаем VPN
    stop_vpn
    
    # Создаем конфигурацию для глобального режима
    create_global_config
    
    # Проверяем конфигурацию
    if ! sing-box check -c ~/.config/sing-box/config.json; then
        print_error "Ошибка в конфигурации"
        return 1
    fi
    
    # Запускаем VPN
    start_vpn
    
    # Настраиваем глобальный прокси
    setup_global_proxy
    
    print_success "🌐 Глобальный режим включен - весь трафик идет через VPN"
    
    # Тестируем соединение сразу с принудительными переменными
    sleep 2
    print_status "Тестирование глобального прокси..."
    
    # Тест с принудительными переменными окружения
    GLOBAL_IP=$(http_proxy=http://127.0.0.1:8080 https_proxy=http://127.0.0.1:8080 curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "ошибка")
    
    if [ "$GLOBAL_IP" != "ошибка" ]; then
        print_success "✅ Глобальный IP: $GLOBAL_IP"
        # Проверяем IP без принудительных переменных (должен быть тот же через автоматический прокси)
        CURRENT_IP=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "ошибка")
        if [ "$CURRENT_IP" = "$GLOBAL_IP" ]; then
            print_success "🎉 Глобальный VPN работает автоматически!"
        else
            print_warning "⚠️ Глобальный VPN настроен, применится после перезапуска терминала"
        fi
    else
        print_warning "⚠️ Не удалось получить IP, но VPN настроен"
    fi
    
    echo ""
    echo -e "${BLUE}Способы тестирования:${NC}"
    echo "  curl ifconfig.me                              # автоматически через VPN"
    echo "  curl-vpn ifconfig.me                          # принудительно через VPN"
    echo "  unset http_proxy && curl ifconfig.me          # напрямую (обход VPN)"
    echo ""
    echo -e "${GREEN}✅ Все новые терминалы будут автоматически использовать VPN${NC}"
}

# Переключение в простой режим
switch_to_simple() {
    print_status "Переключение в простой режим..."
    
    # Проверяем, что переменные установлены, если нет - устанавливаем из сохраненных значений
    if [ -z "$VLESS_SERVER" ]; then
        # Пытаемся извлечь данные из существующей конфигурации
        if [ -f ~/.config/sing-box/config.json ]; then
            VLESS_SERVER=$(grep '"server":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_PORT=$(grep '"server_port":' ~/.config/sing-box/config.json | grep -o '[0-9]\+')
            VLESS_UUID=$(grep '"uuid":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_SNI=$(grep '"server_name":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_PBK=$(grep '"public_key":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_SID=$(grep '"short_id":' ~/.config/sing-box/config.json | cut -d'"' -f4)
            VLESS_FP="chrome"
            
            export VLESS_SERVER VLESS_PORT VLESS_UUID VLESS_SNI VLESS_PBK VLESS_SID VLESS_FP
        else
            print_error "Конфигурация не найдена. Сначала выполните установку."
            return 1
        fi
    fi
    
    # Останавливаем VPN
    stop_vpn
    
    # Настраиваем простой режим (ОТКЛЮЧАЕМ глобальный прокси)
    setup_simple_mode
    
    # Создаем простую конфигурацию (теперь с HTTP прокси)
    create_simple_config
    
    # Проверяем конфигурацию
    if ! sing-box check -c ~/.config/sing-box/config.json; then
        print_error "Ошибка в конфигурации"
        return 1
    fi
    
    # Запускаем VPN
    start_vpn
    
    print_success "📡 Простой режим включен - VPN доступен только через прокси"
    
    # Тестируем соединения
    sleep 2
    print_status "Тестирование простого режима..."
    
    echo -e "${BLUE}Прямое соединение (без прокси):${NC}"
    DIRECT_IP=$(unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY; curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "IP: $DIRECT_IP"
    
    echo -e "${BLUE}Через SOCKS5 прокси:${NC}"
    SOCKS_IP=$(curl -s --max-time 10 --proxy socks5://127.0.0.1:1080 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "IP: $SOCKS_IP"
    
    echo -e "${BLUE}Через HTTP прокси:${NC}"
    HTTP_IP=$(curl -s --max-time 10 --proxy http://127.0.0.1:8080 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "IP: $HTTP_IP"
    
    echo -e "${BLUE}Обычный curl (должен идти напрямую):${NC}"
    NORMAL_IP=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "ошибка")
    echo "IP: $NORMAL_IP"
    
    if [ "$DIRECT_IP" = "$NORMAL_IP" ] && [ "$DIRECT_IP" != "ошибка" ]; then
        print_success "✅ Прямое соединение работает без VPN!"
    else
        print_error "❌ Проблема с прямым соединением"
    fi
    
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
    echo "  curl ifconfig.me                                    # прямое соединение (БЕЗ VPN)"
    echo "  curl --proxy socks5://127.0.0.1:1080 ifconfig.me   # через SOCKS5 (ЧЕРЕЗ VPN)"
    echo "  curl --proxy http://127.0.0.1:8080 ifconfig.me     # через HTTP (ЧЕРЕЗ VPN)"
    echo ""
    echo -e "${GREEN}✅ Все новые терминалы будут работать без автоматического прокси${NC}"
}

# Просмотр логов
show_logs() {
    echo -e "${BLUE}=== Логи VPN (последние 20 строк) ===${NC}"
    sudo journalctl -u sing-box --no-pager -n 20
    echo ""
    echo -e "${BLUE}Для просмотра логов в реальном времени: sudo journalctl -u sing-box -f${NC}"
}

# Функция установки с URL
install_with_url() {
    local vless_url="$1"
    
    if [ -z "$vless_url" ]; then
        print_error "Не указан VLESS URL"
        echo "Использование: $0 install <vless://url>"
        exit 1
    fi
    
    echo -e "${GREEN}=================================================="
    echo "         Установка VLESS VPN (sing-box)"
    echo "==================================================${NC}"
    
    # Установка зависимостей
    if command -v apt &> /dev/null; then
        sudo apt update && sudo apt install -y curl wget
    fi
    
    # Проверяем и устанавливаем sing-box
    install_sing_box
    
    # Парсим URL и создаем конфигурацию
    parse_vless_url "$vless_url"
    create_global_config  # Сразу создаем глобальную конфигурацию
    
    # Проверяем конфигурацию
    if ! sing-box check -c ~/.config/sing-box/config.json; then
        print_error "Ошибка в конфигурации"
        exit 1
    fi
    
    print_success "Конфигурация корректна"
    
    # Создаем сервис и запускаем
    create_service
    start_vpn
    
    # Настраиваем глобальный прокси
    setup_global_proxy
    
    echo ""
    print_success "🎉 VPN успешно установлен и настроен!"
    echo ""
    echo -e "${GREEN}🌐 Глобальный режим активен - весь трафик идет через VPN${NC}"
    echo ""
    echo -e "${BLUE}Прокси адреса:${NC}"
    echo "  SOCKS5: 127.0.0.1:1080"
    echo "  HTTP: 127.0.0.1:8080"
    echo ""
    echo -e "${BLUE}Управление VPN:${NC}"
    echo "  $0 start          # запустить VPN"
    echo "  $0 stop           # остановить VPN"
    echo "  $0 restart        # перезапустить VPN"
    echo "  $0 status         # показать статус"
    echo "  $0 global         # включить глобальный режим"
    echo "  $0 simple         # включить простой режим"
    echo "  $0 clear          # очистить переменные прокси"
    echo "  $0 test           # тест соединения"
    echo "  $0 logs           # показать логи"
    echo "  $0 off            # полностью отключить VPN"
    echo ""
    
    # Тест соединения
    sleep 3
    test_connection
    
    echo ""
    echo -e "${GREEN}✅ Глобальный режим активен для новых терминалов${NC}"
}

# Полное отключение VPN
disable_vpn() {
    print_status "Полное отключение VPN..."
    
    # Останавливаем и отключаем сервис
    sudo systemctl stop sing-box
    sudo systemctl disable sing-box
    
    # Отключаем глобальный прокси
    disable_global_proxy
    
    print_success "VPN полностью отключен"
    print_warning "Новые терминалы будут работать без VPN"
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
        global)
            switch_to_global
            ;;
        simple)
            switch_to_simple
            ;;
        clear)
            clear_proxy_vars
            ;;
        logs)
            show_logs
            ;;
        off|disable)
            disable_vpn
            ;;
        help|*)
            echo -e "${GREEN}🚀 VPN Manager для sing-box${NC}"
            echo ""
            echo "Использование: $0 <команда> [параметры]"
            echo ""
            echo -e "${BLUE}Команды:${NC}"
            echo "  install <vless://url>  # установить VPN с глобальным режимом"
            echo "  start                  # запустить VPN"
            echo "  stop                   # остановить VPN"
            echo "  restart                # перезапустить VPN"
            echo "  status                 # показать статус VPN"
            echo "  test                   # тест соединения"
            echo "  global                 # включить глобальный режим (весь трафик)"
            echo "  simple                 # включить простой режим (только прокси)"
            echo "  clear                  # очистить переменные прокси в сессии"
            echo "  off                    # полностью отключить VPN"
            echo "  logs                   # показать логи"
            echo "  help                   # показать эту справку"
            echo ""
            echo -e "${YELLOW}Примеры:${NC}"
            echo "  $0 install 'vless://uuid@server:port?params'  # установка"
            echo "  $0 test                                       # проверить IP"
            echo "  $0 global                                     # весь трафик через VPN"
            echo "  $0 simple                                     # только прокси режим"
            echo "  $0 clear                                      # очистить прокси"
            echo "  $0 off                                        # отключить VPN"
            echo ""
            echo -e "${BLUE}🌐 Глобальный режим:${NC}"
            echo "  ✅ Весь трафик автоматически через VPN"
            echo "  ✅ Работает во всех новых терминалах"
            echo "  ✅ Не нужно указывать прокси вручную"
            echo ""
            echo -e "${BLUE}📡 Простой режим:${NC}"
            echo "  ✅ Обычный трафик идет напрямую (БЕЗ VPN)"
            echo "  ✅ VPN только при указании прокси вручную"
            echo "  ✅ Полный контроль - когда использовать VPN"
            echo ""
            echo -e "${BLUE}Простой режим - примеры:${NC}"
            echo "  curl ifconfig.me                                    # напрямую"
            echo "  curl --proxy socks5://127.0.0.1:1080 ifconfig.me   # через VPN"
            echo "  curl --proxy http://127.0.0.1:8080 ifconfig.me     # через VPN"
            ;;
    esac
}

# Запуск
main "$@"
