#!/bin/bash
# ==============================================================================
# ДЕМОЭКЗАМЕН 2026 (ВАРИАНТ 2) — МОДУЛЬ 2 (ПРИКЛАДНЫЕ СЕРВИСЫ)
# Особенности: AD NS Delegation, Asymmetric DNS Fix, PAM Force
# ==============================================================================

trap cleanup SIGINT SIGTERM

cleanup() {
    echo -e "\n\033[0;31m[ВНИМАНИЕ] Получен сигнал прерывания (SIGINT/SIGTERM).\033[0m"
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo -e "\033[0;31m[ФАТАЛЬНО] Остановка выполнения. DPKG блокировки НЕ снимаются принудительно для защиты базы пакетов.\033[0m"
    kill -TERM -$$ 2>/dev/null
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[ФАТАЛЬНО] Запустите скрипт от root!\033[0m"
    exit 1
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

DOMAIN="au-team.irpo"
DOMAIN_UPPER="AU-TEAM.IRPO"
DOMAIN_SHORT="AU-TEAM"

ISP_HQ_IP="172.16.30.1"
HQ_ISP_IP="172.16.30.2"
ISP_BR_IP="172.16.40.1"
BR_ISP_IP="172.16.40.2"

HQ_SRV_IP="192.168.10.2"
BR_SRV_IP="192.168.30.2"
HQ_RTR_V112="192.168.10.1"
BR_RTR_LAN="192.168.30.1"

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
    log_info "Блокировка фоновых обновлений Ubuntu (unattended-upgrades)..."
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl disable unattended-upgrades 2>/dev/null || true
    
    echo 'APT::Periodic::Enable "0";' > /etc/apt/apt.conf.d/10periodic
    echo 'APT::Periodic::Update-Package-Lists "0";' >> /etc/apt/apt.conf.d/10periodic
    echo 'APT::Periodic::Unattended-Upgrade "0";' >> /etc/apt/apt.conf.d/10periodic
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    echo 'DPkg::Lock::Timeout "60";' > /etc/apt/apt.conf.d/99lock-timeout
    
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
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
    apt-get update -y -q || true
}

apply_netplan_srv() {
    local IP=$1
    local GW=$2
    local INT=$3
    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT:
      addresses: [$IP]
      routes:
        - to: "0.0.0.0/0"
          via: $GW
EOF
    chmod 600 /etc/netplan/*.yaml
    netplan apply
    sleep 3
}

# ======================== ИСПОЛНЯЕМЫЕ БЛОКИ ========================

setup_hqsrv() {
    hostnamectl set-hostname "hq-srv.$DOMAIN"
    timedatectl set-timezone Europe/Moscow
    echo "127.0.0.1 localhost" > /etc/hosts
    echo "$HQ_SRV_IP hq-srv.$DOMAIN hq-srv" >> /etc/hosts

    show_interfaces
    get_valid_interface "Интерфейс к HQ-SW (Access VLAN 112): " INT_LAN
    apply_netplan_srv "$HQ_SRV_IP/27" "$HQ_RTR_V112" "$INT_LAN"

    log_info "Установка пакетов: mdadm, nfs, LAMP, BIND9..."
    prepare_apt
    apt-get install -y -q mdadm nfs-kernel-server apache2 mariadb-server php php-mysql bind9 bind9-utils chrony openssh-server

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

    log_info "Сборка RAID5 из 3 дисков..."
    AVAILABLE_DISKS=""
    for disk in $(lsblk -d -n -o NAME | grep -E '^sd|^vd|^nvme'); do
        if ! lsblk "/dev/$disk" | grep -q -E "part|lvm|crypt"; then
            if [ -z "$(lsblk -n -o FSTYPE "/dev/$disk")" ]; then
                AVAILABLE_DISKS="$AVAILABLE_DISKS $disk"
            fi
        fi
    done

    AVAILABLE_DISKS=$(echo "$AVAILABLE_DISKS" | tr ' ' '\n' | grep -v '^$' | head -n 3)
    DISK_COUNT=$(echo "$AVAILABLE_DISKS" | wc -l)

    if [ "$DISK_COUNT" -eq 3 ]; then
        RAID_TARGETS=""
        for disk in $AVAILABLE_DISKS; do RAID_TARGETS="$RAID_TARGETS /dev/$disk"; done
        
        yes | mdadm --create --verbose /dev/md2 --level=5 --raid-devices=3 $RAID_TARGETS
        mkdir -p /etc/mdadm
        mdadm --detail --scan >> /etc/mdadm/mdadm.conf
        update-initramfs -u
        
        mkfs.ext4 -F /dev/md2
        udevadm trigger; udevadm settle; partprobe /dev/md2
        
        MD_UUID=""
        for i in {1..15}; do
            MD_UUID=$(blkid -p -s UUID -o value /dev/md2 || lsblk -no UUID /dev/md2)
            if [ -n "$MD_UUID" ]; then break; fi
            sleep 1
        done
        
        if [ -n "$MD_UUID" ]; then
            echo "UUID=$MD_UUID /raid ext4 defaults 0 0" >> /etc/fstab
            mkdir -p /raid
            mount -a
            log_succ "Успешно: RAID5 собран и примонтирован в /raid!"
        fi
    else
        log_err "Найдено только $DISK_COUNT дисков. Пропущено."
    fi

    mkdir -p /raid/nfs
    chmod 777 /raid/nfs
    echo "/raid/nfs 192.168.20.0/27(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
    exportfs -arv
    systemctl restart nfs-kernel-server

    log_info "Настройка базы данных MariaDB (webdb)..."
    systemctl start mariadb
    mysql -u root <<'SQLEOF'
CREATE DATABASE IF NOT EXISTS webdb;
CREATE USER IF NOT EXISTS 'web2c'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web2c'@'localhost';
FLUSH PRIVILEGES;
SQLEOF

    log_info "Настройка Apache на порт 8082..."
    sed -i 's/Listen 80/Listen 8082/' /etc/apache2/ports.conf
    cat > /etc/apache2/sites-available/000-default.conf <<EOF
<VirtualHost *:8082>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
</VirtualHost>
EOF
    cat > /var/www/html/index.php <<EOF
<?php
\$mysqli = new mysqli("localhost", "web2c", "P@ssw0rd", "webdb");
if (\$mysqli->connect_errno) { echo "DB Connection Failed!"; } else { echo "<h1>HQ-SRV Web App Connected Successfully!</h1>"; }
?>
EOF
    rm -f /var/www/html/index.html
    systemctl restart apache2

    # КРИТИЧЕСКИЙ ФИКС: Убраны forward-зоны для AD, используется NS-делегирование
    cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";
    forwarders { 77.88.8.8; 77.88.8.3; };
    dnssec-validation no;
    listen-on { any; };
    allow-query { any; };
};
EOF

    cat > /etc/bind/named.conf.local <<EOF
zone "$DOMAIN" { type master; file "/etc/bind/db.forward"; };
zone "10.168.192.in-addr.arpa" { type master; file "/etc/bind/db.rev10"; };
zone "20.168.192.in-addr.arpa" { type master; file "/etc/bind/db.rev20"; };
EOF

    # КРИТИЧЕСКИЙ ФИКС: Симметричный внешний IP ($ISP_HQ_IP) и NS-записи для Samba
    cat > /etc/bind/db.forward <<EOF
\$TTL 604800
@       IN  SOA   hq-srv.$DOMAIN. admin.$DOMAIN. ( 4 604800 86400 2419200 604800 )
@       IN  NS    hq-srv.$DOMAIN.
@       IN  A     $BR_SRV_IP
hq-rtr  IN  A     $HQ_RTR_V112
br-rtr  IN  A     $BR_RTR_LAN
hq-srv  IN  A     $HQ_SRV_IP
hq-cli  IN  A     192.168.20.10
br-srv  IN  A     $BR_SRV_IP
docker  IN  A     $ISP_HQ_IP
web     IN  A     $ISP_HQ_IP

; Делегирование поддоменов Active Directory на Samba AD DC (BR-SRV)
_msdcs          IN NS br-srv.$DOMAIN.
_sites          IN NS br-srv.$DOMAIN.
_tcp            IN NS br-srv.$DOMAIN.
_udp            IN NS br-srv.$DOMAIN.
DomainDnsZones  IN NS br-srv.$DOMAIN.
ForestDnsZones  IN NS br-srv.$DOMAIN.
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
server $ISP_HQ_IP iburst
makestep 1 3
EOF
    systemctl restart chrony

    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo -e "nameserver 127.0.0.1\nsearch $DOMAIN" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true

    log_succ "HQ-SRV: RAID5, NFS, Web App (8082), AD DNS Delegation и SSH (2012) готовы!"
}

setup_brsrv() {
    hostnamectl set-hostname "br-srv.$DOMAIN"
    timedatectl set-timezone Europe/Moscow
    echo "127.0.0.1 localhost" > /etc/hosts
    echo "$BR_SRV_IP br-srv.$DOMAIN br-srv" >> /etc/hosts

    show_interfaces
    get_valid_interface "Интерфейс в LAN: " INT_LAN
    apply_netplan_srv "$BR_SRV_IP/28" "$BR_RTR_LAN" "$INT_LAN"

    log_info "Установка Samba AD, Docker и Ansible..."
    prepare_apt
    apt-get install -y -q docker.io docker-compose-plugin samba smbclient krb5-user winbind libpam-winbind libnss-winbind ansible sshpass chrony openssh-server

    # Пользователь 2012
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

    log_info "Инициализация домена Samba AD DC..."
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo -e "nameserver 127.0.0.1\nsearch $DOMAIN" > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true

    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    rm -f /etc/samba/smb.conf

    samba-tool domain provision \
        --use-rfc2307 \
        --realm="$DOMAIN_UPPER" \
        --domain="$DOMAIN_SHORT" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --option="dns forwarder=$HQ_SRV_IP" \
        --host-ip="$BR_SRV_IP" \
        --adminpass='P@ssw0rd123!'

    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf 2>/dev/null || true
    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl start samba-ad-dc
    systemctl enable samba-ad-dc
    
    for i in {1..30}; do
        if ss -tln | grep -q ":53 "; then break; fi
        sleep 2
    done

    samba-tool group add hq 2>/dev/null || true
    for i in {1..5}; do
        samba-tool user create "hquser${i}" 'P@ssw0rd123!' 2>/dev/null || true
        samba-tool group addmembers hq "hquser${i}" 2>/dev/null || true
    done

    log_info "Создание Docker-композиции (Mock Application)..."
    mkdir -p /opt/docker_app
    cat > /opt/docker_app/docker-compose.yml <<EOF
version: '3.8'
services:
  site:
    image: nginx:alpine
    container_name: site
    ports:
      - "8082:80"
    dns:
      - $BR_SRV_IP
    depends_on:
      - db
  db:
    image: mariadb:10.11
    container_name: db
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: testdb2
      MYSQL_USER: test2c
      MYSQL_PASSWORD: P@ssw0rd
EOF
    systemctl start docker
    cd /opt/docker_app
    docker compose up -d

    log_info "Настройка Ansible..."
    mkdir -p /etc/ansible
    cat > /etc/ansible/hosts <<EOF
[all:vars]
ansible_ssh_pass=P@ssw0rd
ansible_user=sshuser
ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[servers]
$HQ_SRV_IP ansible_port=2012
$BR_SRV_IP ansible_port=2026

[routers]
$HQ_RTR_V112 ansible_user=net_admin ansible_ssh_pass=P@\$\$word
$BR_RTR_LAN ansible_user=net_admin ansible_ssh_pass=P@\$\$word

[clients]
192.168.20.10
EOF

    cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
host_key_checking = False
inventory = /etc/ansible/hosts
EOF

    log_succ "BR-SRV: Samba AD, Docker App (8082), Ansible и SSH (2026) готовы!"
}

setup_hqcli() {
    hostnamectl set-hostname "hq-cli.$DOMAIN"
    timedatectl set-timezone Europe/Moscow
    echo "127.0.0.1 localhost" > /etc/hosts

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

    log_info "Проверка DNS (ожидание BIND9)..."
    for i in {1..20}; do
        if getent ahosts archive.ubuntu.com >/dev/null 2>&1; then break; fi
        sleep 3
    done

    log_info "Установка AutoFS, SSSD и Yandex Browser..."
    prepare_apt
    apt-get install -y -q nfs-common autofs realmd sssd sssd-tools adcli krb5-user dnsutils chrony

    cat > /etc/chrony/chrony.conf <<EOF
server $ISP_HQ_IP iburst
makestep 1 3
EOF
    systemctl restart chrony

    echo "/mnt/nfs -fstype=nfs,rw,hard $HQ_SRV_IP:/raid/nfs" > /etc/auto.nfs
    mkdir -p /mnt/nfs
    systemctl restart autofs

    mkdir -p /usr/share/keyrings
    curl -fsSL https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG | gpg --dearmor -o /usr/share/keyrings/yandex-browser.gpg --yes
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/yandex-browser.gpg] http://repo.yandex.ru/yandex-browser/deb stable main" > /etc/apt/sources.list.d/yandex-browser.list
    apt-get update -y -q && apt-get install -y -q yandex-browser-corporate || true

    log_info "Ввод машины в домен AD..."
    resolvectl flush-caches 2>/dev/null || true
    echo 'P@ssw0rd123!' | realm join -U Administrator "$DOMAIN"
    if [ $? -eq 0 ]; then
        sed -i 's/use_fully_qualified_names = [Tt]rue/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
        systemctl restart sssd
    fi

    # КРИТИЧЕСКИЙ ФИКС: Форсированное включение mkhomedir без интерактивного окна
    pam-auth-update --enable mkhomedir --force

    cat > /etc/sudoers.d/hq_domain <<EOF
%hq ALL=(ALL) NOPASSWD: /usr/bin/cat, /usr/bin/grep, /usr/bin/id
EOF
    chmod 440 /etc/sudoers.d/hq_domain

    log_succ "HQ-CLI: Настроен, введен в домен, AutoFS работает!"
}

setup_isp() {
    log_info "Установка Nginx и Apache-utils (Basic Auth)..."
    prepare_apt
    apt-get install -y -q nginx apache2-utils

    htpasswd -b -c /etc/nginx/.htpasswd Kozmac 'P@ssw0rd'

    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name web.$DOMAIN;
    
    auth_basic "Restricted Access";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://$HQ_ISP_IP:8082;
        proxy_set_header Host \$host;
    }
}
server {
    listen 80 default_server;
    server_name docker.$DOMAIN;
    location / {
        proxy_pass http://$BR_ISP_IP:8082;
        proxy_set_header Host \$host;
    }
}
EOF
    nginx -t && systemctl restart nginx
    log_succ "ISP: Nginx Reverse Proxy и Basic Auth настроены!"
}

clear
echo -e "${YELLOW}======================================================${NC}"
echo -e "${GREEN} ДЕМОЭКЗАМЕН 2026 (В2) — МОДУЛЬ 2 (ПРИКЛАДНЫЕ СЕРВИСЫ)${NC}"
echo -e "${CYAN} RAID5, Samba AD DNS Fix, APT Locks, Asymmetric IPs Fixed${NC}"
echo -e "${YELLOW}======================================================${NC}"
echo ""
echo "Выберите роль машины:"
echo "  1) ISP     — Провайдер (Nginx Reverse Proxy + Basic Auth)"
echo "  2) HQ-RTR  — Роутер Центра (Пропуск)"
echo "  3) HQ-SW   — Коммутатор Центра (Пропуск)"
echo "  4) BR-RTR  — Роутер Филиала (Пропуск)"
echo "  5) HQ-SRV  — Сервер Центра (RAID5, NFS, Apache/MariaDB)"
echo "  6) BR-SRV  — Сервер Филиала (Samba AD, Docker, Ansible)"
echo "  7) HQ-CLI  — Клиент (AutoFS, Join AD, Yandex)"
echo "  0) Выход"
echo ""

while true; do
    read -p "Ваш выбор: " choice
    case $choice in
        1) setup_isp; break ;;
        2|3|4) log_info "Сервисный модуль не требуется."; break ;;
        5) setup_hqsrv; break ;;
        6) setup_brsrv; break ;;
        7) setup_hqcli; break ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный выбор!${NC}" ;;
    esac
done

log_succ "Конфигурация Модуля 2 завершена!"
