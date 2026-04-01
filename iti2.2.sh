#!/bin/bash
# ==============================================================================
# ДЕМОЭКЗАМЕН 2025 - МОДУЛЬ 2 (Сервисы)
# Включает фикс DNS и принудительный IPv4 для APT
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mЗапустите от root (sudo su)!\e[0m"
  exit 1
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DOMAIN="au-team.irpo"
DOMAIN_UPPER="AU-TEAM.IRPO"
HQ_RTR_IP="192.168.10.1"
HQ_SRV_IP="192.168.10.2"
BR_SRV_IP="192.168.30.2"

echo -e "${CYAN}=== ЖЕСТКИЙ ФИКС ИНТЕРНЕТА ===${NC}"
# 1. Принудительно заставляем APT работать только по IPv4
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

# 2. Временно глушим локальный DNS и прописываем Google (чтобы пакеты 100% скачались)
chattr -i /etc/resolv.conf 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

export DEBIAN_FRONTEND=noninteractive
rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock
dpkg --configure -a 2>/dev/null || true

# Проверяем, скачиваются ли теперь списки пакетов
apt-get update -y -q || echo -e "\e[31mПРЕДУПРЕЖДЕНИЕ: Ошибка обновления APT. Проверьте роутеры!\e[0m"

# ==============================================================================

setup_isp() {
    echo -e "${YELLOW}Настройка NGINX Reverse Proxy (Задание 8)...${NC}"
    apt-get install -y nginx

    cat <<EOF > /etc/nginx/sites-available/default
server {
    listen 80;
    server_name moodle.$DOMAIN;
    location / { proxy_pass http://172.16.40.2:80; proxy_set_header Host \$host; }
}
server {
    listen 80;
    server_name wiki.$DOMAIN;
    location / { proxy_pass http://172.16.50.2:8086; proxy_set_header Host \$host; }
}
EOF
    systemctl restart nginx
    echo -e "${GREEN}[УСПЕХ] ISP: Nginx Proxy настроен!${NC}"
}

setup_hqrtr() {
    echo -e "${YELLOW}Настройка Chrony (Сервер) и Port Forwarding...${NC}"
    apt-get install -y chrony iptables-persistent

    cat <<EOF > /etc/chrony/chrony.conf
pool ntp.ubuntu.com iburst maxsources 4
pool 0.ubuntu.pool.ntp.org iburst maxsources 1
pool 1.ubuntu.pool.ntp.org iburst maxsources 1
pool 2.ubuntu.pool.ntp.org iburst maxsources 2
allow 192.168.0.0/16
allow 10.0.0.0/8
local stratum 5
EOF
    systemctl restart chrony

    iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination $HQ_SRV_IP:80
    iptables -t nat -A PREROUTING -p tcp --dport 3015 -j DNAT --to-destination $HQ_SRV_IP:3015
    iptables-save > /etc/iptables/rules.v4

    echo -e "${GREEN}[УСПЕХ] HQ-RTR: Chrony и NAT настроены!${NC}"
}

setup_brrtr() {
    echo -e "${YELLOW}Настройка Chrony (Клиент) и Port Forwarding...${NC}"
    apt-get install -y chrony iptables-persistent

    echo "server 10.0.0.1 iburst" > /etc/chrony/chrony.conf
    systemctl restart chrony

    iptables -t nat -A PREROUTING -p tcp --dport 8086 -j DNAT --to-destination $BR_SRV_IP:8080
    iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination $BR_SRV_IP:8086
    iptables -t nat -A PREROUTING -p tcp --dport 3015 -j DNAT --to-destination $BR_SRV_IP:3015
    iptables-save > /etc/iptables/rules.v4

    echo -e "${GREEN}[УСПЕХ] BR-RTR: Chrony и NAT настроены!${NC}"
}

setup_hqsrv() {
    echo -e "${YELLOW}Настройка RAID0, NFS, Chrony, Moodle...${NC}"
    apt-get install -y chrony mdadm nfs-kernel-server apache2 mariadb-server php php-mysql libapache2-mod-php php-xml php-mbstring php-curl php-zip php-gd php-intl unzip

    echo "server $HQ_RTR_IP iburst" > /etc/chrony/chrony.conf
    systemctl restart chrony

    echo -e "${YELLOW}Собираем RAID0...${NC}"
    if lsblk | grep -q sdb && lsblk | grep -q sdc && lsblk | grep -q sdd; then
        mdadm --create --verbose /dev/md0 --level=0 --raid-devices=3 /dev/sdb /dev/sdc /dev/sdd <<< "y"
        mdadm --detail --scan >> /etc/mdadm/mdadm.conf
        mkfs.ext4 /dev/md0
        mkdir -p /raid0
        echo "/dev/md0 /raid0 ext4 defaults 0 0" >> /etc/fstab
        mount -a
    else
        echo -e "\e[31mВНИМАНИЕ: Диски sdb, sdc, sdd не найдены! Создаю эмуляцию папки /raid0\e[0m"
        mkdir -p /raid0
    fi

    mkdir -p /raid0/nfs
    chmod 777 /raid0/nfs
    echo "/raid0/nfs 192.168.20.0/27(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
    exportfs -a
    systemctl restart nfs-kernel-server

    systemctl start mariadb
    sleep 2
    mysql -u root -e "CREATE DATABASE IF NOT EXISTS moodledb DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -u root -e "CREATE USER IF NOT EXISTS 'moodle'@'localhost' IDENTIFIED BY 'P@ssw0rd';"
    mysql -u root -e "GRANT ALL PRIVILEGES ON moodledb.* TO 'moodle'@'localhost';"
    mysql -u root -e "FLUSH PRIVILEGES;"

    mkdir -p /var/www/html/moodle
    echo "<h1>Moodle: Workplace Number 1</h1>" > /var/www/html/moodle/index.php
    echo "<h1>Welcome to Moodle Server</h1>" > /var/www/html/index.html
    chown -R www-data:www-data /var/www/html
    systemctl restart apache2

    echo -e "${GREEN}[УСПЕХ] HQ-SRV: RAID, NFS, Moodle настроены!${NC}"
}

setup_brsrv() {
    echo -e "${YELLOW}Настройка Samba AD, Chrony, Ansible, Docker...${NC}"
    apt-get install -y chrony ansible sshpass docker.io docker-compose samba smbclient krb5-user winbind libpam-winbind libnss-winbind

    echo "server 10.0.0.1 iburst" > /etc/chrony/chrony.conf
    systemctl restart chrony

    mkdir -p /etc/ansible
    cat <<EOF > /etc/ansible/hosts
[all:vars]
ansible_user=sshuser
ansible_password=P@ssw0rd
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
ansible_port=3015

[servers]
$HQ_SRV_IP
192.168.20.10
$HQ_RTR_IP
$BR_RTR_LAN
EOF

    mkdir -p /home/sshuser
    cat <<EOF > /home/sshuser/wiki.yml
version: '3'
services:
  wiki:
    image: mediawiki
    container_name: wiki
    ports:
      - "8080:80"
    volumes:
      - ./LocalSettings.php:/var/www/html/LocalSettings.php
    depends_on:
      - mariadb
  mariadb:
    image: mariadb
    container_name: mariadb
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: mediawiki
      MYSQL_USER: wiki
      MYSQL_PASSWORD: WikiP@ssw0rd
EOF
    touch /home/sshuser/LocalSettings.php
    cd /home/sshuser && docker-compose -f wiki.yml up -d || true

    systemctl stop smbd nmbd winbind systemd-resolved || true
    systemctl disable systemd-resolved || true
    rm -f /etc/samba/smb.conf /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf

    samba-tool domain provision --use-rfc2307 --realm=$DOMAIN_UPPER --domain=${DOMAIN%%.*} --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass="P@ssw0rd123!" || true

    systemctl unmask samba-ad-dc
    systemctl start samba-ad-dc
    systemctl enable samba-ad-dc

    samba-tool group add hq || true
    for i in {1..5}; do
        samba-tool user create user$i.hq "P@ssw0rd123!" || true
        samba-tool group addmembers hq user$i.hq || true
    done

    mkdir -p /opt
    echo "user1.hq,user2.hq,user3.hq" > /opt/users.csv

    echo -e "${GREEN}[УСПЕХ] BR-SRV: Samba, Ansible, Docker готовы!${NC}"
}

setup_hqcli() {
    echo -e "${YELLOW}Настройка Chrony, AutoFS (NFS), Samba AD (Join), Yandex...${NC}"
    apt-get install -y chrony nfs-common autofs realmd sssd sssd-tools adcli krb5-user packagekit

    echo "server $HQ_RTR_IP iburst" > /etc/chrony/chrony.conf
    systemctl restart chrony

    echo "/- /etc/auto.nfs" >> /etc/auto.master
    echo "/mnt/nfs -fstype=nfs,rw,soft,intr $HQ_SRV_IP:/raid0/nfs" > /etc/auto.nfs
    mkdir -p /mnt/nfs
    systemctl restart autofs

    echo "deb [arch=amd64] http://repo.yandex.ru/yandex-browser/deb stable main" > /etc/apt/sources.list.d/yandex-browser.list
    wget -q https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG -O- | apt-key add -
    apt-get update && apt-get install -y yandex-browser-corporate || echo "Установка браузера пропущена."

    # Настройка домена
    chattr -i /etc/resolv.conf 2>/dev/null
    echo "nameserver $BR_SRV_IP" > /etc/resolv.conf
    
    echo "P@ssw0rd123!" | realm join -U Administrator $DOMAIN || true
    
    echo "%hq@$DOMAIN ALL=(ALL) /usr/bin/cat, /usr/bin/grep, /usr/bin/id" > /etc/sudoers.d/hq_domain
    chmod 440 /etc/sudoers.d/hq_domain

    echo -e "${GREEN}[УСПЕХ] HQ-CLI: NFS, Домен и Яндекс Браузер настроены!${NC}"
}

clear
echo -e "${YELLOW}=================================================${NC}"
echo -e "${GREEN} ДЕМОЭКЗАМЕН 2025 - МОДУЛЬ 2 (С фиксом APT)${NC}"
echo -e "${YELLOW}=================================================${NC}"
echo "Выберите роль машины:"
echo "1) ISP     (Провайдер - Nginx)"
echo "2) HQ-RTR  (Роутер Центра - Port Forwarding, Chrony)"
echo "3) BR-RTR  (Роутер Филиала - Port Forwarding, Chrony)"
echo "4) HQ-SRV  (Сервер Центра - RAID0, NFS, Moodle)"
echo "5) BR-SRV  (Сервер Филиала - Samba AD, Ansible, Docker)"
echo "6) HQ-CLI  (Клиент - Join AD, AutoFS, Yandex)"
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
    0) exit 0 ;;
    *) echo "Ошибка выбора!"; exit 1 ;;
esac
