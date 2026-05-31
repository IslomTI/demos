#!/bin/bash
# ==============================================================================
# ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 1 (БАЗОВАЯ ИНФРАСТРУКТУРА)
# Целевая ОС: Ubuntu 22.04 / 24.04 LTS
# Особенности: carrier.d PVID Fix, OSPF Anti-Spoofing, Safe APT Trap
# ==============================================================================

trap cleanup SIGINT SIGTERM

cleanup() {
    echo -e "\n\033[0;31m[ВНИМАНИЕ] Получен сигнал прерывания (SIGINT/SIGTERM).\033[0m"
    echo -e "\033[0;33m[INFO] Восстанавливаю атрибуты файлов...\033[0m"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    echo -e "\033[0;31m[ФАТАЛЬНО] Остановка выполнения. DPKG блокировки НЕ снимаются принудительно для защиты базы пакетов. Если APT завис, дождитесь его завершения или выполните 'dpkg --configure -a'.\033[0m"
    
    kill -TERM -$$ 2>/dev/null
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

log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_succ() { echo -e "${GREEN}[УСПЕХ] $1${NC}"; }
log_err()  { echo -e "${RED}[ОШИБКА] $1${NC}"; }

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

prepare_apt() {
    log_info "Проверка связности с Интернетом (через DNS)..."
    if ! getent ahosts archive.ubuntu.com >/dev/null 2>&1; then
        log_err "Внимание! Возможны проблемы с разрешением имен или маршрутизацией."
    fi

    log_info "Блокировка фоновых обновлений Ubuntu (unattended-upgrades)..."
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl disable unattended-upgrades 2>/dev/null || true
    
    log_info "Ожидание освобождения блокировок DPKG/APT..."
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        log_info "APT занят другим процессом. Ожидание 3 секунды..."
        sleep 3
    done

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
    apt-get update -y -q || log_err "apt-get update вернул ошибку, проверьте доступность архивов!"
}

set_hostname_and_time() {
    log_info "Установка имени $1 и часового пояса..."
    hostnamectl set-hostname "$1"
    timedatectl set-timezone Europe/Moscow
    cat > /etc/hosts <<EOF
127.0.0.1 localhost
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
    
    log_info "Фиксация SSH службы для обхода ssh.socket..."
    systemctl disable --now ssh.socket 2>/dev/null || true
    systemctl enable --now ssh.service 2>/dev/null || true
    systemctl restart ssh.service || systemctl restart ssh || true
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
    
    log_info "Настройка проброса портов (DNAT) для SSH (3015 -> HQ-SRV, 3016 -> BR-SRV)..."
    iptables -t nat -A PREROUTING -i $INT_EXT -p tcp --dport 3015 -j DNAT --to-destination $HQ_ISP_IP:3015
    iptables -t nat -A PREROUTING -i $INT_EXT -p tcp --dport 3016 -j DNAT --to-destination $BR_ISP_IP:3015
    
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    force_dns "8.8.8.8"
    log_succ "ISP: Маршрутизация, NAT и DNAT для SSH настроены!"
}

setup_hqrtr() {
    set_hostname_and_time "hq-rtr.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс к ISP (WAN): " INT_ISP
    get_valid_interface "Интерфейс к HQ-SRV (Access VLAN 10): " INT_LAN_SRV
    get_valid_interface "Интерфейс к HQ-CLI (Access VLAN 20): " INT_LAN_CLI

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
        - to: "0.0.0.0/0"
          via: $ISP_HQ_IP
    $INT_LAN_SRV:
      optional: true
      dhcp4: false
    $INT_LAN_CLI:
      optional: true
      dhcp4: false
  bridges:
    br0:
      interfaces: [$INT_LAN_SRV, $INT_LAN_CLI]
      parameters:
        stp: false
        forward-delay: 0
      vlan-filtering: true
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

    apt-get install -y -q isc-dhcp-server iptables-persistent frr chrony iproute2 bridge-utils networkd-dispatcher

    log_info "Настройка триггеров PVID для физических портов моста br0 (carrier.d)..."
    mkdir -p /etc/networkd-dispatcher/carrier.d
    cat > /etc/networkd-dispatcher/carrier.d/50-vlan-pvid <<EOF
#!/bin/bash
if [ "\$IFACE" = "$INT_LAN_SRV" ]; then
    /sbin/bridge vlan add dev $INT_LAN_SRV vid 10 pvid untagged master
elif [ "\$IFACE" = "$INT_LAN_CLI" ]; then
    /sbin/bridge vlan add dev $INT_LAN_CLI vid 20 pvid untagged master
fi
EOF
    chmod +x /etc/networkd-dispatcher/carrier.d/50-vlan-pvid

    /sbin/bridge vlan add dev $INT_LAN_SRV vid 10 pvid untagged master 2>/dev/null || true
    /sbin/bridge vlan add dev $INT_LAN_CLI vid 20 pvid untagged master 2>/dev/null || true

    create_netadmin

    log_info "Загрузка модуля br_netfilter для предотвращения ошибок sysctl..."
    modprobe br_netfilter 2>/dev/null || true
    echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf

    cat > /etc/sysctl.d/99-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-arptables=0
EOF
    sysctl -p /etc/sysctl.d/99-forward.conf
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f" 2>/dev/null || true; done

    sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"vlan20\"/" /etc/default/isc-dhcp-server
    
    cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
subnet 192.168.20.0 netmask 255.255.255.224 {
  range 192.168.20.10 192.168.20.30;
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

    log_info "Блокировка маршрутизации пользовательского трафика в VLAN 99 с поддержкой conntrack..."
    iptables -I FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -i vlan10 -o vlan99 -m conntrack --ctstate NEW -j DROP
    iptables -A FORWARD -i vlan20 -o vlan99 -m conntrack --ctstate NEW -j DROP
    iptables -A FORWARD -i gre1 -o vlan99 -m conntrack --ctstate NEW -j DROP

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    
    iptables -I INPUT -p gre -j ACCEPT
    iptables -I FORWARD -p gre -j ACCEPT
    iptables -I INPUT -i gre1 -p ospf -j ACCEPT
    iptables -I FORWARD -i gre1 -o gre1 -p ospf -j ACCEPT
    iptables -A INPUT -p ospf -j DROP

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
        - to: "0.0.0.0/0"
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
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f" 2>/dev/null || true; done

    iptables -F
    iptables -t nat -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    
    iptables -I INPUT -p gre -j ACCEPT
    iptables -I FORWARD -p gre -j ACCEPT
    iptables -I INPUT -i gre1 -p ospf -j ACCEPT
    iptables -I FORWARD -i gre1 -o gre1 -p ospf -j ACCEPT
    iptables -A INPUT -p ospf -j DROP

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
    log_succ "BR-RTR: Сеть, NAT и безопасный OSPF настроены!"
}

setup_hqsrv() {
    set_hostname_and_time "hq-srv.$DOMAIN"
    echo "$HQ_SRV_IP hq-srv.$DOMAIN hq-srv" >> /etc/hosts

    show_interfaces
    get_valid_interface "Интерфейс, смотрящий в HQ-RTR: " INT_LAN

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
        - to: "0.0.0.0/0"
          via: $HQ_RTR_V10
EOF
    apply_netplan
    prepare_apt

    apt-get install -y -q bind9 bind9-utils chrony
    create_sshuser

    cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";
    forwarders { 8.8.8.8; };
    dnssec-validation no;
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
zone "_tcp.$DOMAIN" { type forward; forward only; forwarders { $BR_SRV_IP; }; };
zone "_udp.$DOMAIN" { type forward; forward only; forwarders { $BR_SRV_IP; }; };
zone "_msdcs.$DOMAIN" { type forward; forward only; forwarders { $BR_SRV_IP; }; };
zone "_sites.$DOMAIN" { type forward; forward only; forwarders { $BR_SRV_IP; }; };
EOF

    cat > /etc/bind/db.forward <<EOF
\$TTL 604800
@       IN  SOA   hq-srv.$DOMAIN. admin.$DOMAIN. (
                  4 604800 86400 2419200 604800 )
@       IN  NS    hq-srv.$DOMAIN.
@       IN  A     $BR_SRV_IP
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
    log_succ "HQ-SRV: Базовая сеть, SSH и Master DNS (с делегированием AD) развернуты!"
}

setup_brsrv() {
    set_hostname_and_time "br-srv.$DOMAIN"
    echo "$BR_SRV_IP br-srv.$DOMAIN br-srv" >> /etc/hosts

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
        - to: "0.0.0.0/0"
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
EOF
    
    log_info "Применение конфигурации Netplan..."
    chmod 600 /etc/netplan/*.yaml
    netplan apply

    log_info "Ожидание получения IP и маршрутов по DHCP..."
    for i in {1..15}; do
        if ip route show | grep -q default; then
            log_succ "DHCP аренда получена!"
            break
        fi
        sleep 2
    done

    log_info "Проверка связности DNS (ожидание разрешения имен от HQ-SRV)..."
    for i in {1..20}; do
        if getent ahosts archive.ubuntu.com >/dev/null 2>&1; then
            log_succ "DNS-резолвинг функционирует корректно."
            break
        fi
        sleep 3
    done

    log_info "Подготовка подсистемы APT через нативный DNS от DHCP..."
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    dpkg --configure -a 2>/dev/null || true
    apt-get update -y -q || log_err "apt-get update вернул ошибку, проверьте DNS на HQ-SRV!"

    apt-get install -y -q chrony dnsutils

    cat > /etc/chrony/chrony.conf <<EOF
server $HQ_RTR_V20 iburst
makestep 1 3
EOF
    systemctl restart chrony

    log_succ "HQ-CLI: Нативный клиент настроен. Сеть и разрешение имен работают штатно!"
}

# ======================== МЕНЮ ========================

clear
echo -e "${YELLOW}======================================================${NC}"
echo -e "${GREEN} ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 1 (СЕТЕВОЙ ФУНДАМЕНТ)${NC}"
echo -e "${CYAN} Production-Ready: Clean Syntax, carrier.d Bridge, Safe Trap${NC}"
echo -e "${YELLOW}======================================================${NC}"
echo ""
echo "Выберите роль машины:"
echo "  1) ISP     — Провайдер (Сеть + NAT + SSH DNAT)"
echo "  2) HQ-RTR  — Роутер Центра (Bridge, OSPF, DHCP, NAT, VLAN 99 ACL)"
echo "  3) BR-RTR  — Роутер Филиала (Сеть, OSPF, NAT)"
echo "  4) HQ-SRV  — Сервер Центра (DNS Master + AD Delegation)"
echo "  5) BR-SRV  — Сервер Филиала (Базовая сеть)"
echo "  6) HQ-CLI  — Клиент (Чистый DHCP)"
echo "  0) Выход"
echo ""

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