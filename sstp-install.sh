#!/bin/bash

# ============================================================
#  SSTP VPN Server Setup for Ubuntu 24.04
#  Подключение с Windows 11 (встроенный VPN клиент)
#  Протокол: SSTP (Secure Socket Tunneling Protocol)
#  v3.4 — ДАННЫЕ ПОЛЬЗОВАТЕЛЯ ПО НОМЕРУ
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

CONFIG_FILE="/etc/sstp_vpn.conf"
CHAP_SECRETS="/etc/ppp/chap-secrets"
CERT_DIR="/etc/sstpd/certs"
ONETIME_DIR="/tmp/sstp_onetime"
ONETIME_PID_FILE="/tmp/sstp_onetime.pid"
PPP_OPTIONS="/etc/ppp/options.sstp"

# ============================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================================

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║          SSTP VPN Manager v3.4                       ║"
    echo "║          Ubuntu 24.04 → Windows 11                   ║"
    echo "║           Передай привеД ПОТАПу !                    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
print_err()  { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
print_step() { echo -e "  ${MAGENTA}→${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_err "Скрипт нужно запускать от root (sudo)."
        exit 1
    fi
}

is_installed() {
    [[ -f "$CONFIG_FILE" ]]
}

get_server_ip() {
    hostname -I | awk '{print $1}'
}

get_external_ip() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local _EXT
        _EXT=$(grep "^EXTERNAL_IP=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
        if [[ -n "$_EXT" ]]; then
            echo "$_EXT"
            return
        fi
    fi
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
    get_server_ip
}

detect_external_ip_auto() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
    get_server_ip
}

# ============================================================
# УСТАНОВКА ПАКЕТОВ
# ============================================================

install_packages() {
    print_info "Обновление пакетов..."
    apt-get update -qq

    print_info "Установка зависимостей..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ppp openssl net-tools iptables-persistent \
        build-essential cmake git wget curl \
        python3 python3-pip libevent-dev libssl-dev

    print_info "Установка sstp-server через pip..."
    pip3 install --break-system-packages sstp-server 2>/dev/null || \
    pip3 install sstp-server 2>/dev/null || true

    if ! command -v sstp-server &>/dev/null && ! command -v sstpd &>/dev/null; then
        print_info "Сборка sstp-server из исходников..."
        rm -rf /tmp/sstp-server
        git clone https://github.com/sorz/sstp-server.git /tmp/sstp-server 2>/dev/null
        if [[ -d /tmp/sstp-server ]]; then
            cd /tmp/sstp-server
            mkdir -p build && cd build
            cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
            make -j"$(nproc)" && make install
        fi
    fi

    print_ok "Пакеты установлены."
}

# ============================================================
# ГЕНЕРАЦИЯ SSL СЕРТИФИКАТА
# ============================================================

generate_certificate() {
    local SERVER_IP="$1"
    local FORCE="${2:-0}"

    if [[ -f "$CERT_DIR/server.crt" && "$FORCE" != "1" ]]; then
        print_info "Сертификат уже существует."
        return 0
    fi

    mkdir -p "$CERT_DIR"
    cd "$CERT_DIR" || exit 1

    print_info "Генерация самоподписанного SSL сертификата..."

    openssl genrsa -out ca.key 4096 2>/dev/null
    openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
        -subj "/C=RU/ST=Moscow/L=Moscow/O=SSTPVPN/OU=VPN/CN=SSTP-VPN-CA" 2>/dev/null

    openssl genrsa -out server.key 4096 2>/dev/null
    openssl req -new -key server.key -out server.csr \
        -subj "/C=RU/ST=Moscow/L=Moscow/O=SSTPVPN/OU=VPN/CN=$SERVER_IP" 2>/dev/null

    cat > /tmp/sstp_v3.cnf <<EOF
[v3_req]
subjectAltName = IP:$SERVER_IP
EOF

    openssl x509 -req -days 3650 \
        -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out server.crt -extfile /tmp/sstp_v3.cnf -extensions v3_req 2>/dev/null

    cat server.crt server.key > server.pem
    chmod 600 server.key server.pem ca.key
    rm -f server.csr /tmp/sstp_v3.cnf

    print_ok "Сертификат сгенерирован: $CERT_DIR/"
}

# ============================================================
# КОНФИГУРАЦИЯ PPP
# ============================================================

configure_ppp() {
    cat > "$PPP_OPTIONS" <<EOF
ipcp-accept-local
ipcp-accept-remote
ms-dns 8.8.8.8
ms-dns 8.8.4.4
noccp
auth
crtscts
mtu 1400
mru 1400
lock
connect-delay 5000
refuse-pap
require-mschap-v2
EOF
    print_ok "PPP options настроены: $PPP_OPTIONS"
}

# ============================================================
# СОЗДАНИЕ SYSTEMD СЕРВИСА
# ============================================================

create_systemd_service() {
    local BIN_PATH=""
    if [[ -f "/usr/local/bin/sstpd" ]]; then
        BIN_PATH="/usr/local/bin/sstpd"
    elif [[ -f "/usr/bin/sstpd" ]]; then
        BIN_PATH="/usr/bin/sstpd"
    elif command -v sstp-server &>/dev/null; then
        BIN_PATH=$(which sstp-server)
    else
        print_err "Не найден sstpd/sstp-server"
        exit 1
    fi
    
    cat > /etc/systemd/system/sstp-vpn.service <<EOF
[Unit]
Description=SSTP VPN Server
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH -l 0.0.0.0 -p 443 -c $CERT_DIR/server.crt -k $CERT_DIR/server.key --local 192.168.88.1 --remote 192.168.88.0/24 --range 192.168.88.10-192.168.88.250 --pppd-config $PPP_OPTIONS
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    print_ok "Systemd сервис создан."
}

# ============================================================
# НАСТРОЙКА NAT И ФАЙРВОЛА
# ============================================================

configure_nat() {
    local IFACE
    IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [[ -z "$IFACE" ]]; then
        print_warn "Не удалось определить внешний интерфейс"
        IFACE="eth0"
    fi

    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sed -i 's/net.ipv4.ip_forward=0/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p -q

    iptables -t nat -D POSTROUTING -s 192.168.88.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -s 192.168.88.0/24 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -d 192.168.88.0/24 -j ACCEPT 2>/dev/null

    iptables -t nat -A POSTROUTING -s 192.168.88.0/24 -o "$IFACE" -j MASQUERADE
    iptables -A FORWARD -s 192.168.88.0/24 -j ACCEPT
    iptables -A FORWARD -d 192.168.88.0/24 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443  -j ACCEPT
    iptables -A INPUT -p tcp --dport 8099 -j ACCEPT
    iptables -A INPUT -p tcp --dport 8088 -j ACCEPT

    netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null
    
    print_ok "NAT и firewall настроены (интерфейс: $IFACE)."
}

# ============================================================
# СОХРАНЕНИЕ КОНФИГУРАЦИИ
# ============================================================

save_config() {
    local _SERVER_IP="$1"
    local _EXT_IP="${2:-}"
    cat > "$CONFIG_FILE" <<EOF
SERVER_IP=$_SERVER_IP
CERT_DIR=$CERT_DIR
EXTERNAL_IP=$_EXT_IP
INSTALLED=1
EOF
    chmod 600 "$CONFIG_FILE"
}

set_external_ip() {
    local NEW_IP="$1"
    local SERVER_IP
    SERVER_IP=$(grep "^SERVER_IP=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
    save_config "$SERVER_IP" "$NEW_IP"
}

# ============================================================
# УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ
# ============================================================

user_exists() {
    [[ -f "$CHAP_SECRETS" ]] && grep -q "^\"$1\"" "$CHAP_SECRETS" 2>/dev/null
}

add_user() {
    local U="$1" P="$2"
    if user_exists "$U"; then
        print_warn "Пользователь '$U' уже существует."
        return 1
    fi
    echo "\"$U\" * \"$P\" *" >> "$CHAP_SECRETS"
    chmod 600 "$CHAP_SECRETS"
    print_ok "Пользователь '$U' добавлен."
}

delete_user() {
    local U="$1"
    if ! user_exists "$U"; then
        print_warn "Пользователь '$U' не найден."
        return 1
    fi
    sed -i "/^\"$U\"/d" "$CHAP_SECRETS"
    print_ok "Пользователь '$U' удалён."
}

change_password() {
    local U="$1" P="$2"
    if ! user_exists "$U"; then
        print_warn "Пользователь '$U' не найден."
        return 1
    fi
    sed -i "s|^\"$U\" .* \".*\" .*$|\"$U\" * \"$P\" *|" "$CHAP_SECRETS"
    print_ok "Пароль пользователя '$U' изменён."
}

list_users() {
    print_info "Список пользователей VPN:"
    if [[ ! -f "$CHAP_SECRETS" ]] || [[ ! -s "$CHAP_SECRETS" ]]; then
        echo "  (нет пользователей)"
        return
    fi
    
    local users=$(grep -v "^#" "$CHAP_SECRETS" | grep -v "^$" | awk '{print $1}' | tr -d '"')
    
    if [[ -z "$users" ]]; then
        echo "  (нет пользователей)"
    else
        echo "$users" | while read user; do
            echo "  • $user"
        done
    fi
}

# Функция для получения списка пользователей с номерами
get_users_list() {
    local users=()
    local i=1
    while IFS= read -r line; do
        if [[ -n "$line" ]] && [[ ! "$line" =~ ^# ]]; then
            local username=$(echo "$line" | awk '{print $1}' | tr -d '"')
            if [[ -n "$username" ]]; then
                users+=("$i|$username|$line")
                ((i++))
            fi
        fi
    done < "$CHAP_SECRETS"
    printf '%s\n' "${users[@]}"
}

# Функция для отображения данных выбранного пользователя
show_user_connection_info() {
    local username="$1"
    local password="$2"
    local ext_ip="$3"
    
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗"
    echo -e "║       ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ (Windows 11)            ║"
    echo -e "╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}Пользователь:${NC}      $username"
    echo -e "  ${YELLOW}Пароль:${NC}            $password"
    echo -e "  ${YELLOW}Адрес сервера:${NC}     $ext_ip"
    echo -e "  ${YELLOW}Тип VPN:${NC}           SSTP"
    echo -e "  ${YELLOW}Порт:${NC}              443 (HTTPS)"
    echo -e "  ${YELLOW}Сертификат CA:${NC}     $CERT_DIR/ca.crt"
    echo ""
    echo -e "${GREEN}Инструкция по установке сертификата:${NC}"
    echo "  1. Скачай сертификат через пункт 6 меню"
    echo "  2. Установи его в «Доверенные корневые центры сертификации»"
    echo "  3. Создай VPN подключение с этими данными"
    echo ""
}

print_connection_info() {
    local ext_ip=$(get_external_ip)
    
    # Получаем список пользователей
    local users_list=()
    while IFS= read -r line; do
        if [[ -n "$line" ]] && [[ ! "$line" =~ ^# ]]; then
            local username=$(echo "$line" | awk '{print $1}' | tr -d '"')
            if [[ -n "$username" ]]; then
                users_list+=("$username|$line")
            fi
        fi
    done < "$CHAP_SECRETS"
    
    if [[ ${#users_list[@]} -eq 0 ]]; then
        echo ""
        print_warn "Нет зарегистрированных пользователей!"
        echo ""
        print_info "Сначала добавьте пользователя (пункт 1)"
        return
    fi
    
    # Показываем список пользователей с номерами
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗"
    echo -e "║       ВЫБЕРИТЕ ПОЛЬЗОВАТЕЛЯ                               ║"
    echo -e "╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local i=1
    for entry in "${users_list[@]}"; do
        local username=$(echo "$entry" | cut -d'|' -f1)
        echo -e "  ${GREEN}$i)${NC} $username"
        ((i++))
    done
    echo ""
    echo -e "  ${RED}0)${NC} Назад"
    echo ""
    
    read -rp "  Выберите пользователя [0-${#users_list[@]}]: " user_choice
    
    if [[ "$user_choice" == "0" ]] || [[ -z "$user_choice" ]]; then
        return
    fi
    
    if [[ "$user_choice" =~ ^[0-9]+$ ]] && [[ "$user_choice" -ge 1 ]] && [[ "$user_choice" -le ${#users_list[@]} ]]; then
        local selected="${users_list[$((user_choice-1))]}"
        local username=$(echo "$selected" | cut -d'|' -f1)
        local full_line=$(echo "$selected" | cut -d'|' -f2-)
        # Извлекаем пароль из строки (третий элемент в кавычках)
        local password=$(echo "$full_line" | awk '{print $3}' | tr -d '"')
        
        show_user_connection_info "$username" "$password" "$ext_ip"
    else
        print_err "Неверный выбор!"
    fi
}

restart_services() {
    systemctl restart sstp-vpn 2>/dev/null
    sleep 2
    if systemctl is-active --quiet sstp-vpn; then
        print_ok "Сервис перезапущен и работает."
    else
        print_warn "Сервис не запустился. Проверь: journalctl -u sstp-vpn -n 30"
    fi
}

# ============================================================
# ОДНОРАЗОВАЯ ССЫЛКА ДЛЯ СКАЧИВАНИЯ СЕРТИФИКАТА
# ============================================================

stop_onetime_server() {
    if [[ -f "$ONETIME_PID_FILE" ]]; then
        local PID
        PID=$(cat "$ONETIME_PID_FILE")
        kill "$PID" 2>/dev/null || true
        rm -f "$ONETIME_PID_FILE"
    fi
}

generate_onetime_link() {
    echo ""

    if [[ ! -f "$CERT_DIR/ca.crt" ]]; then
        print_err "Сертификат CA не найден. Сначала выполните установку."
        return 1
    fi

    stop_onetime_server

    local TOKEN
    TOKEN=$(openssl rand -hex 16)

    mkdir -p "$ONETIME_DIR"
    cp "$CERT_DIR/ca.crt" "$ONETIME_DIR/${TOKEN}.crt"

    local PORT=8099
    ss -tlnp 2>/dev/null | grep -q ":${PORT} " && PORT=8088

    local LOCAL_IP
    LOCAL_IP=$(get_server_ip)
    local EXT_IP
    EXT_IP=$(get_external_ip)

    python3 - "$TOKEN" "$PORT" "$ONETIME_DIR" "$ONETIME_PID_FILE" <<'PYEOF' &
import sys, os, time, threading
import http.server, socketserver

TOKEN   = sys.argv[1]
PORT    = int(sys.argv[2])
CERTDIR = sys.argv[3]
PIDFILE = sys.argv[4]
CERTFILE = os.path.join(CERTDIR, TOKEN + '.crt')

with open(PIDFILE, 'w') as f:
    f.write(str(os.getpid()))

downloaded = threading.Event()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass
    def do_GET(self):
        if self.path == '/' + TOKEN + '.crt' and os.path.exists(CERTFILE):
            with open(CERTFILE, 'rb') as f:
                data = f.read()
            self.send_response(200)
            self.send_header('Content-Type',        'application/x-x509-ca-cert')
            self.send_header('Content-Disposition', 'attachment; filename="sstp_ca.crt"')
            self.send_header('Content-Length',      str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            downloaded.set()
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not found or already used.')

httpd = socketserver.TCPServer(('0.0.0.0', PORT), Handler)
httpd.allow_reuse_address = True

def shutdown():
    time.sleep(0.5)
    if os.path.exists(CERTFILE):
        os.remove(CERTFILE)
    if os.path.exists(PIDFILE):
        os.remove(PIDFILE)
    os._exit(0)

def timeout_handler():
    httpd.shutdown()
    shutdown()

t = threading.Timer(60, timeout_handler)
t.daemon = True
t.start()

httpd.serve_forever()
shutdown()
PYEOF

    sleep 1

    if ! ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
        print_err "Не удалось запустить временный HTTP-сервер на порту $PORT."
        return 1
    fi

    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗"
    echo -e "║       ОДНОРАЗОВАЯ ССЫЛКА ДЛЯ СЕРТИФИКАТА            ║"
    echo -e "╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${RED}⚠  Действует 60 секунд или до первого скачивания!${NC}"
    echo ""
    if [[ "$EXT_IP" != "$LOCAL_IP" && -n "$EXT_IP" ]]; then
        echo -e "  ${GREEN}Внешний IP:${NC}  http://${EXT_IP}:${PORT}/${TOKEN}.crt"
    fi
    echo -e "  ${GREEN}Локальный IP:${NC} http://${LOCAL_IP}:${PORT}/${TOKEN}.crt"
    echo ""
    echo -e "  ${BLUE}Инструкция:${NC}"
    echo "    Открой любую из ссылок в браузере на Windows"
    echo "    Файл sstp_ca.crt скачается автоматически"
    echo "    После скачивания ссылка немедленно деактивируется"
    echo ""
    echo -ne "  Ожидание: "

    local PID
    PID=$(cat "$ONETIME_PID_FILE" 2>/dev/null)
    for i in $(seq 60 -1 1); do
        if [[ -n "$PID" ]] && ! kill -0 "$PID" 2>/dev/null; then
            echo ""
            echo ""
            print_ok "Сертификат успешно скачан! Ссылка деактивирована."
            return 0
        fi
        if [[ ! -f "$ONETIME_DIR/${TOKEN}.crt" ]]; then
            sleep 2
            echo ""
            echo ""
            print_ok "Сертификат успешно скачан! Ссылка деактивирована."
            return 0
        fi
        echo -ne "${YELLOW}${i}${NC} "
        sleep 1
    done

    echo ""
    echo ""
    stop_onetime_server
    rm -f "$ONETIME_DIR/${TOKEN}.crt"
    print_warn "Время вышло (60 сек). Ссылка деактивирована."
}

# ============================================================
# ПЕРЕСОЗДАТЬ СЕРТИФИКАТ
# ============================================================

regenerate_certificate() {
    echo ""
    print_warn "После пересоздания сертификата нужно заново"
    print_warn "установить новый ca.crt на ВСЕХ Windows-клиентах!"
    echo ""
    read -rp "  Продолжить? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Отменено."
        return
    fi

    source "$CONFIG_FILE" 2>/dev/null
    local SERVER_IP="${SERVER_IP:-$(get_server_ip)}"

    print_info "Удаляем старые сертификаты..."
    rm -f "$CERT_DIR"/{ca.key,ca.crt,ca.srl,server.key,server.crt,server.pem,server.csr}

    generate_certificate "$SERVER_IP" "1"
    restart_services

    print_ok "Сертификат успешно пересоздан!"
    echo ""
    print_warn "Не забудь обновить сертификат на всех клиентах Windows."
    echo ""
    read -rp "  Сгенерировать одноразовую ссылку прямо сейчас? (y/N): " GEN
    [[ "$GEN" =~ ^[Yy]$ ]] && generate_onetime_link
}

# ============================================================
# HELP — КАК ПОДКЛЮЧИТЬСЯ С WINDOWS 11
# ============================================================

show_help() {
    source "$CONFIG_FILE" 2>/dev/null
    local EXT_IP
    EXT_IP=$(get_external_ip)

    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║       HELP — Подключение SSTP VPN на Windows 11                 ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${YELLOW}━━━ ШАГ 1 — Получить сертификат CA ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    print_step "В главном меню выбери пункт 6 — «Одноразовая ссылка для сертификата»"
    print_step "Скопируй ссылку и открой её в браузере на Windows"
    print_step "Файл ${GREEN}sstp_ca.crt${NC} скачается автоматически"
    echo ""

    echo -e "${YELLOW}━━━ ШАГ 2 — Установить сертификат на Windows ━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    print_step "Двойной клик по файлу ${GREEN}sstp_ca.crt${NC}"
    print_step "Нажми ${CYAN}«Установить сертификат»${NC}"
    print_step "Выбери ${CYAN}«Локальный компьютер»${NC} → Далее"
    print_step "Выбери ${CYAN}«Поместить все сертификаты в следующее хранилище»${NC}"
    print_step "Нажми ${CYAN}«Обзор»${NC} → выбери ${CYAN}«Доверенные корневые центры сертификации»${NC}"
    print_step "ОК → Далее → Готово"
    echo ""

    echo -e "${YELLOW}━━━ ШАГ 3 — Создать VPN подключение ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    print_step "Параметры → Сеть и Интернет → VPN → Добавить VPN"
    echo ""
    echo "    Поставщик VPN:    Windows (встроенный)"
    echo "    Тип VPN:          Протокол SSTP"
    echo "    Адрес сервера:    (внешний IP вашего сервера)"
    echo "    Логин/пароль:     (данные выбранного пользователя)"
    echo ""
}

# ============================================================
# МЕНЮ УПРАВЛЕНИЯ
# ============================================================

menu_add_user() {
    echo ""
    read -rp "  Имя пользователя: " U
    [[ -z "$U" ]] && { print_err "Имя не может быть пустым."; return; }
    read -rsp "  Пароль: " P; echo ""
    [[ -z "$P" ]] && { print_err "Пароль не может быть пустым."; return; }
    add_user "$U" "$P" && restart_services
}

menu_delete_user() {
    echo ""
    list_users; echo ""
    read -rp "  Имя пользователя для удаления: " U
    [[ -z "$U" ]] && { print_err "Имя не может быть пустым."; return; }
    read -rp "  Подтвердить удаление '$U'? (y/N): " C
    [[ "$C" =~ ^[Yy]$ ]] && delete_user "$U" && restart_services || print_info "Отменено."
}

menu_change_password() {
    echo ""
    list_users; echo ""
    read -rp "  Имя пользователя: " U
    [[ -z "$U" ]] && { print_err "Имя не может быть пустым."; return; }
    read -rsp "  Новый пароль: " P; echo ""
    [[ -z "$P" ]] && { print_err "Пароль не может быть пустым."; return; }
    change_password "$U" "$P" && restart_services
}

menu_change_external_ip() {
    echo ""
    local AUTO_IP
    print_info "Определяю внешний IP автоматически..."
    AUTO_IP=$(detect_external_ip_auto)
    local CURRENT_IP
    CURRENT_IP=$(get_external_ip)

    echo ""
    echo -e "  ${YELLOW}Текущий внешний IP:${NC}     $CURRENT_IP"
    echo -e "  ${YELLOW}Авто-определённый IP:${NC}   $AUTO_IP"
    echo -e "  ${YELLOW}Локальный IP сервера:${NC}   $(get_server_ip)"
    echo ""
    echo -e "  ${BLUE}Варианты:${NC}"
    echo -e "  ${CYAN}1)${NC} Использовать авто-определённый: $AUTO_IP"
    echo -e "  ${CYAN}2)${NC} Ввести вручную"
    echo -e "  ${CYAN}3)${NC} Сбросить на авто (удалить ручной IP из конфига)"
    echo -e "  ${CYAN}0)${NC} Отмена"
    echo ""
    read -rp "  Выберите [0-3]: " CH

    case "$CH" in
        1)
            set_external_ip "$AUTO_IP"
            print_ok "Внешний IP установлен: $AUTO_IP"
            ;;
        2)
            echo ""
            read -rp "  Введите внешний IP: " MANUAL_IP
            if [[ -z "$MANUAL_IP" ]]; then
                print_err "IP не может быть пустым."
                return
            fi
            if ! echo "$MANUAL_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
                print_err "Неверный формат IP адреса."
                return
            fi
            set_external_ip "$MANUAL_IP"
            print_ok "Внешний IP установлен: $MANUAL_IP"
            ;;
        3)
            set_external_ip ""
            print_ok "Ручной IP удалён. Теперь IP определяется автоматически."
            ;;
        0)
            print_info "Отменено."
            return
            ;;
        *)
            print_warn "Неверный выбор."
            return
            ;;
    esac
    echo ""
    print_info "Новый внешний IP будет использоваться в данных подключения."
}

show_menu() {
    while true; do
        clear
        print_banner
        source "$CONFIG_FILE" 2>/dev/null
        local SRV_IP="${SERVER_IP:-$(get_server_ip)}"
        local STATUS
        systemctl is-active --quiet sstp-vpn 2>/dev/null && \
            STATUS="${GREEN}● работает${NC}" || STATUS="${RED}● остановлен${NC}"

        echo -e "  ${GREEN}Сервер:${NC} $SRV_IP  ${GREEN}|${NC}  ${GREEN}Внешний IP:${NC} $(get_external_ip)  ${GREEN}|${NC}  Статус: $STATUS"
        echo ""
        echo -e "  ${CYAN} 1)${NC}  Добавить пользователя"
        echo -e "  ${CYAN} 2)${NC}  Удалить пользователя"
        echo -e "  ${CYAN} 3)${NC}  Сменить пароль пользователя"
        echo -e "  ${CYAN} 4)${NC}  Список пользователей"
        echo -e "  ${CYAN} 5)${NC}  Показать данные подключения для пользователя"
        echo -e "  ${CYAN} 6)${NC}  Одноразовая ссылка для сертификата"
        echo -e "  ${CYAN} 7)${NC}  Пересоздать сертификат"
        echo -e "  ${CYAN} 8)${NC}  Перезапустить сервис VPN"
        echo -e "  ${CYAN} 9)${NC}  Статус сервиса и логи"
        echo -e "  ${CYAN}10)${NC}  HELP — как подключиться с Windows"
        echo -e "  ${CYAN}11)${NC}  Изменить внешний IP"
        echo -e "  ${RED} 0)${NC}  Выход"
        echo ""
        read -rp "  Выберите действие [0-11]: " CHOICE

        case "$CHOICE" in
            1)  menu_add_user ;;
            2)  menu_delete_user ;;
            3)  menu_change_password ;;
            4)  echo ""; list_users ;;
            5)  print_connection_info ;;
            6)  generate_onetime_link ;;
            7)  regenerate_certificate ;;
            8)  restart_services ;;
            9)
                echo ""
                systemctl status sstp-vpn --no-pager -l 2>/dev/null
                echo ""
                echo -e "${BLUE}— Последние 20 строк лога —${NC}"
                journalctl -u sstp-vpn -n 20 --no-pager 2>/dev/null
                ;;
            10) show_help ;;
            11) menu_change_external_ip ;;
            0)  echo ""; print_info "До свидания!"; exit 0 ;;
            *)  print_warn "Неверный выбор. Введите число от 0 до 11." ;;
        esac

        echo ""
        read -rp "  Нажмите Enter для продолжения..." _
    done
}

# ============================================================
# ПЕРВИЧНАЯ УСТАНОВКА
# ============================================================

first_install() {
    print_banner
    print_info "Первый запуск — установка SSTP VPN сервера на Ubuntu 24.04"
    echo ""

    local SERVER_IP
    SERVER_IP=$(get_server_ip)
    print_info "Локальный IP сервера: $SERVER_IP"

    print_info "Определяю внешний IP..."
    local AUTO_EXT_IP
    AUTO_EXT_IP=$(detect_external_ip_auto)
    print_info "Обнаружен внешний IP: $AUTO_EXT_IP"
    echo ""

    local FINAL_EXT_IP="$AUTO_EXT_IP"
    if [[ "$AUTO_EXT_IP" == "$SERVER_IP" ]]; then
        print_info "Сервер имеет прямой внешний IP."
    else
        echo -e "  ${YELLOW}Локальный IP:${NC} $SERVER_IP"
        echo -e "  ${YELLOW}Внешний IP:${NC}   $AUTO_EXT_IP"
        echo ""
        echo -e "  Какой IP использовать для подключения клиентов?"
        echo -e "  ${CYAN}1)${NC} Авто-определённый внешний: $AUTO_EXT_IP  ${GREEN}(рекомендуется)${NC}"
        echo -e "  ${CYAN}2)${NC} Ввести вручную"
        echo -e "  ${CYAN}3)${NC} Локальный: $SERVER_IP"
        echo ""
        read -rp "  Выберите [1-3, Enter = 1]: " IP_CHOICE
        IP_CHOICE="${IP_CHOICE:-1}"

        case "$IP_CHOICE" in
            2)
                read -rp "  Введите внешний IP: " MANUAL_EXT
                if echo "$MANUAL_EXT" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
                    FINAL_EXT_IP="$MANUAL_EXT"
                else
                    print_warn "Неверный формат. Используем авто-определённый: $AUTO_EXT_IP"
                    FINAL_EXT_IP="$AUTO_EXT_IP"
                fi
                ;;
            3)
                FINAL_EXT_IP="$SERVER_IP"
                ;;
            *)
                FINAL_EXT_IP="$AUTO_EXT_IP"
                ;;
        esac
    fi

    print_ok "Внешний IP для клиентов: $FINAL_EXT_IP"
    echo ""

    install_packages
    generate_certificate "$SERVER_IP"
    configure_ppp

    touch "$CHAP_SECRETS"
    chmod 600 "$CHAP_SECRETS"

    create_systemd_service
    configure_nat
    save_config "$SERVER_IP" "$FINAL_EXT_IP"

    systemctl enable sstp-vpn 2>/dev/null
    systemctl start sstp-vpn 2>/dev/null
    sleep 2

    if systemctl is-active --quiet sstp-vpn; then
        print_ok "SSTP VPN сервис успешно запущен!"
    else
        print_warn "Сервис не запустился автоматически."
        print_info "Проверьте логи: journalctl -u sstp-vpn -n 30"
    fi

    echo ""
    print_info "Создание первого VPN-пользователя:"
    read -rp "  Имя пользователя: " FIRST_USER
    while [[ -z "$FIRST_USER" ]]; do
        print_err "Имя не может быть пустым."
        read -rp "  Имя пользователя: " FIRST_USER
    done
    read -rsp "  Пароль: " FIRST_PASS; echo ""
    while [[ -z "$FIRST_PASS" ]]; do
        print_err "Пароль не может быть пустым."
        read -rsp "  Пароль: " FIRST_PASS; echo ""
    done

    add_user "$FIRST_USER" "$FIRST_PASS"
    restart_services

    print_ok "Установка завершена!"
    
    echo ""
    read -rp "  Сгенерировать одноразовую ссылку для сертификата прямо сейчас? (y/N): " GEN
    [[ "$GEN" =~ ^[Yy]$ ]] && generate_onetime_link

    echo ""
    read -rp "  Нажмите Enter для перехода в меню управления..." _
}

# ============================================================
# ТОЧКА ВХОДА
# ============================================================

check_root

if is_installed; then
    clear
    show_menu
else
    clear
    first_install
    show_menu
fi
