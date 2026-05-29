#!/bin/bash
# ==============================================================================
# ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 1 (БАЗОВАЯ ИНФРАСТРУКТУРА)
# Целевая ОС: Ubuntu 22.04 / 24.04 LTS
# Архитектура: x86_64
# ==============================================================================

# --- ИНЖЕНЕРНАЯ ИНИЦИАТИВА: Безопасное завершение ---
trap cleanup SIGINT SIGTERM

cleanup() {
    echo -e "\n\033[0;31m[ВНИМАНИЕ] Скрипт прерван пользователем. Снимаю блокировки файлов...\033[0m"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
    exit 1
}

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[0;31m[ФАТАЛЬНО] Запустите скрипт от root (sudo su)!\033[0m"
  exit 1
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ======================== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ========================
DOMAIN="au-team.irpo"

ISP_HQ_IP="172.16.40.1"
HQ_ISP_IP="172.16.40.2"
ISP_BR_IP="172.16.50.1"
BR_ISP_IP="172.16.50.2"

HQ_SRV_IP="192.168.10.2"
HQ_RTR_V10="192.168.10.1"
HQ_RTR_V20="192.168.20.1"
HQ_RTR_V99="192.168.99.1"

BR_SRV_IP="192.168.30.2"
BR_RTR_LAN="192.168.30.1"

GRE_HQ="10.0.0.1"
GRE_BR="10.0.0.2"

export DEBIAN_FRONTEND=noninteractive

# ======================== БАЗОВЫЕ ФУНКЦИИ ========================

log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_succ() { echo -e "${GREEN}[УСПЕХ] $1${NC}"; }
log_err()  { echo -e "${RED}[ОШИБКА] $1${NC}"; }

# --- ИНЖЕНЕРНАЯ ИНИЦИАТИВА: Защита от "опечаток" при выборе интерфейса ---
get_valid_interface() {
    local prompt_msg="$1"
    local int_var_name="$2"
    local input_int
    while true; do
        read -p "$prompt_msg" input_int
        if ip link show "$input_int" > /dev/null 2>&1; then
            eval $int_var_name="'$input_int'"
            break
        else
            log_err "Интерфейс '$input_int' не существует! Попробуйте снова."
        fi
    done
}

# --- ИНЖЕНЕРНАЯ ИНИЦИАТИВА: Защита от зависания APT ---
prepare_apt() {
    log_info "Проверка связности с Интернетом (8.8.8.8)..."
    if ! ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_err "Нет доступа в Интернет! Убедитесь, что ISP и NAT настроены."
        log_info "Попытка продолжить, но установка пакетов может зависнуть."
    fi

    log_info "Подготовка подсистемы APT..."
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

    chattr -i /etc/resolv.conf 2>/dev/null || true
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

    dpkg --configure -a 2>/dev/null || true
    apt-get update -y -q || log_err "apt-get update вернул ошибку!"
}

set_hostname_and_time() {
    log_info "Установка имени $1 и часового пояса..."
    hostnamectl set-hostname "$1"
    timedatectl set-timezone Europe/Moscow
    cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.0.1 $1 ${1%%.*}
EOF
}

show_interfaces() {
    echo -e "\n${YELLOW}Доступные сетевые интерфейсы:${NC}"
    ip -br l | awk '{print $1" - "$3}' | grep -v "lo"
}

apply_netplan() {
    log_info "Применение конфигурации Netplan..."
    chmod 600 /etc/netplan/*.yaml
    netplan apply
    sleep 3
}

force_dns() {
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver $1
search $DOMAIN
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
}

create_sshuser() {
    log_info "Создание учетной записи sshuser..."
    id -u sshuser &>/dev/null || useradd -m -s /bin/bash -u 1015 sshuser
    echo "sshuser:P@ssw0rd" | chpasswd
    usermod -aG sudo sshuser
    echo "sshuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser
    chmod 440 /etc/sudoers.d/sshuser

    echo "Authorized access only" > /etc/issue.net
    apt-get install -y -q openssh-server || true

    sed -i 's/^#*Port .*/Port 3015/' /etc/ssh/sshd_config
    sed -i 's/^#*Banner .*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
    sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 2/' /etc/ssh/sshd_config
    
    if ! grep -q "^AllowUsers" /etc/ssh/sshd_config; then
        echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    else
        sed -i 's/^AllowUsers.*/AllowUsers sshuser/' /etc/ssh/sshd_config
    fi
    systemctl restart ssh || systemctl restart sshd || true
}

create_netadmin() {
    log_info "Создание пользователя net_admin..."
    id -u net_admin &>/dev/null || useradd -m -s /bin/bash net_admin
    echo 'net_admin:P@$$word' | chpasswd
    usermod -aG sudo net_admin
    echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
    chmod 440 /etc/sudoers.d/net_admin
}

# ======================== ИСПОЛНЯЕМЫЕ БЛОКИ ========================

setup_isp() {
    set_hostname_and_time "isp.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс в ИНТЕРНЕТ (NAT/DHCP): " INT_EXT
    get_valid_interface "Интерфейс к HQ-RTR: " INT_HQ
    get_valid_interface "Интерфейс к BR-RTR: " INT_BR

    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_EXT:
      optional: true
      dhcp4: true
    $INT_HQ:
      optional: true
      addresses: [$ISP_HQ_IP/28]
    $INT_BR:
      optional: true
      addresses: [$ISP_BR_IP/28]
EOF
    apply_netplan
    prepare_apt

    apt-get install -y -q iptables-persistent

    cat > /etc/sysctl.d/99-forward.conf <<EOF
net.ipv4.ip_forward=1
EOF
    sysctl -p /etc/sysctl.d/99-forward.conf

    iptables -t nat -F POSTROUTING
    iptables -t nat -A POSTROUTING -o $INT_EXT -j MASQUERADE
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    force_dns "8.8.8.8"
    log_succ "ISP: Маршрутизация и NAT настроены!"
}

setup_hqrtr() {
    set_hostname_and_time "hq-rtr.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс к ISP: " INT_ISP
    get_valid_interface "Интерфейс ВНУТРЬ (к серверу/клиенту): " INT_LAN

    # Реализация "Виртуального коммутатора" через bridge
    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_ISP:
      optional: true
      addresses: [$HQ_ISP_IP/28]
      routes:
        - to: default
          via: $ISP_HQ_IP
    $INT_LAN:
      optional: true
      dhcp4: false
  bridges:
    br0:
      interfaces: [$INT_LAN]
      parameters:
        stp: false
        forward-delay: 0
  vlans:
    vlan10:
      id: 10
      link: br0
      addresses: [$HQ_RTR_V10/27]
    vlan20:
      id: 20
      link: br0
      addresses: [$HQ_RTR_V20/27]
    vlan99:
      id: 99
      link: br0
      addresses: [$HQ_RTR_V99/29]
  tunnels:
    gre1:
      mode: gre
      local: $HQ_ISP_IP
      remote: $BR_ISP_IP
      addresses: [$GRE_HQ/30]
      mtu: 1400
EOF
    apply_netplan
    prepare_apt

    apt-get install -y -q isc-dhcp-server iptables-persistent frr chrony

    create_netadmin

    cat > /etc/sysctl.d/99-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
# Разрешаем прохождение трафика через мост (для OSPF и мультикаста)
net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-arptables=0
EOF
    sysctl -p /etc/sysctl.d/99-forward.conf
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f"; done

    sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"vlan20\"/" /etc/default/isc-dhcp-server
    cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
subnet 192.168.20.0 netmask 255.255.255.224 {
  range 192.168.20.11 192.168.20.30;
  option routers $HQ_RTR_V20;
  option domain-name-servers $HQ_SRV_IP;
  option domain-name "$DOMAIN";
}
EOF
    systemctl restart isc-dhcp-server || true

    iptables -F
    iptables -t nat -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -I INPUT -p gre -j ACCEPT
    iptables -I INPUT -i gre1 -p ospf -j ACCEPT
    iptables -I FORWARD -p gre -j ACCEPT
    iptables -I FORWARD -p ospf -j ACCEPT

    # КРИТИЧЕСКИЙ ФИКС: Проброс портов работает ТОЛЬКО для входящего извне трафика (-i $INT_ISP)
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 80 -j DNAT --to-destination $HQ_SRV_IP:80
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 3015 -j DNAT --to-destination $HQ_SRV_IP:3015

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    cat > /etc/chrony/chrony.conf <<EOF
pool ntp.ubuntu.com iburst maxsources 4
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12
local stratum 5
EOF
    systemctl restart chrony

    ip route flush cache
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl restart frr
    sleep 3

    vtysh -c "conf t" \
          -c "interface gre1" \
          -c " ip ospf network point-to-point" \
          -c " ip ospf authentication message-digest" \
          -c " ip ospf message-digest-key 1 md5 P@ssw0rd" \
          -c "exit" \
          -c "router ospf" \
          -c " ospf router-id 1.1.1.1" \
          -c " network 10.0.0.0/30 area 0" \
          -c " network 192.168.10.0/27 area 0" \
          -c " network 192.168.20.0/27 area 0" \
          -c " network 192.168.99.0/29 area 0" \
          -c " passive-interface default" \
          -c " no passive-interface gre1" \
          -c "end" \
          -c "write"

    force_dns "$HQ_SRV_IP"
    log_succ "HQ-RTR: Настроен виртуальный коммутатор, NAT, DHCP и OSPF!"
}

setup_brrtr() {
    set_hostname_and_time "br-rtr.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс к ISP: " INT_ISP
    get_valid_interface "Интерфейс в LAN (к BR-SRV): " INT_LAN

    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_ISP:
      optional: true
      addresses: [$BR_ISP_IP/28]
      routes:
        - to: default
          via: $ISP_BR_IP
    $INT_LAN:
      optional: true
      addresses: [$BR_RTR_LAN/28]
  tunnels:
    gre1:
      mode: gre
      local: $BR_ISP_IP
      remote: $HQ_ISP_IP
      addresses: [$GRE_BR/30]
      mtu: 1400
EOF
    apply_netplan
    prepare_apt

    apt-get install -y -q iptables-persistent frr chrony

    create_netadmin

    cat > /etc/sysctl.d/99-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
    sysctl -p /etc/sysctl.d/99-forward.conf
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f"; done

    iptables -F
    iptables -t nat -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -I INPUT -p gre -j ACCEPT
    iptables -I INPUT -i gre1 -p ospf -j ACCEPT
    iptables -I FORWARD -p gre -j ACCEPT
    iptables -I FORWARD -p ospf -j ACCEPT

    # КРИТИЧЕСКИЙ ФИКС: Ограничение DNAT только внешним интерфейсом
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 8086 -j DNAT --to-destination $BR_SRV_IP:8080
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 3015 -j DNAT --to-destination $BR_SRV_IP:3015

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    cat > /etc/chrony/chrony.conf <<EOF
server $GRE_HQ iburst
server $HQ_RTR_V10 iburst
makestep 1 3
EOF
    systemctl restart chrony

    ip route flush cache
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl restart frr
    sleep 3

    vtysh -c "conf t" \
          -c "interface gre1" \
          -c " ip ospf network point-to-point" \
          -c " ip ospf authentication message-digest" \
          -c " ip ospf message-digest-key 1 md5 P@ssw0rd" \
          -c "exit" \
          -c "router ospf" \
          -c " ospf router-id 2.2.2.2" \
          -c " network 10.0.0.0/30 area 0" \
          -c " network 192.168.30.0/28 area 0" \
          -c " passive-interface default" \
          -c " no passive-interface gre1" \
          -c "end" \
          -c "write"

    force_dns "$HQ_SRV_IP"
    log_succ "BR-RTR: Сеть, NAT и OSPF настроены!"
}

setup_hqsrv() {
    set_hostname_and_time "hq-srv.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс, смотрящий в HQ-RTR: " INT_LAN

    # Коммутатор создан на роутере, здесь просто чистый IP (Access-порт)
    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_LAN:
      optional: true
      dhcp4: false
      addresses: [$HQ_SRV_IP/27]
      routes:
        - to: default
          via: $HQ_RTR_V10
EOF
    apply_netplan
    prepare_apt

    apt-get install -y -q bind9 bind9utils chrony
    create_sshuser

    cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";
    forwarders { 8.8.8.8; };
    dnssec-validation auto;
    listen-on { any; };
    listen-on-v6 { any; };
    allow-query { any; };
    allow-recursion { any; };
};
EOF

    cat > /etc/bind/named.conf.local <<EOF
zone "$DOMAIN" {
    type master;
    file "/etc/bind/db.forward";
};
zone "10.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.rev10";
};
zone "20.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.rev20";
};
EOF

    cat > /etc/bind/db.forward <<EOF
\$TTL 604800
@       IN  SOA   hq-srv.$DOMAIN. admin.$DOMAIN. (
                  4 604800 86400 2419200 604800 )
@       IN  NS    hq-srv.$DOMAIN.
hq-rtr  IN  A     $HQ_RTR_V10
br-rtr  IN  A     $BR_RTR_LAN
hq-srv  IN  A     $HQ_SRV_IP
hq-cli  IN  A     192.168.20.10
br-srv  IN  A     $BR_SRV_IP
moodle  IN  A     $ISP_HQ_IP
wiki    IN  A     $ISP_BR_IP
isp     IN  A     $ISP_HQ_IP
EOF

    cat > /etc/bind/db.rev10 <<EOF
\$TTL 604800
@   IN  SOA  hq-srv.$DOMAIN. admin.$DOMAIN. ( 4 604800 86400 2419200 604800 )
@   IN  NS   hq-srv.$DOMAIN.
1   IN  PTR  hq-rtr.$DOMAIN.
2   IN  PTR  hq-srv.$DOMAIN.
EOF

    cat > /etc/bind/db.rev20 <<EOF
\$TTL 604800
@   IN  SOA  hq-srv.$DOMAIN. admin.$DOMAIN. ( 4 604800 86400 2419200 604800 )
@   IN  NS   hq-srv.$DOMAIN.
10  IN  PTR  hq-cli.$DOMAIN.
EOF

    systemctl restart bind9
    systemctl enable bind9

    cat > /etc/chrony/chrony.conf <<EOF
server $HQ_RTR_V10 iburst
makestep 1 3
EOF
    systemctl restart chrony

    force_dns "127.0.0.1"
    log_succ "HQ-SRV: Базовая сеть, SSH и DNS развернуты!"
}

setup_brsrv() {
    set_hostname_and_time "br-srv.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс в LAN: " INT_LAN

    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_LAN:
      optional: true
      addresses: [$BR_SRV_IP/28]
      routes:
        - to: default
          via: $BR_RTR_LAN
EOF
    apply_netplan
    prepare_apt

    apt-get install -y -q chrony
    create_sshuser

    cat > /etc/chrony/chrony.conf <<EOF
server $GRE_HQ iburst
server $HQ_RTR_V10 iburst
makestep 1 3
EOF
    systemctl restart chrony

    force_dns "$HQ_SRV_IP"
    log_succ "BR-SRV: Базовая сеть и SSH развернуты!"
}

setup_hqcli() {
    set_hostname_and_time "hq-cli.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс к HQ-RTR (Получает IP по DHCP): " INT_LAN

    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_LAN:
      optional: true
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses: [$HQ_SRV_IP]
        search: [$DOMAIN]
EOF
    apply_netplan
    prepare_apt

    apt-get install -y -q chrony

    cat > /etc/chrony/chrony.conf <<EOF
server $HQ_RTR_V20 iburst
makestep 1 3
EOF
    systemctl restart chrony

    # Полагаемся на резолвинг от нашего DNS
    force_dns "$HQ_SRV_IP"
    log_succ "HQ-CLI: Клиент настроен!"
}

# ======================== МЕНЮ ========================

clear
echo -e "${YELLOW}======================================================${NC}"
echo -e "${GREEN} ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 1 (СЕТЕВОЙ ФУНДАМЕНТ)${NC}"
echo -e "${CYAN} Включена жесткая валидация интерфейсов и защита APT${NC}"
echo -e "${YELLOW}======================================================${NC}"
echo ""
echo "Выберите роль машины:"
echo "  1) ISP     — Провайдер (Сеть + NAT)"
echo "  2) HQ-RTR  — Роутер Центра (Bridge, OSPF, DHCP, NAT)"
echo "  3) BR-RTR  — Роутер Филиала (Сеть, OSPF, NAT)"
echo "  4) HQ-SRV  — Сервер Центра (DNS Master)"
echo "  5) BR-SRV  — Сервер Филиала (Базовая сеть)"
echo "  6) HQ-CLI  — Клиент (DHCP)"
echo "  0) Выход"
echo ""
get_valid_interface "Ваш выбор (0-6): " choice
# Переопределение для меню, т.к. get_valid_interface проверяет ip link
# Сделаем ручной fallback для меню
while true; do
    read -p "Ваш выбор: " choice
    case $choice in
        1) setup_isp; break ;;
        2) setup_hqrtr; break ;;
        3) setup_brrtr; break ;;
        4) setup_hqsrv; break ;;
        5) setup_brsrv; break ;;
        6) setup_hqcli; break ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный выбор!${NC}" ;;
    esac
done

log_succ "Конфигурация Модуля 1 завершена!"