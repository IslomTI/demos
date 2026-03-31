#!/bin/bash
# ==============================================================================
# ДЕМОЭКЗАМЕН 2025 - МОДУЛЬ 1 (v9 - Бронебойный Netplan & Unicast OSPF)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mЗапустите скрипт от root (через sudo su)!\e[0m"
  exit 1
fi

GREEN='\033[0;32m'
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

echo -e "${CYAN}=== Подготовка системы ===${NC}"
rm -rf /var/lib/apt/lists/* /var/lib/dpkg/lock* /var/cache/apt/archives/lock
dpkg --configure -a 2>/dev/null || true

# Снимаем защиту с resolv.conf, если она была
chattr -i /etc/resolv.conf 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q || true

# --- ОБЩИЕ ФУНКЦИИ ---

set_hostname_and_time() {
    hostnamectl set-hostname "$1"
    timedatectl set-timezone Europe/Moscow
    echo "127.0.0.1 localhost" > /etc/hosts
    echo "127.0.0.1 $1 ${1%%.*}" >> /etc/hosts
}

show_interfaces() {
    echo -e "\n${YELLOW}Доступные сетевые интерфейсы:${NC}"
    ip -br l | awk '{print $1}' | grep -v "lo"
}

apply_netplan() {
    chmod 600 /etc/netplan/*.yaml
    netplan apply
    sleep 3
}

force_dns() {
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver $1" > /etc/resolv.conf
    echo "search $DOMAIN" >> /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
}

create_sshuser() {
    id -u sshuser &>/dev/null || useradd -m -s /bin/bash -u 1015 sshuser
    echo "sshuser:P@ssw0rd" | chpasswd
    usermod -aG sudo sshuser
    echo "sshuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser
    
    echo "Authorized access only" > /etc/issue.net
    apt-get install -y -q openssh-server || true
    
    sed -i 's/^#*Port 22/Port 3015/' /etc/ssh/sshd_config
    sed -i 's/^#*Banner .*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
    sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 2/' /etc/ssh/sshd_config
    grep -q "AllowUsers sshuser" /etc/ssh/sshd_config || echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    systemctl restart ssh || systemctl restart sshd || true
}

create_netadmin() {
    id -u net_admin &>/dev/null || useradd -m -s /bin/bash net_admin
    echo "net_admin:P@\$\$w0rd" | chpasswd
    usermod -aG sudo net_admin
    echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
}

# ==============================================================================

setup_isp() {
    set_hostname_and_time "isp.$DOMAIN"
    show_interfaces
    read -p "Интерфейс в ИНТЕРНЕТ (NAT DHCP): " INT_EXT
    read -p "Интерфейс к HQ-RTR: " INT_HQ
    read -p "Интерфейс к BR-RTR: " INT_BR

    apt-get install -y -q iptables-persistent

    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
network:
  version: 2
  ethernets:
    $INT_EXT: {optional: true, dhcp4: true}
    $INT_HQ: {optional: true, addresses: [$ISP_HQ_IP/28]}
    $INT_BR: {optional: true, addresses: [$ISP_BR_IP/28]}
EOF
    apply_netplan

    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    iptables -t nat -A POSTROUTING -o $INT_EXT -j MASQUERADE
    
    ip route add 192.168.10.0/24 via $HQ_ISP_IP 2>/dev/null || true
    ip route add 192.168.20.0/24 via $HQ_ISP_IP 2>/dev/null || true
    ip route add 192.168.30.0/24 via $BR_ISP_IP 2>/dev/null || true

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    force_dns "8.8.8.8"
    echo -e "${GREEN}[УСПЕХ] ISP настроен!${NC}"
}

setup_hqrtr() {
    set_hostname_and_time "hq-rtr.$DOMAIN"
    create_netadmin
    show_interfaces
    read -p "Интерфейс к ISP: " INT_ISP
    read -p "Интерфейс ВНУТРЬ (VLAN 10, 20, 99): " INT_LAN

    apt-get install -y -q isc-dhcp-server iptables-persistent frr

    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
network:
  version: 2
  ethernets:
    $INT_ISP:
      optional: true
      addresses: [$HQ_ISP_IP/28]
      routes: [{to: default, via: $ISP_HQ_IP}]
    $INT_LAN: {optional: true, dhcp4: false}
  vlans:
    vlan10: {id: 10, link: $INT_LAN, addresses: [$HQ_RTR_V10/27]}
    vlan20: {id: 20, link: $INT_LAN, addresses: [$HQ_RTR_V20/27]}
    vlan99: {id: 99, link: $INT_LAN, addresses: [$HQ_RTR_V99/29]}
  tunnels:
    gre1: {mode: gre, local: $HQ_ISP_IP, remote: $BR_ISP_IP, addresses: [$GRE_HQ/30], mtu: 1400}
EOF
    apply_netplan

    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $f; done
    sed -i 's/rp_filter=1/rp_filter=0/g' /etc/sysctl.conf
    sysctl -p

    sed -i "s/INTERFACESv4=.*/INTERFACESv4=\"vlan20\"/" /etc/default/isc-dhcp-server
    cat <<EOF > /etc/dhcp/dhcpd.conf
authoritative;
subnet 192.168.20.0 netmask 255.255.255.224 {
  range 192.168.20.10 192.168.20.30;
  option routers $HQ_RTR_V20;
  option domain-name-servers $HQ_SRV_IP;
  option domain-name "$DOMAIN";
}
EOF
    systemctl restart isc-dhcp-server || true

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -I INPUT -p ospf -j ACCEPT
    iptables -I FORWARD -p ospf -j ACCEPT
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # ЖЕСТКИЙ ФИКС OSPF
    ip route flush cache
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl restart frr
    sleep 3
    vtysh <<EOF
conf t
interface gre1
 ip ospf network non-broadcast
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
exit
router ospf
 ospf router-id 1.1.1.1
 network 10.0.0.0/30 area 0
 network 192.168.10.0/27 area 0
 network 192.168.20.0/27 area 0
 network 192.168.99.0/29 area 0
 neighbor 10.0.0.2
 passive-interface default
 no passive-interface gre1
end
write
EOF

    force_dns "$HQ_SRV_IP"
    echo -e "${GREEN}[УСПЕХ] HQ-RTR настроен!${NC}"
}

setup_brrtr() {
    set_hostname_and_time "br-rtr.$DOMAIN"
    create_netadmin
    show_interfaces
    read -p "Интерфейс к ISP: " INT_ISP
    read -p "Интерфейс в LAN BR-SRV: " INT_LAN

    apt-get install -y -q iptables-persistent frr

    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
network:
  version: 2
  ethernets:
    $INT_ISP:
      optional: true
      addresses: [$BR_ISP_IP/28]
      routes: [{to: default, via: $ISP_BR_IP}]
    $INT_LAN: {optional: true, addresses: [$BR_RTR_LAN/28]}
  tunnels:
    gre1: {mode: gre, local: $BR_ISP_IP, remote: $HQ_ISP_IP, addresses: [$GRE_BR/30], mtu: 1400}
EOF
    apply_netplan

    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $f; done
    sed -i 's/rp_filter=1/rp_filter=0/g' /etc/sysctl.conf
    sysctl -p

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -I INPUT -p ospf -j ACCEPT
    iptables -I FORWARD -p ospf -j ACCEPT
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # ЖЕСТКИЙ ФИКС OSPF
    ip route flush cache
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl restart frr
    sleep 3
    vtysh <<EOF
conf t
interface gre1
 ip ospf network non-broadcast
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
exit
router ospf
 ospf router-id 2.2.2.2
 network 10.0.0.0/30 area 0
 network 192.168.30.0/28 area 0
 neighbor 10.0.0.1
 passive-interface default
 no passive-interface gre1
end
write
EOF

    force_dns "$HQ_SRV_IP"
    echo -e "${GREEN}[УСПЕХ] BR-RTR настроен!${NC}"
}

setup_hqsrv() {
    set_hostname_and_time "hq-srv.$DOMAIN"
    create_sshuser
    show_interfaces
    read -p "Интерфейс: " INT_LAN

    apt-get install -y -q bind9 bind9utils

    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
network:
  version: 2
  ethernets:
    $INT_LAN: {optional: true, dhcp4: false}
  vlans:
    vlan10: {id: 10, link: $INT_LAN, addresses: [$HQ_SRV_IP/27], routes: [{to: default, via: $HQ_RTR_V10}]}
EOF
    apply_netplan

    cat <<EOF > /etc/bind/named.conf.options
options { directory "/var/cache/bind"; forwarders { 8.8.8.8; }; dnssec-validation auto; listen-on-v6 { any; }; allow-query { any; }; };
EOF
    cat <<EOF > /etc/bind/named.conf.local
zone "$DOMAIN" { type master; file "/etc/bind/db.forward"; };
zone "10.168.192.in-addr.arpa" { type master; file "/etc/bind/db.rev10"; };
zone "20.168.192.in-addr.arpa" { type master; file "/etc/bind/db.rev20"; };
EOF

    cat <<EOF > /etc/bind/db.forward
\$TTL 604800
@ IN SOA hq-srv.$DOMAIN. admin.$DOMAIN. ( 2 604800 86400 2419200 604800 )
@ IN NS hq-srv.$DOMAIN.
hq-rtr IN A $HQ_RTR_V10
br-rtr IN A $BR_RTR_LAN
hq-srv IN A $HQ_SRV_IP
hq-cli IN A 192.168.20.10
br-srv IN A $BR_SRV_IP
moodle IN A $ISP_HQ_IP
wiki   IN A $ISP_BR_IP
EOF

    cat <<EOF > /etc/bind/db.rev10
\$TTL 604800
@ IN SOA hq-srv.$DOMAIN. admin.$DOMAIN. ( 2 604800 86400 2419200 604800 )
@ IN NS hq-srv.$DOMAIN.
1 IN PTR hq-rtr.$DOMAIN.
2 IN PTR hq-srv.$DOMAIN.
EOF

    cat <<EOF > /etc/bind/db.rev20
\$TTL 604800
@ IN SOA hq-srv.$DOMAIN. admin.$DOMAIN. ( 2 604800 86400 2419200 604800 )
@ IN NS hq-srv.$DOMAIN.
10 IN PTR hq-cli.$DOMAIN.
EOF

    systemctl restart bind9
    force_dns "127.0.0.1"
    
    echo -e "${GREEN}[УСПЕХ] HQ-SRV настроен (DNS + SSH)!${NC}"
}

setup_brsrv() {
    set_hostname_and_time "br-srv.$DOMAIN"
    create_sshuser
    show_interfaces
    read -p "Интерфейс: " INT_LAN

    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
network:
  version: 2
  ethernets:
    $INT_LAN: {optional: true, addresses: [$BR_SRV_IP/28], routes: [{to: default, via: $BR_RTR_LAN}]}
EOF
    apply_netplan

    force_dns "$HQ_SRV_IP"
    echo -e "${GREEN}[УСПЕХ] BR-SRV настроен (Базовая сеть + SSH)!${NC}"
}

setup_hqcli() {
    set_hostname_and_time "hq-cli.$DOMAIN"
    show_interfaces
    read -p "Интерфейс: " INT_LAN

    # АБСОЛЮТНЫЙ ФИКС DNS В NETPLAN ДЛЯ КЛИЕНТА
    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
network:
  version: 2
  ethernets:
    $INT_LAN: {optional: true, dhcp4: false}
  vlans:
    vlan20:
      id: 20
      link: $INT_LAN
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses: [$HQ_SRV_IP]
        search: [$DOMAIN]
EOF
    
    # Защита от всех системных служб
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver $HQ_SRV_IP" > /etc/resolv.conf
    echo "search $DOMAIN" >> /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true

    apply_netplan

    echo -e "${GREEN}[УСПЕХ] HQ-CLI настроен (Получает IP по DHCP, DNS зафиксирован жестко)!${NC}"
}

clear
echo -e "${YELLOW}=================================================${NC}"
echo -e "${GREEN} ДЕМОЭКЗАМЕН 2025 - МОДУЛЬ 1 (БРОНЕБОЙНЫЙ)${NC}"
echo -e "${YELLOW}=================================================${NC}"
echo "Выберите роль машины:"
echo "1) ISP     (Провайдер)"
echo "2) HQ-RTR  (Роутер Центра)"
echo "3) BR-RTR  (Роутер Филиала)"
echo "4) HQ-SRV  (Сервер Центра - DNS)"
echo "5) BR-SRV  (Сервер Филиала)"
echo "6) HQ-CLI  (Клиент)"
echo "0) Выход"
echo -n "Ваш выбор: "
read choice

case $choice in
    1) setup_isp ;;
    2) setup_hqrtr ;;
    3) setup_brrtr ;;
    4) setup_hqsrv ;;
    5) setup_brsrv ;;
    6) setup_hqcli ;;
    0) echo "Выход."; exit 0 ;;
    *) echo -e "${RED}Ошибка: Неверный выбор!${NC}"; exit 1 ;;
esac

echo -e "\n${YELLOW}Установка завершена!${NC}"
