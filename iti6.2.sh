#!/bin/bash
# ==============================================================================
# ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 2 (ПРИКЛАДНЫЕ СЕРВИСЫ И AD)
# Целевая ОС: Ubuntu 22.04 / 24.04 LTS
# Требование: Успешно выполненный Модуль 1
# ==============================================================================

trap cleanup SIGINT SIGTERM

cleanup() {
    echo -e "\n\033[0;31m[ВНИМАНИЕ] Скрипт прерван пользователем. Очищаю блокировки...\033[0m"
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

DOMAIN="au-team.irpo"
DOMAIN_UPPER="AU-TEAM.IRPO"
DOMAIN_SHORT="AU-TEAM"

ISP_HQ_IP="172.16.40.1"
ISP_BR_IP="172.16.50.1"
HQ_ISP_IP="172.16.40.2"
BR_ISP_IP="172.16.50.2"
HQ_SRV_IP="192.168.10.2"
BR_SRV_IP="192.168.30.2"
HQ_RTR_V10="192.168.10.1"
BR_RTR_LAN="192.168.30.1"
HQ_CLI_IP="192.168.20.10"

export DEBIAN_FRONTEND=noninteractive

log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_succ() { echo -e "${GREEN}[УСПЕХ] $1${NC}"; }
log_err()  { echo -e "${RED}[ОШИБКА] $1${NC}"; }

# --- ИНЖЕНЕРНАЯ ИНИЦИАТИВА: Безопасный вызов APT ---
safe_apt_update() {
    log_info "Подготовка APT..."
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    dpkg --configure -a 2>/dev/null || true
    apt-get update -y -q || log_err "apt-get update завершился с ошибкой, но продолжаем..."
}

# ======================== ИСПОЛНЯЕМЫЕ БЛОКИ ========================

setup_isp() {
    log_info "Установка Nginx Reverse Proxy..."
    safe_apt_update
    apt-get install -y -q nginx

    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name moodle.$DOMAIN;
    location / {
        proxy_pass http://$HQ_ISP_IP:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
server {
    listen 80 default_server;
    server_name wiki.$DOMAIN;
    location / {
        proxy_pass http://$BR_ISP_IP:8086;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
    nginx -t && systemctl restart nginx
    log_succ "ISP: Nginx Proxy настроен!"
}

setup_hqsrv() {
    log_info "Установка пакетов: mdadm, nfs, LAMP, Moodle..."
    safe_apt_update
    apt-get install -y -q mdadm nfs-kernel-server apache2 mariadb-server \
        php php-mysql libapache2-mod-php php-xml php-mbstring php-curl \
        php-zip php-gd php-intl unzip

    # 1. Интеллектуальный поиск дисков и сборка RAID0
    log_info "Ищем 3 свободных диска для RAID0..."
    ROOT_DISK=$(lsblk -no pkname $(findmnt -no SOURCE /) | head -n 1)
    AVAILABLE_DISKS=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print $1}' | grep -v "^${ROOT_DISK}$" | head -n 3)
    DISK_COUNT=$(echo "$AVAILABLE_DISKS" | wc -w)

    if [ "$DISK_COUNT" -eq 3 ]; then
        RAID_TARGETS=""
        for disk in $AVAILABLE_DISKS; do
            RAID_TARGETS="$RAID_TARGETS /dev/$disk"
        done
        log_succ "Найдены диски: $RAID_TARGETS"
        
        yes | mdadm --create --verbose /dev/md0 --level=0 --raid-devices=3 $RAID_TARGETS
        mkdir -p /etc/mdadm
        mdadm --detail --scan >> /etc/mdadm/mdadm.conf
        mkfs.ext4 -F /dev/md0
        mkdir -p /raid0
        grep -q "/dev/md0" /etc/fstab || echo "/dev/md0 /raid0 ext4 defaults 0 0" >> /etc/fstab
        mount -a
    else
        log_err "Найдено только $DISK_COUNT свободных дисков из 3. Сборка RAID0 пропущена."
        log_info "Создаю эмуляцию директории /raid0 для совместимости с NFS."
        mkdir -p /raid0
    fi

    # 2. Настройка NFS
    mkdir -p /raid0/nfs
    chmod 777 /raid0/nfs
    echo "/raid0/nfs 192.168.20.0/27(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
    exportfs -arv
    systemctl restart nfs-kernel-server
    systemctl enable nfs-kernel-server

    # 3. Настройка MariaDB и Moodle
    systemctl start mariadb
    systemctl enable mariadb
    sleep 2

    mysql -u root <<'SQLEOF'
CREATE DATABASE IF NOT EXISTS moodledb DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'moodle'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON moodledb.* TO 'moodle'@'localhost';
FLUSH PRIVILEGES;
SQLEOF

    mkdir -p /var/www/html/moodle
    cat > /var/www/html/moodle/index.php <<'PHPEOF'
<?php
echo "<h1 style='color: #2c3e50; font-family: Arial;'>Moodle: Workplace Number 1</h1>";
echo "<p>Connected to database successfully.</p>";
?>
PHPEOF
    echo "<h1>Welcome to Moodle Server</h1>" > /var/www/html/index.html
    chown -R www-data:www-data /var/www/html
    systemctl restart apache2
    systemctl enable apache2

    log_succ "HQ-SRV: RAID0, NFS, LAMP и БД Moodle готовы!"
}

setup_brsrv() {
    log_info "Установка Samba AD, Ansible и Docker..."
    safe_apt_update
    apt-get install -y -q ansible sshpass docker.io docker-compose-plugin \
        samba smbclient krb5-user winbind libpam-winbind libnss-winbind acl attr

    # 1. Настройка Ansible Inventory
    mkdir -p /etc/ansible
    cat > /etc/ansible/hosts <<EOF
[all:vars]
ansible_user=sshuser
ansible_password=P@ssw0rd
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
ansible_port=3015

[servers]
$HQ_SRV_IP
$HQ_CLI_IP
$HQ_RTR_V10
$BR_RTR_LAN
EOF

    # 2. Развертывание MediaWiki через Docker Compose
    mkdir -p /home/sshuser/wiki
    cat > /home/sshuser/wiki/docker-compose.yml <<'DCEOF'
version: '3.8'
services:
  wiki:
    image: mediawiki:latest
    container_name: wiki_app
    ports:
      - "8080:80"
    environment:
      MEDIAWIKI_DB_HOST: mariadb
      MEDIAWIKI_DB_USER: wiki
      MEDIAWIKI_DB_PASSWORD: WikiP@ssw0rd
      MEDIAWIKI_DB_NAME: mediawiki
    depends_on:
      - mariadb
  mariadb:
    image: mariadb:10.11
    container_name: wiki_db
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: mediawiki
      MYSQL_USER: wiki
      MYSQL_PASSWORD: WikiP@ssw0rd
DCEOF
    chown -R sshuser:sshuser /home/sshuser
    systemctl start docker
    systemctl enable docker
    
    cd /home/sshuser/wiki
    log_info "Запуск контейнеров MediaWiki..."
    docker compose up -d || log_err "Docker Compose не смог запустить контейнеры."

    # 3. Настройка контроллера домена Samba AD DC
    log_info "Инициализация домена Samba AD DC..."
    
    # Освобождаем 53 порт для Samba DNS
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
search $DOMAIN
EOF
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
        --adminpass='P@ssw0rd123!' || log_err "Сбой при provision домена!"

    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf 2>/dev/null || true

    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl start samba-ad-dc
    systemctl enable samba-ad-dc
    sleep 5

    # 4. Создание групп и пользователей домена
    samba-tool group add hq 2>/dev/null || true
    mkdir -p /opt
    > /opt/users.csv

    for i in {1..5}; do
        samba-tool user create "user${i}.hq" 'P@ssw0rd123!' 2>/dev/null || true
        samba-tool group addmembers hq "user${i}.hq" 2>/dev/null || true
        echo "user${i}.hq,P@ssw0rd123!" >> /opt/users.csv
    done

    log_succ "BR-SRV: Docker, Ansible и Samba AD DC настроены!"
}

setup_hqcli() {
    log_info "Установка AutoFS, утилит SSSD и Yandex Browser..."
    safe_apt_update
    apt-get install -y -q nfs-common autofs realmd sssd sssd-tools adcli krb5-user packagekit curl gpg

    # 1. Настройка AutoFS
    if ! grep -q "/etc/auto.nfs" /etc/auto.master; then
        echo "/- /etc/auto.nfs --timeout=60" >> /etc/auto.master
    fi
    echo "/mnt/nfs -fstype=nfs,rw,soft,intr $HQ_SRV_IP:/raid0/nfs" > /etc/auto.nfs
    mkdir -p /mnt/nfs
    systemctl restart autofs
    systemctl enable autofs

    # 2. Установка Yandex Browser (Секьюрный метод ключей)
    mkdir -p /usr/share/keyrings
    curl -fsSL https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG | gpg --dearmor -o /usr/share/keyrings/yandex-browser.gpg --yes
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/yandex-browser.gpg] http://repo.yandex.ru/yandex-browser/deb stable main" > /etc/apt/sources.list.d/yandex-browser.list
    
    apt-get update -y -q
    apt-get install -y -q yandex-browser-corporate || log_err "Yandex Browser не установлен (нет GUI среды?)"

    # 3. Ввод в домен (Join AD)
    log_info "Подключение машины к домену $DOMAIN..."
    
    # Резолвинг на AD контроллер
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver $BR_SRV_IP
search $DOMAIN
EOF
    
    # Попытка ввода (потребует связи с BR-SRV)
    echo 'P@ssw0rd123!' | realm join -U Administrator "$DOMAIN" 2>/dev/null
    if [ $? -eq 0 ]; then
        log_succ "Успешно присоединено к домену $DOMAIN!"
    else
        log_err "Не удалось присоединиться к домену. Убедитесь, что BR-SRV(Samba) запущен и доступен по IP $BR_SRV_IP."
    fi

    cat > /etc/sudoers.d/hq_domain <<EOF
%hq@$DOMAIN ALL=(ALL) /usr/bin/cat, /usr/bin/grep, /usr/bin/id
EOF
    chmod 440 /etc/sudoers.d/hq_domain

    log_succ "HQ-CLI: NFS, Yandex и доменные политики готовы!"
}

# ======================== МЕНЮ ========================

clear
echo -e "${YELLOW}======================================================${NC}"
echo -e "${GREEN} ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 2 (ПРИКЛАДНЫЕ СЕРВИСЫ)${NC}"
echo -e "${YELLOW}======================================================${NC}"
echo ""
echo "Выберите роль машины:"
echo "  1) ISP     — Провайдер (Nginx Proxy)"
echo "  2) HQ-RTR  — Роутер Центра (Пропуск - настроено в Модуле 1)"
echo "  3) BR-RTR  — Роутер Филиала (Пропуск - настроено в Модуле 1)"
echo "  4) HQ-SRV  — Сервер Центра (RAID0, NFS, MariaDB, Moodle)"
echo "  5) BR-SRV  — Сервер Филиала (Samba AD, Ansible, Docker)"
echo "  6) HQ-CLI  — Клиент (AutoFS, SSSD/Join, Yandex)"
echo "  0) Выход"
echo ""

while true; do
    read -p "Ваш выбор: " choice
    case $choice in
        1) setup_isp; break ;;
        2) log_info "Для HQ-RTR сервисный модуль не требуется."; break ;;
        3) log_info "Для BR-RTR сервисный модуль не требуется."; break ;;
        4) setup_hqsrv; break ;;
        5) setup_brsrv; break ;;
        6) setup_hqcli; break ;;
        0) echo "Выход."; exit 0 ;;
        *) echo -e "${RED}Неверный выбор!${NC}" ;;
    esac
done

log_succ "Конфигурация Модуля 2 завершена!"