#!/bin/bash
# ==============================================================================
# ДЕМОЭКЗАМЕН 2026 (ВАРИАНТ 2) — МОДУЛЬ 1 (БАЗОВАЯ ИНФРАСТРУКТУРА)
# Особенности: Boot Hang Fix, CD-ROM APT Fix, Full Network Init, NTP Server Fix
# ==============================================================================

trap cleanup SIGINT SIGTERM

cleanup() {
    echo -e "\n\033[0;31m[ВНИМАНИЕ] Получен сигнал прерывания (SIGINT/SIGTERM).\033[0m"
    chattr -i /etc/resolv.conf 2>/dev/null || true
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

ISP_HQ_IP="172.16.30.1"
HQ_ISP_IP="172.16.30.2"
ISP_BR_IP="172.16.40.1"
BR_ISP_IP="172.16.40.2"

HQ_SRV_IP="192.168.10.2"
HQ_RTR_V112="192.168.10.1"
HQ_RTR_V212="192.168.20.1"
HQ_RTR_V812="192.168.99.1"

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
            log_err "Интерфейс '$input_int' не существует!"
        fi
    done
}

prepare_apt() {
    log_info "Очистка APT от сломанных CD-ROM репозиториев (Ubuntu 24.04 bug)..."
    sed -i '/cdrom/s/^/#/' /etc/apt/sources.list 2>/dev/null || true
    sed -i '/cdrom/s/^/#/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
    
    log_info "Блокировка фоновых обновлений Ubuntu..."
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl disable unattended-upgrades 2>/dev/null || true
    
    echo 'APT::Periodic::Enable "0";' > /etc/apt/apt.conf.d/10periodic
    echo 'APT::Periodic::Update-Package-Lists "0";' >> /etc/apt/apt.conf.d/10periodic
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        sleep 3
    done

    chattr -i /etc/resolv.conf 2>/dev/null || true
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    dpkg --configure -a 2>/dev/null || true
    apt-get update -y -q || log_err "Сбой apt-get update!"
}

set_hostname_and_time() {
    hostnamectl set-hostname "$1"
    timedatectl set-timezone Europe/Moscow
    echo "127.0.0.1 localhost" > /etc/hosts
}

show_interfaces() {
    echo -e "\n${YELLOW}Доступные интерфейсы:${NC}"
    ip -br l | awk '{print $1" - "$3}' | grep -v "lo"
}

apply_netplan() {
    chmod 600 /etc/netplan/*.yaml
    netplan apply
    sleep 3
}

force_dns() {
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo -e "nameserver $1\nsearch $DOMAIN" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
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
      dhcp4: true
    $INT_HQ:
      addresses: [$ISP_HQ_IP/28]
    $INT_BR:
      addresses: [$ISP_BR_IP/28]
EOF
    apply_netplan
    prepare_apt
    apt-get install -y -q iptables-persistent chrony

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
    sysctl -p /etc/sysctl.d/99-forward.conf

    iptables -t nat -F POSTROUTING
    iptables -t nat -A POSTROUTING -o $INT_EXT -j MASQUERADE
    iptables-save > /etc/iptables/rules.v4

    cat > /etc/chrony/chrony.conf <<EOF
pool ntp.ubuntu.com iburst maxsources 4
allow all
local stratum 7
EOF
    systemctl restart chrony
    force_dns "8.8.8.8"
    log_succ "ISP: Маршрутизация, NTP Stratum 7 и NAT настроены!"
}

setup_hqrtr() {
    set_hostname_and_time "hq-rtr.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс к ISP (WAN): " INT_ISP
    get_valid_interface "Интерфейс к HQ-SW (ТРАНК для VLAN): " INT_LAN

    systemctl mask systemd-networkd-wait-online.service

    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_ISP:
      addresses: [$HQ_ISP_IP/28]
      routes:
        - to: "0.0.0.0/0"
          via: $ISP_HQ_IP
    $INT_LAN:
      dhcp4: false
      optional: true
  vlans:
    vlan112:
      id: 112
      link: $INT_LAN
      addresses: [$HQ_RTR_V112/27]
    vlan212:
      id: 212
      link: $INT_LAN
      addresses: [$HQ_RTR_V212/27]
    vlan812:
      id: 812
      link: $INT_LAN
      addresses: [$HQ_RTR_V812/29]
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

    # КРИТИЧЕСКИЙ ФИКС КРИТЕРИЯ 2.4: Устанавливаем chrony на роутер
    apt-get install -y -q isc-dhcp-server iptables-persistent frr chrony

    id -u net_admin &>/dev/null || useradd -m -s /bin/bash net_admin
    echo 'net_admin:P@$$word' | chpasswd
    usermod -aG sudo net_admin
    echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
    sysctl -p /etc/sysctl.d/99-forward.conf

    sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"vlan212\"/" /etc/default/isc-dhcp-server
    cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
subnet 192.168.20.0 netmask 255.255.255.224 {
  range 192.168.20.10 192.168.20.30;
  option routers $HQ_RTR_V212;
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
    iptables -I FORWARD -p gre -j ACCEPT
    iptables -I INPUT -i gre1 -p ospf -j ACCEPT
    iptables -I FORWARD -i gre1 -o gre1 -p ospf -j ACCEPT
    iptables -A INPUT -p ospf -j DROP

    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 8082 -j DNAT --to-destination $HQ_SRV_IP:8082
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 2012 -j DNAT --to-destination $HQ_SRV_IP:2012

    iptables-save > /etc/iptables/rules.v4

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

    # КРИТИЧЕСКИЙ ФИКС КРИТЕРИЯ 2.4: Настройка роутера как сервера времени для сети HQ
    cat > /etc/chrony/chrony.conf <<EOF
server $ISP_HQ_IP iburst
allow 192.168.0.0/16
allow 10.0.0.0/8
makestep 1 3
EOF
    systemctl restart chrony

    force_dns "$HQ_SRV_IP"
    log_succ "HQ-RTR: ROAS, OSPF, DHCP, NTP Server и DNAT готовы!"
}

setup_hqsw() {
    set_hostname_and_time "hq-sw.$DOMAIN"
    show_interfaces
    
    log_info "HQ-SW (Коммутатор). IP-адрес ему не нужен, он работает на L2."
    get_valid_interface "Транк от HQ-RTR: " INT_TRUNK
    get_valid_interface "Access порт к HQ-SRV: " INT_SRV
    get_valid_interface "Access порт к HQ-CLI: " INT_CLI

    systemctl mask systemd-networkd-wait-online.service

    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_TRUNK:
      optional: true
    $INT_SRV:
      optional: true
    $INT_CLI:
      optional: true
  bridges:
    br0:
      interfaces: [$INT_TRUNK, $INT_SRV, $INT_CLI]
      parameters:
        stp: false
        forward-delay: 0
EOF
    apply_netplan
    prepare_apt
    apt-get install -y -q bridge-utils networkd-dispatcher

    mkdir -p /etc/networkd-dispatcher/routable.d
    cat > /etc/networkd-dispatcher/routable.d/50-switch-vlans <<EOF
#!/bin/bash
if [ "\$IFACE" = "br0" ]; then
    /sbin/bridge vlan add dev $INT_TRUNK vid 112 master
    /sbin/bridge vlan add dev $INT_TRUNK vid 212 master
    /sbin/bridge vlan add dev $INT_TRUNK vid 812 master
    /sbin/bridge vlan add dev $INT_SRV vid 112 pvid untagged master
    /sbin/bridge vlan add dev $INT_CLI vid 212 pvid untagged master
fi
EOF
    chmod +x /etc/networkd-dispatcher/routable.d/50-switch-vlans

    cat > /etc/systemd/system/bridge-vlan-filter.service <<EOF
[Unit]
Description=Enable VLAN filtering on br0
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 1 > /sys/class/net/br0/bridge/vlan_filtering'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now bridge-vlan-filter.service

    /sbin/bridge vlan add dev $INT_TRUNK vid 112 master 2>/dev/null || true
    /sbin/bridge vlan add dev $INT_TRUNK vid 212 master 2>/dev/null || true
    /sbin/bridge vlan add dev $INT_TRUNK vid 812 master 2>/dev/null || true
    /sbin/bridge vlan add dev $INT_SRV vid 112 pvid untagged master 2>/dev/null || true
    /sbin/bridge vlan add dev $INT_CLI vid 212 pvid untagged master 2>/dev/null || true

    log_succ "HQ-SW: Виртуальный L2-коммутатор (VLAN 112/212/812) запущен надежно!"
}

setup_brrtr() {
    set_hostname_and_time "br-rtr.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс к ISP: " INT_ISP
    get_valid_interface "Интерфейс в LAN (к BR-SRV): " INT_LAN

    systemctl mask systemd-networkd-wait-online.service

    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_ISP:
      addresses: [$BR_ISP_IP/28]
      routes:
        - to: "0.0.0.0/0"
          via: $ISP_BR_IP
    $INT_LAN:
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

    id -u net_admin &>/dev/null || useradd -m -s /bin/bash net_admin
    echo 'net_admin:P@$$word' | chpasswd
    usermod -aG sudo net_admin
    echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
    sysctl -p /etc/sysctl.d/99-forward.conf

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

    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 8082 -j DNAT --to-destination $BR_SRV_IP:8082
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 2026 -j DNAT --to-destination $BR_SRV_IP:2026

    iptables-save > /etc/iptables/rules.v4

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

    # Симметричная настройка сервера времени для сети BR
    cat > /etc/chrony/chrony.conf <<EOF
server $ISP_BR_IP iburst
allow 192.168.0.0/16
allow 10.0.0.0/8
makestep 1 3
EOF
    systemctl restart chrony

    force_dns "$HQ_SRV_IP"
    log_succ "BR-RTR: Сеть, NAT, OSPF, NTP Server и DNAT настроены!"
}

setup_hqsrv() {
    set_hostname_and_time "hq-srv.$DOMAIN"
    echo "$HQ_SRV_IP hq-srv.$DOMAIN hq-srv" >> /etc/hosts

    show_interfaces
    get_valid_interface "Интерфейс к HQ-SW (Access VLAN 112): " INT_LAN

    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_LAN:
      addresses: [$HQ_SRV_IP/27]
      routes:
        - to: "0.0.0.0/0"
          via: $HQ_RTR_V112
EOF
    apply_netplan
    prepare_apt

    apt-get install -y -q chrony openssh-server

    id -u sshuser &>/dev/null || useradd -m -s /bin/bash -u 2012 sshuser
    echo "sshuser:P@ssw0rd" | chpasswd
    usermod -aG sudo sshuser
    echo "sshuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser

    echo "Authorized access only" > /etc/issue.net
    sed -i 's/^#*Port .*/Port 2012/' /etc/ssh/sshd_config
    sed -i 's/^#*Banner .*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
    sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 2/' /etc/ssh/sshd_config
    echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    systemctl restart ssh

    cat > /etc/chrony/chrony.conf <<EOF
server $ISP_HQ_IP iburst
makestep 1 3
EOF
    systemctl restart chrony

    force_dns "127.0.0.1"
    log_succ "HQ-SRV: Сеть, SSH (Port 2012) и NTP готовы!"
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
      addresses: [$BR_SRV_IP/28]
      routes:
        - to: "0.0.0.0/0"
          via: $BR_RTR_LAN
EOF
    apply_netplan
    prepare_apt

    apt-get install -y -q chrony openssh-server

    id -u sshuser &>/dev/null || useradd -m -s /bin/bash -u 2012 sshuser
    echo "sshuser:P@ssw0rd" | chpasswd
    usermod -aG sudo sshuser
    echo "sshuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser

    echo "Authorized access only" > /etc/issue.net
    sed -i 's/^#*Port .*/Port 2026/' /etc/ssh/sshd_config
    sed -i 's/^#*Banner .*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
    sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 2/' /etc/ssh/sshd_config
    echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    systemctl restart ssh

    cat > /etc/chrony/chrony.conf <<EOF
server $ISP_BR_IP iburst
makestep 1 3
EOF
    systemctl restart chrony

    force_dns "$HQ_SRV_IP"
    log_succ "BR-SRV: Сеть, SSH (Port 2026) и NTP готовы!"
}

setup_hqcli() {
    set_hostname_and_time "hq-cli.$DOMAIN"
    show_interfaces
    
    get_valid_interface "Интерфейс к HQ-SW (Получает IP по DHCP): " INT_LAN

    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_LAN:
      dhcp4: true
EOF
    apply_netplan

    log_info "Ожидание получения IP по DHCP..."
    for i in {1..15}; do
        if ip route show | grep -q default; then break; fi
        sleep 2
    done

    prepare_apt
    apt-get install -y -q chrony
    
    cat > /etc/chrony/chrony.conf <<EOF
server $ISP_HQ_IP iburst
makestep 1 3
EOF
    systemctl restart chrony

    log_succ "HQ-CLI: DHCP и NTP настроены!"
}

clear
echo -e "${YELLOW}======================================================${NC}"
echo -e "${GREEN} ДЕМОЭКЗАМЕН 2026 (В2) — МОДУЛЬ 1 (СЕТЕВОЙ ФУНДАМЕНТ)${NC}"
echo -e "${CYAN} All Nodes Support, Boot Hang Fix, Ubuntu CD-ROM Fix${NC}"
echo -e "${YELLOW}======================================================${NC}"
echo ""
echo "Выберите роль машины:"
echo "  1) ISP     — Провайдер (Сеть + NAT + NTP Master 7)"
echo "  2) HQ-RTR  — Роутер Центра (ROAS, OSPF, DHCP, DNAT, NTP Server)"
echo "  3) HQ-SW   — Коммутатор Центра (L2 Bridge + VLAN Tags)"
echo "  4) BR-RTR  — Роутер Филиала (Сеть, OSPF, DNAT, NTP Server)"
echo "  5) HQ-SRV  — Сервер Центра (Базовая сеть, SSH 2012)"
echo "  6) BR-SRV  — Сервер Филиала (Базовая сеть, SSH 2026)"
echo "  7) HQ-CLI  — Клиент (Чистый DHCP)"
echo "  0) Выход"
echo ""

while true; do
    read -p "Ваш выбор: " choice
    case $choice in
        1) setup_isp; break ;;
        2) setup_hqrtr; break ;;
        3) setup_hqsw; break ;;
        4) setup_brrtr; break ;;
        5) setup_hqsrv; break ;;
        6) setup_brsrv; break ;;
        7) setup_hqcli; break ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный выбор!${NC}" ;;
    esac
done

log_succ "Конфигурация Модуля 1 завершена! Переходите к установке сервисов (Модуль 2)."
