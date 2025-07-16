# VPN Manager для sing-box

Простой менеджер VPN для настройки и управления VLESS-соединениями через sing-box.

## Что это такое?

VPN Manager - это bash-скрипт для автоматической установки, настройки и управления VPN-соединениями через VLESS протокол с использованием sing-box. Скрипт поддерживает Reality TLS и предоставляет удобный интерфейс для управления VPN-сервисом.

## Функциональность

- ✅ Автоматическая установка sing-box
- ✅ Парсинг VLESS URL с параметрами Reality
- ✅ Создание конфигурации sing-box
- ✅ Настройка systemd сервиса
- ✅ Управление VPN (start/stop/restart)
- ✅ Тестирование соединения
- ✅ Просмотр логов
- ✅ SOCKS5 прокси (127.0.0.1:1080)
- ✅ HTTP прокси (127.0.0.1:8080)

## Установка

1. Скачайте скрипт:
```bash
wget https://raw.githubusercontent.com/your-repo/vpn-manager/main/vpn_manager.sh
chmod +x vpn_manager.sh
```

2. Установите VPN с вашим VLESS URL:
```bash
./vpn_manager.sh install 'vless://uuid@server:port?security=reality&sni=example.com&pbk=public_key&sid=short_id&fp=chrome'
```

## Использование

### Основные команды

```bash
# Запустить VPN
./vpn_manager.sh start

# Остановить VPN
./vpn_manager.sh stop

# Перезапустить VPN
./vpn_manager.sh restart

# Проверить статус
./vpn_manager.sh status

# Протестировать соединение
./vpn_manager.sh test

# Показать логи
./vpn_manager.sh logs

# Показать справку
./vpn_manager.sh help
```

### Использование прокси

После запуска VPN доступны два прокси:

```bash
# SOCKS5 прокси (рекомендуется)
curl --proxy socks5://127.0.0.1:1080 ifconfig.me

# HTTP прокси
curl --proxy http://127.0.0.1:8080 ifconfig.me

# Прямое соединение (без VPN)
curl ifconfig.me
```

## Переменные окружения для curl

Для удобства использования curl через VPN без указания прокси-параметров каждый раз, можно настроить следующие переменные окружения:

### Вариант 1: Автоматическое использование прокси

```bash
# Добавить в ~/.bashrc или ~/.zshrc:
export HTTP_PROXY=http://127.0.0.1:8080
export HTTPS_PROXY=http://127.0.0.1:8080
export http_proxy=http://127.0.0.1:8080
export https_proxy=http://127.0.0.1:8080
export ftp_proxy=http://127.0.0.1:8080
export socks_proxy=socks5://127.0.0.1:1080

# Исключения для локальных адресов
export no_proxy=127.0.0.1,localhost,local,.local

# Применить изменения
source ~/.bashrc
```

После настройки переменных окружения:
```bash
# Все curl команды будут автоматически использовать прокси
curl ifconfig.me  # теперь идет через VPN
```

### Вариант 2: Алиасы для удобства

```bash
# Добавить в ~/.bashrc или ~/.zshrc:
alias curl-vpn='curl --proxy http://127.0.0.1:8080'
alias curl-socks='curl --proxy socks5://127.0.0.1:1080'
alias curl-direct='curl --noproxy "*"'

# Применить изменения
source ~/.bashrc
```

Использование алиасов:
```bash
curl-vpn ifconfig.me    # через HTTP прокси
curl-socks ifconfig.me  # через SOCKS5 прокси
curl-direct ifconfig.me # прямое соединение
```

### Вариант 3: Временные переменные для сессии

```bash
# Только для текущей сессии терминала
export HTTP_PROXY=http://127.0.0.1:8080
export HTTPS_PROXY=http://127.0.0.1:8080
export http_proxy=http://127.0.0.1:8080
export https_proxy=http://127.0.0.1:8080

# Все curl команды в этой сессии будут использовать прокси
curl ifconfig.me
```

## Требования

- Linux система с systemd
- sudo права
- curl и wget
- Интернет соединение для скачивания sing-box

## Поддерживаемые архитектуры

- x86_64 (amd64)
- aarch64 (arm64)
- armv7l (armv7)

## Файлы конфигурации

- Конфигурация sing-box: `~/.config/sing-box/config.json`
- Systemd сервис: `/etc/systemd/system/sing-box.service`

## Порты

- SOCKS5 прокси: 127.0.0.1:1080
- HTTP прокси: 127.0.0.1:8080

## Логи

Просмотр логов в реальном времени:
```bash
sudo journalctl -u sing-box -f
```

## Отладка

Если VPN не работает:
1. Проверьте статус: `./vpn_manager.sh status`
2. Посмотрите логи: `./vpn_manager.sh logs`
3. Протестируйте соединение: `./vpn_manager.sh test`
4. Проверьте конфигурацию: `sing-box check -c ~/.config/sing-box/config.json`