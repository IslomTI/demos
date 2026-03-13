#!/bin/bash
# ==============================================================================
# Master Script - Демонстрационный экзамен 09.02.06 (Сетевое администрирование)
# Поддержка ОС: Ubuntu 22.04 / 24.04
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mПожалуйста, запустите скрипт от пользователя root (sudo su).\e[0m"
  exit
fi

# Цвета для вывода
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Глобальные переменные IP (Расчет по заданию)
DOMAIN="au-team.irpo"
REALM="AU-TEAM.IRPO"

ISP_HQ_NET="172.16.40.0/28"
ISP_HQ_IP="172.16.40.1"
HQ_ISP_IP="172.16.40.2"

ISP_BR_NET="172.16.50.0/28"
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

# === ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ===

show_interfaces() {
    echo -e "${CYAN}Доступные сетевые интерфейсы:${NC}"
    ip -br l | awk '{print $1}' | grep -v "lo"
}

set_hostname_tz() {
    hostnamectl set-hostname "$1"
    timedatectl set-timezone Europe/Moscow
    echo -e "${GREEN}Hostname задан: $1. Часовой пояс: MSK.${NC}"
}

backup_netplan() {
    mkdir -p /etc/netplan/backup
    mv /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null
}

apply_sysctl_forwarding() {
    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sysctl -p
}

create_sshuser() {
    echo -e "${CYAN}Создание sshuser...${NC}"
    useradd -m -s /bin/bash -u 1015 sshuser
    echo "sshuser:P@ssw0rd" | chpasswd
    usermod -aG sudo sshuser
    echo "sshuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser
    
    echo "Authorized access only" > /etc/issue.net
    sed -i 's/#Port 22/Port 3015/' /etc/ssh/sshd_config
    sed -i 's/#Banner none/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
    sed -i 's/#MaxAuthTries 6/MaxAuthTries 2/' /etc/ssh/sshd_config
    echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    systemctl restart sshd
}

create_netadmin() {
    echo -e "${CYAN}Создание net_admin...${NC}"
    useradd -m -s /bin/bash net_admin
    echo "net_admin:P@\$\$w0rd" | chpasswd
    usermod -aG sudo net_admin
    echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
}

# ==============================================================================
# НАСТРОЙКА УСТРОЙСТВ
# ==============================================================================

setup_isp() {
    set_hostname_tz "isp.$DOMAIN"
    
    show_interfaces
    read -p "Введите интерфейс, смотрящий в ИНТЕРНЕТ (NAT): " INT_EXT
    read -p "Введите интерфейс, смотрящий на HQ-RTR: " INT_HQ
    read -p "Введите интерфейс, смотрящий на BR-RTR: " INT_BR

    backup_netplan
    cat <<EOF > /etc/netplan/01-isp.yaml
network:
  version: 2
  ethernets:
    $INT_EXT:
      dhcp4: true
    $INT_HQ:
      addresses: [$ISP_HQ_IP/28]
    $INT_BR:
      addresses: [$ISP_BR_IP/28]
EOF
    netplan apply
    apply_sysctl_forwarding

    echo -e "${CYAN}Настройка NAT и Nginx...${NC}"
    apt update && DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent nginx
    iptables -t nat -A POSTROUTING -o $INT_EXT -j MASQUERADE
    iptables-save > /etc/iptables/rules.v4

    cat <<EOF > /etc/nginx/sites-available/default
server {
    listen 80;
    server_name moodle.$DOMAIN;
    location / { proxy_pass http://$HQ_ISP_IP:80; }
}
server {
    listen 80;
    server_name wiki.$DOMAIN;
    location / { proxy_pass http://$BR_ISP_IP:8086; }
}
EOF
    systemctl restart nginx
    echo -e "${GREEN}ISP Настроен!${NC}"
}

setup_hqrtr() {
    set_hostname_tz "hq-rtr.$DOMAIN"
    create_netadmin
    
    show_interfaces
    read -p "Введите интерфейс, смотрящий на ISP: " INT_ISP
    read -p "Введите интерфейс, смотрящий ВНУТРЬ (в сторону коммутатора): " INT_LAN

    backup_netplan
    cat <<EOF > /etc/netplan/01-hqrtr.yaml
network:
  version: 2
  ethernets:
    $INT_ISP:
      addresses: [$HQ_ISP_IP/28]
      routes:
        - to: default
          via: $ISP_HQ_IP
    $INT_LAN:
      dhcp4: false
  vlans:
    vlan10:
      id: 10
      link: $INT_LAN
      addresses: [$HQ_RTR_V10/27]
    vlan20:
      id: 20
      link: $INT_LAN
      addresses: [$HQ_RTR_V20/27]
    vlan99:
      id: 99
      link: $INT_LAN
      addresses: [$HQ_RTR_V99/29]
  tunnels:
    gre1:
      mode: gre
      local: $HQ_ISP_IP
      remote: $BR_ISP_IP
      addresses: [$GRE_HQ/30]
EOF
    netplan apply
    apply_sysctl_forwarding

    echo -e "${CYAN}Настройка DHCP, NAT, FRR, Chrony...${NC}"
    apt update && DEBIAN_FRONTEND=noninteractive apt install -y isc-dhcp-server iptables-persistent frr chrony

    # DHCP
    sed -i 's/INTERFACESv4=""/INTERFACESv4="vlan20"/' /etc/default/isc-dhcp-server
    cat <<EOF >> /etc/dhcp/dhcpd.conf
subnet 192.168.20.0 netmask 255.255.255.224 {
  range 192.168.20.10 192.168.20.30;
  option routers $HQ_RTR_V20;
  option domain-name-servers $HQ_SRV_IP;
  option domain-name "$DOMAIN";
}
EOF
    systemctl restart isc-dhcp-server

    # NAT & Port Forwarding
    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -t nat -A PREROUTING -p tcp -i $INT_ISP --dport 80 -j DNAT --to-destination $HQ_SRV_IP:80
    iptables -t nat -A PREROUTING -p tcp -i $INT_ISP --dport 3015 -j DNAT --to-destination $HQ_SRV_IP:3015
    iptables-save > /etc/iptables/rules.v4

    # OSPF (FRR)
    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl restart frr
    vtysh -c "conf t" \
          -c "router ospf" \
          -c "network 10.0.0.0/30 area 0" \
          -c "network 192.168.10.0/27 area 0" \
          -c "network 192.168.20.0/27 area 0" \
          -c "exit" \
          -c "interface gre1" \
          -c "ip ospf authentication message-digest" \
          -c "ip ospf message-digest-key 1 md5 P@ssw0rd" \
          -c "exit" -c "write"

    # NTP Server
    sed -i '/pool/d' /etc/chrony/chrony.conf
    echo "local stratum 5" >> /etc/chrony/chrony.conf
    echo "allow 192.168.0.0/16" >> /etc/chrony/chrony.conf
    echo "allow 10.0.0.0/8" >> /etc/chrony/chrony.conf
    systemctl restart chronyd

    echo -e "${GREEN}HQ-RTR Настроен!${NC}"
}

setup_brrtr() {
    set_hostname_tz "br-rtr.$DOMAIN"
    create_netadmin
    
    show_interfaces
    read -p "Введите интерфейс, смотрящий на ISP: " INT_ISP
    read -p "Введите интерфейс, смотрящий ВНУТРЬ (LAN BR): " INT_LAN

    backup_netplan
    cat <<EOF > /etc/netplan/01-brrtr.yaml
network:
  version: 2
  ethernets:
    $INT_ISP:
      addresses: [$BR_ISP_IP/28]
      routes:
        - to: default
          via: $ISP_BR_IP
    $INT_LAN:
      addresses: [$BR_RTR_LAN/28]
  tunnels:
    gre1:
      mode: gre
      local: $BR_ISP_IP
      remote: $HQ_ISP_IP
      addresses: [$GRE_BR/30]
EOF
    netplan apply
    apply_sysctl_forwarding

    echo -e "${CYAN}Настройка NAT, FRR, Chrony...${NC}"
    apt update && DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent frr chrony

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -t nat -A PREROUTING -p tcp -i $INT_ISP --dport 8086 -j DNAT --to-destination $BR_SRV_IP:8080
    iptables -t nat -A PREROUTING -p tcp -i $INT_ISP --dport 3015 -j DNAT --to-destination $BR_SRV_IP:3015
    iptables-save > /etc/iptables/rules.v4

    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl restart frr
    vtysh -c "conf t" \
          -c "router ospf" \
          -c "network 10.0.0.0/30 area 0" \
          -c "network 192.168.30.0/28 area 0" \
          -c "exit" \
          -c "interface gre1" \
          -c "ip ospf authentication message-digest" \
          -c "ip ospf message-digest-key 1 md5 P@ssw0rd" \
          -c "exit" -c "write"

    echo "server $HQ_RTR_V10 iburst" >> /etc/chrony/chrony.conf
    systemctl restart chronyd

    echo -e "${GREEN}BR-RTR Настроен!${NC}"
}

setup_hqsrv() {
    set_hostname_tz "hq-srv.$DOMAIN"
    create_sshuser
    
    show_interfaces
    read -p "Введите интерфейс (vlan10 LAN): " INT_LAN

    backup_netplan
    cat <<EOF > /etc/netplan/01-hqsrv.yaml
network:
  version: 2
  ethernets:
    $INT_LAN:
      addresses: [$HQ_SRV_IP/27]
      routes:
        - to: default
          via: $HQ_RTR_V10
      nameservers:
        addresses: [127.0.0.1, 8.8.8.8]
EOF
    netplan apply

    echo -e "${CYAN}Настройка пакетов (Bind9, NFS, MDADM, Apache, DB)...${NC}"
    apt update && DEBIAN_FRONTEND=noninteractive apt install -y mdadm nfs-kernel-server bind9 bind9utils chrony apache2 mariadb-server php libapache2-mod-php php-mysql php-xml php-curl php-zip php-gd php-mbstring php-intl

    # RAID
    lsblk | grep disk
    echo -e "${YELLOW}Введите 3 имени дисков для RAID (например: sdb sdc sdd), разделяя ПРОБЕЛОМ:${NC}"
    read DISK1 DISK2 DISK3
    mdadm --create --verbose /dev/md0 --level=0 --raid-devices=3 /dev/$DISK1 /dev/$DISK2 /dev/$DISK3
    mkfs.ext4 /dev/md0
    mkdir -p /raid0/nfs
    echo "/dev/md0 /raid0 ext4 defaults 0 0" >> /etc/fstab
    mount -a
    echo "/raid0/nfs 192.168.20.0/27(rw,sync,no_subtree_check)" >> /etc/exports
    exportfs -a
    systemctl restart nfs-kernel-server

    # DNS
    cat <<EOF > /etc/bind/named.conf.options
options {
    directory "/var/cache/bind";
    forwarders { 8.8.8.8; };
    dnssec-validation auto;
    listen-on-v6 { any; };
    allow-query { any; };
};
EOF
    cat <<EOF > /etc/bind/named.conf.local
zone "$DOMAIN" { type master; file "/etc/bind/db.$DOMAIN"; };
EOF
    cat <<EOF > /etc/bind/db.$DOMAIN
\$TTL    604800
@       IN      SOA     hq-srv.$DOMAIN. admin.$DOMAIN. ( 2 604800 86400 2419200 604800 )
@       IN      NS      hq-srv.$DOMAIN.
hq-rtr  IN      A       $HQ_RTR_V10
br-rtr  IN      A       $BR_RTR_LAN
hq-srv  IN      A       $HQ_SRV_IP
br-srv  IN      A       $BR_SRV_IP
moodle  IN      A       $HQ_ISP_IP
wiki    IN      A       $BR_ISP_IP
EOF
    # Запись для hq-cli добавится динамически или статикой позже
    systemctl restart bind9

    # DB Moodle
    systemctl start mariadb
    mysql -e "CREATE DATABASE moodledb DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER 'moodle'@'localhost' IDENTIFIED BY 'P@ssw0rd';"
    mysql -e "GRANT ALL PRIVILEGES ON moodledb.* TO 'moodle'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    echo "server $HQ_RTR_V10 iburst" >> /etc/chrony/chrony.conf
    systemctl restart chronyd

    echo -e "${GREEN}HQ-SRV Настроен! (Осталось скачать Moodle в /var/www/html/moodle)${NC}"
}

setup_brsrv() {
    set_hostname_tz "br-srv.$DOMAIN"
    create_sshuser
    
    show_interfaces
    read -p "Введите интерфейс (LAN): " INT_LAN

    backup_netplan
    cat <<EOF > /etc/netplan/01-brsrv.yaml
network:
  version: 2
  ethernets:
    $INT_LAN:
      addresses: [$BR_SRV_IP/28]
      routes:
        - to: default
          via: $BR_RTR_LAN
      nameservers:
        addresses: [$HQ_SRV_IP, 8.8.8.8]
EOF
    netplan apply

    echo -e "${CYAN}Установка Docker, Samba AD, Ansible...${NC}"
    apt update && DEBIAN_FRONTEND=noninteractive apt install -y docker.io docker-compose samba smbclient winbind krb5-user chrony ansible

    # Docker Wiki
    useradd -m -s /bin/bash wiki
    mkdir -p /home/wiki
    cat <<EOF > /home/wiki/wiki.yml
version: '3'
services:
  wiki:
    image: mediawiki
    restart: always
    ports:
      - "8080:80"
    volumes:
      - ./LocalSettings.php:/var/www/html/LocalSettings.php
  mariadb:
    image: mariadb
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: mediawiki
      MYSQL_USER: wiki
      MYSQL_PASSWORD: WikiP@ssw0rd
EOF
    touch /home/wiki/LocalSettings.php
    cd /home/wiki && docker-compose -f wiki.yml up -d

    # Samba AD DC
    systemctl disable --now systemd-resolved
    rm /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    systemctl stop smbd nmbd winbind
    mv /etc/samba/smb.conf /etc/samba/smb.conf.bak

    echo -e "${CYAN}Provisioning Domain (это займет время)...${NC}"
    samba-tool domain provision --use-rfc2307 --realm="$REALM" --domain="AU-TEAM" --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass="AdminP@ssw0rd1!"
    systemctl unmask samba-ad-dc
    systemctl enable --now samba-ad-dc

    sleep 5
    samba-tool group add hq
    for i in {1..5}; do
        samba-tool user create "user${i}.hq" "P@ssw0rd1!"
        samba-tool group addmembers hq "user${i}.hq"
    done

    # Ansible
    mkdir -p /etc/ansible
    cat <<EOF > /etc/ansible/hosts
[routers]
$HQ_RTR_V10
$BR_RTR_LAN
[servers]
$HQ_SRV_IP
EOF

    echo "server $HQ_RTR_V10 iburst" >> /etc/chrony/chrony.conf
    systemctl restart chronyd

    echo -e "${GREEN}BR-SRV Настроен! (Импорт csv сделан через заглушки user1-user5)${NC}"
}

setup_hqcli() {
    set_hostname_tz "hq-cli.$DOMAIN"
    
    echo -e "${CYAN}Установка Yandex Browser и NFS...${NC}"
    apt update
    wget -qO - https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG | gpg --dearmor -o /usr/share/keyrings/yandex-browser.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/yandex-browser.gpg] http://repo.yandex.ru/yandex-browser/deb stable main" > /etc/apt/sources.list.d/yandex-browser.list
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y yandex-browser-corporate nfs-common autofs chrony realmd sssd sssd-tools adcli krb5-user packagekit

    # AutoFS
    echo "/mnt/nfs /etc/auto.nfs" >> /etc/auto.master
    echo "share -rw,soft,intr $HQ_SRV_IP:/raid0/nfs" > /etc/auto.nfs
    systemctl restart autofs

    echo "server $HQ_RTR_V10 iburst" >> /etc/chrony/chrony.conf
    systemctl restart chronyd

    echo -e "${GREEN}HQ-CLI Настроен!${NC}"
    echo -e "${YELLOW}Для ввода в домен используйте: sudo realm join -U Administrator $REALM${NC}"
    echo -e "${YELLOW}И добавьте в visudo: %hq@$DOMAIN ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /usr/bin/id${NC}"
}

# ==============================================================================
# МЕНЮ
# ==============================================================================

clear
echo -e "${YELLOW}==============================================${NC}"
echo -e "${GREEN}Автоматическая настройка модулей ДЭМО Экзамена${NC}"
echo -e "${YELLOW}==============================================${NC}"
echo "Выберите роль для этой машины:"
echo "1) ISP     (Провайдер)"
echo "2) HQ-RTR  (Роутер Центрального Офиса)"
echo "3) BR-RTR  (Роутер Филиала)"
echo "4) HQ-SRV  (Сервер Центрального Офиса)"
echo "5) BR-SRV  (Сервер Филиала)"
echo "6) HQ-CLI  (Клиентская машина)"
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
    0) exit ;;
    *) echo -e "${RED}Неверный выбор.${NC}" ;;
esac

echo -e "${YELLOW}Скрипт завершил работу. Рекомендуется перезагрузить систему (reboot).${NC}"
