#!/bin/bash
# ==============================================================================
# Master Script - V3 (Сначала качаем пакеты, потом ломаем интернет)
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mЗапустите скрипт от root (sudo su)!\e[0m"
  exit 1
fi

LOG_FILE="/var/log/exam_debug.log"
echo "=== НАЧАЛО УСТАНОВКИ: $(date) ===" > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
set -e
trap 'echo -e "\n\e[41m[ОШИБКА] Скрипт упал на строке $LINENO. Код: $?.\e[0m"' ERR

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}Удаление CD-ROM из источников apt...${NC}"
sed -i '/cdrom/d' /etc/apt/sources.list 2>/dev/null || true
sed -i '/cdrom/d' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

echo -e "${CYAN}Обновление списка пакетов (пока есть интернет)...${NC}"
apt-get update -y -q || true

# Глобальные IP
DOMAIN="au-team.irpo"
REALM="AU-TEAM.IRPO"
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

show_interfaces() {
    echo -e "\n${YELLOW}Доступные сетевые интерфейсы:${NC}"
    ip -br l | awk '{print $1}' | grep -v "lo"
}

apply_netplan() {
    echo -e "${CYAN}Применение Netplan (смена сети на экзаменационную)...${NC}"
    chmod 600 /etc/netplan/*.yaml
    netplan apply
    sleep 2
}

create_sshuser() {
    id -u sshuser &>/dev/null || useradd -m -s /bin/bash -u 1015 sshuser
    echo "sshuser:P@ssw0rd" | chpasswd
    usermod -aG sudo sshuser
    echo "sshuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser
    echo "Authorized access only" > /etc/issue.net
    sed -i 's/^#*Port 22/Port 3015/' /etc/ssh/sshd_config
    sed -i 's/^#*Banner .*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
    sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 2/' /etc/ssh/sshd_config
    grep -q "AllowUsers sshuser" /etc/ssh/sshd_config || echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    systemctl restart sshd
}

create_netadmin() {
    id -u net_admin &>/dev/null || useradd -m -s /bin/bash net_admin
    echo "net_admin:P@\$\$w0rd" | chpasswd
    usermod -aG sudo net_admin
    echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
}

# ==============================================================================

setup_isp() {
    hostnamectl set-hostname "isp.$DOMAIN"
    timedatectl set-timezone Europe/Moscow
    
    show_interfaces
    read -p "Интерфейс в ИНТЕРНЕТ (NAT VMware): " INT_EXT
    read -p "Интерфейс к HQ-RTR (vlan 40): " INT_HQ
    read -p "Интерфейс к BR-RTR (vlan 50): " INT_BR

    # ШАГ 1: КАЧАЕМ ПАКЕТЫ (пока работает твой временный NAT)
    echo -e "${CYAN}Установка пакетов (требуется интернет!)...${NC}"
    apt-get install -y -q iptables-persistent nginx

    # ШАГ 2: ЛОМАЕМ ИНТЕРНЕТ, СТРОИМ СЕТЬ
    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
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
    apply_netplan

    # ШАГ 3: НАСТРОЙКА
    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sysctl -p

    iptables -t nat -A POSTROUTING -o $INT_EXT -j MASQUERADE
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat <<EOF > /etc/nginx/sites-available/default
server { listen 80; server_name moodle.$DOMAIN; location / { proxy_pass http://$HQ_ISP_IP:80; } }
server { listen 80; server_name wiki.$DOMAIN; location / { proxy_pass http://$BR_ISP_IP:8086; } }
EOF
    systemctl restart nginx
    echo -e "${GREEN}[УСПЕХ] ISP настроен!${NC}"
}

setup_hqrtr() {
    hostnamectl set-hostname "hq-rtr.$DOMAIN"
    timedatectl set-timezone Europe/Moscow
    create_netadmin
    
    show_interfaces
    read -p "Интерфейс к ISP: " INT_ISP
    read -p "Интерфейс ВНУТРЬ (VLANs): " INT_LAN

    # ШАГ 1: КАЧАЕМ ПАКЕТЫ
    echo -e "${CYAN}Установка пакетов (требуется интернет!)...${NC}"
    apt-get install -y -q isc-dhcp-server iptables-persistent frr chrony

    # ШАГ 2: СЕТЬ
    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
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
    apply_netplan

    # ШАГ 3: НАСТРОЙКА
    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sysctl -p

    sed -i 's/INTERFACESv4=""/INTERFACESv4="vlan20"/' /etc/default/isc-dhcp-server
    cat <<EOF >> /etc/dhcp/dhcpd.conf
subnet 192.168.20.0 netmask 255.255.255.224 {
  range 192.168.20.10 192.168.20.30;
  option routers $HQ_RTR_V20;
  option domain-name-servers $HQ_SRV_IP;
  option domain-name "$DOMAIN";
}
EOF
    systemctl restart isc-dhcp-server || true

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -t nat -A PREROUTING -p tcp -i $INT_ISP --dport 80 -j DNAT --to-destination $HQ_SRV_IP:80
    iptables -t nat -A PREROUTING -p tcp -i $INT_ISP --dport 3015 -j DNAT --to-destination $HQ_SRV_IP:3015
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl restart frr
    sleep 2
    vtysh -c "conf t" -c "router ospf" -c "network 10.0.0.0/30 area 0" -c "network 192.168.10.0/27 area 0" -c "network 192.168.20.0/27 area 0" -c "exit" -c "interface gre1" -c "ip ospf authentication message-digest" -c "ip ospf message-digest-key 1 md5 P@ssw0rd" -c "exit" -c "write"

    sed -i '/^pool/d' /etc/chrony/chrony.conf
    echo "local stratum 5" >> /etc/chrony/chrony.conf
    echo "allow 192.168.0.0/16" >> /etc/chrony/chrony.conf
    echo "allow 10.0.0.0/8" >> /etc/chrony/chrony.conf
    systemctl restart chronyd

    echo -e "${GREEN}[УСПЕХ] HQ-RTR настроен!${NC}"
}

setup_brrtr() {
    hostnamectl set-hostname "br-rtr.$DOMAIN"
    timedatectl set-timezone Europe/Moscow
    create_netadmin
    
    show_interfaces
    read -p "Интерфейс к ISP: " INT_ISP
    read -p "Интерфейс в LAN: " INT_LAN

    # ШАГ 1: КАЧАЕМ ПАКЕТЫ
    echo -e "${CYAN}Установка пакетов (требуется интернет!)...${NC}"
    apt-get install -y -q iptables-persistent frr chrony

    # ШАГ 2: СЕТЬ
    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
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
    apply_netplan

    # ШАГ 3: НАСТРОЙКА
    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    sysctl -p

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -t nat -A PREROUTING -p tcp -i $INT_ISP --dport 8086 -j DNAT --to-destination $BR_SRV_IP:8080
    iptables -t nat -A PREROUTING -p tcp -i $INT_ISP --dport 3015 -j DNAT --to-destination $BR_SRV_IP:3015
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
    systemctl restart frr
    sleep 2
    vtysh -c "conf t" -c "router ospf" -c "network 10.0.0.0/30 area 0" -c "network 192.168.30.0/28 area 0" -c "exit" -c "interface gre1" -c "ip ospf authentication message-digest" -c "ip ospf message-digest-key 1 md5 P@ssw0rd" -c "exit" -c "write"

    echo "server $HQ_RTR_V10 iburst" >> /etc/chrony/chrony.conf
    systemctl restart chronyd

    echo -e "${GREEN}[УСПЕХ] BR-RTR настроен!${NC}"
}

setup_hqsrv() {
    hostnamectl set-hostname "hq-srv.$DOMAIN"
    timedatectl set-timezone Europe/Moscow
    create_sshuser
    
    show_interfaces
    read -p "Интерфейс: " INT_LAN

    # ШАГ 1: КАЧАЕМ ПАКЕТЫ
    echo -e "${CYAN}Установка пакетов (требуется интернет!)...${NC}"
    apt-get install -y -q mdadm nfs-kernel-server bind9 bind9utils chrony apache2 mariadb-server php libapache2-mod-php php-mysql php-xml php-curl php-zip php-gd php-mbstring php-intl

    # ШАГ 2: СЕТЬ
    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
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
    apply_netplan

    # ШАГ 3: НАСТРОЙКА
    echo "Настройка RAID..."
    lsblk | grep disk || true
    read -p "Введи 3 диска для RAID (напр. sdb sdc sdd) или нажми Enter для пропуска: " DISK1 DISK2 DISK3
    if [ -n "$DISK1" ]; then
        mdadm --create --verbose /dev/md0 --level=0 --raid-devices=3 /dev/$DISK1 /dev/$DISK2 /dev/$DISK3 || true
        mkfs.ext4 /dev/md0 || true
        mkdir -p /raid0/nfs
        echo "/dev/md0 /raid0 ext4 defaults 0 0" >> /etc/fstab
        mount -a || true
        echo "/raid0/nfs 192.168.20.0/27(rw,sync,no_subtree_check)" >> /etc/exports
        exportfs -a
        systemctl restart nfs-kernel-server
    fi

    cat <<EOF > /etc/bind/named.conf.options
options { directory "/var/cache/bind"; forwarders { 8.8.8.8; }; dnssec-validation auto; listen-on-v6 { any; }; allow-query { any; }; };
EOF
    cat <<EOF > /etc/bind/named.conf.local
zone "$DOMAIN" { type master; file "/etc/bind/db.$DOMAIN"; };
EOF
    cat <<EOF > /etc/bind/db.$DOMAIN
\$TTL 604800
@ IN SOA hq-srv.$DOMAIN. admin.$DOMAIN. ( 2 604800 86400 2419200 604800 )
@ IN NS hq-srv.$DOMAIN.
hq-rtr IN A $HQ_RTR_V10
br-rtr IN A $BR_RTR_LAN
hq-srv IN A $HQ_SRV_IP
br-srv IN A $BR_SRV_IP
moodle IN A $HQ_ISP_IP
wiki   IN A $BR_ISP_IP
EOF
    systemctl restart bind9

    systemctl start mariadb
    mysql -e "CREATE DATABASE IF NOT EXISTS moodledb DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS 'moodle'@'localhost' IDENTIFIED BY 'P@ssw0rd';"
    mysql -e "GRANT ALL PRIVILEGES ON moodledb.* TO 'moodle'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    echo "server $HQ_RTR_V10 iburst" >> /etc/chrony/chrony.conf
    systemctl restart chronyd

    echo -e "${GREEN}[УСПЕХ] HQ-SRV настроен!${NC}"
}

setup_brsrv() {
    hostnamectl set-hostname "br-srv.$DOMAIN"
    timedatectl set-timezone Europe/Moscow
    create_sshuser
    
    show_interfaces
    read -p "Интерфейс: " INT_LAN

    # ШАГ 1: КАЧАЕМ ПАКЕТЫ
    echo -e "${CYAN}Установка пакетов (требуется интернет!)...${NC}"
    apt-get install -y -q docker.io docker-compose samba smbclient winbind krb5-user chrony ansible

    # ШАГ 2: СЕТЬ
    rm -f /etc/netplan/*.yaml
    cat <<EOF > /etc/netplan/00-config.yaml
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
    apply_netplan

    # ШАГ 3: НАСТРОЙКА
    id -u wiki &>/dev/null || useradd -m -s /bin/bash wiki
    mkdir -p /home/wiki
    cat <<EOF > /home/wiki/wiki.yml
version: '3'
services:
  wiki:
    image: mediawiki
    restart: always
    ports: [ "8080:80" ]
    volumes: [ "./LocalSettings.php:/var/www/html/LocalSettings.php" ]
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
    cd /home/wiki && docker-compose -f wiki.yml up -d || true

    systemctl disable --now systemd-resolved
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    systemctl stop smbd nmbd winbind || true
    mv /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true

    samba-tool domain provision --use-rfc2307 --realm="$REALM" --domain="AU-TEAM" --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass="AdminP@ssw0rd1!" || true
    systemctl unmask samba-ad-dc
    systemctl enable --now samba-ad-dc

    sleep 5
    samba-tool group add hq || true
    for i in {1..5}; do
        samba-tool user create "user${i}.hq" "P@ssw0rd1!" || true
        samba-tool group addmembers hq "user${i}.hq" || true
    done

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

    echo -e "${GREEN}[УСПЕХ] BR-SRV настроен!${NC}"
}

setup_hqcli() {
    hostnamectl set-hostname "hq-cli.$DOMAIN"
    timedatectl set-timezone Europe/Moscow
    
    # ШАГ 1: КАЧАЕМ ПАКЕТЫ
    echo -e "${CYAN}Установка пакетов (требуется интернет!)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    wget -qO - https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG | gpg --dearmor -o /usr/share/keyrings/yandex-browser.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/yandex-browser.gpg] http://repo.yandex.ru/yandex-browser/deb stable main" > /etc/apt/sources.list.d/yandex-browser.list
    apt-get update -y -q
    apt-get install -y -q yandex-browser-corporate nfs-common autofs chrony realmd sssd sssd-tools adcli krb5-user packagekit

    # ШАГ 2: НАСТРОЙКА (Сеть здесь получает DHCP, её ломать не надо)
    echo "/mnt/nfs /etc/auto.nfs" >> /etc/auto.master
    echo "share -rw,soft,intr $HQ_SRV_IP:/raid0/nfs" > /etc/auto.nfs
    systemctl restart autofs

    echo "server $HQ_RTR_V10 iburst" >> /etc/chrony/chrony.conf
    systemctl restart chronyd

    echo -e "${GREEN}[УСПЕХ] HQ-CLI настроен!${NC}"
}

clear
echo -e "${YELLOW}=================================================${NC}"
echo -e "${GREEN} ЭКЗАМЕН - СНАЧАЛА КАЧАЕМ ПАКЕТЫ, ПОТОМ СЕТЬ${NC}"
echo -e "${YELLOW}=================================================${NC}"
echo "Выберите роль машины:"
echo "1) ISP     (Провайдер)"
echo "2) HQ-RTR  (Роутер Центра)"
echo "3) BR-RTR  (Роутер Филиала)"
echo "4) HQ-SRV  (Сервер Центра)"
echo "5) BR-SRV  (Сервер Филиала)"
echo "6) HQ-CLI  (Клиент, Desktop)"
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

echo -e "\n${YELLOW}Скрипт завершен! Пакеты скачаны, сеть перенастроена.${NC}"
echo -e "${RED}ВАЖНО: После выполнения скрипта отключи лишние NAT-адаптеры в VMware (оставь только на ISP) и проверь пинги!${NC}"
