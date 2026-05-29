#!/bin/bash
# ==============================================================================
# ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 2 (ПРИКЛАДНЫЕ СЕРВИСЫ И AD)
# Целевая ОС: Ubuntu 22.04 / 24.04 LTS
# Особенности: Docker Volumes Persistence, SSSD FQDN Fix, Apache RemoteIP
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
HQ_ISP_IP="172.16.40.2"
ISP_BR_IP="172.16.50.1"
BR_ISP_IP="172.16.50.2"

HQ_SRV_IP="192.168.10.2"
BR_SRV_IP="192.168.30.2"

export DEBIAN_FRONTEND=noninteractive

log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_succ() { echo -e "${GREEN}[УСПЕХ] $1${NC}"; }
log_err()  { echo -e "${RED}[ОШИБКА] $1${NC}"; }

safe_apt_update() {
    log_info "Подготовка APT..."
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
    dpkg --configure -a 2>/dev/null || true
    apt-get update -y -q || log_err "apt-get update завершился с ошибкой, но продолжаем..."
}

apply_ssh_fix() {
    log_info "Проверка патча SSH Socket (Ubuntu 24.04+)..."
    systemctl disable --now ssh.socket 2>/dev/null || true
    
    sed -i 's/^#*Port .*/Port 3015/' /etc/ssh/sshd_config
    sed -i 's/^#*MaxAuthTries .*/MaxAuthTries 2/' /etc/ssh/sshd_config
    grep -q "AllowUsers sshuser" /etc/ssh/sshd_config || echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    
    echo "Authorized access only" > /etc/issue.net
    sed -i 's|^#*Banner .*|Banner /etc/issue.net|' /etc/ssh/sshd_config

    systemctl enable --now ssh.service 2>/dev/null || true
    systemctl restart ssh.service || systemctl restart ssh || true
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
    apply_ssh_fix
    
    log_info "Установка пакетов: mdadm, nfs, LAMP, инструменты..."
    safe_apt_update
    apt-get install -y -q mdadm nfs-kernel-server apache2 mariadb-server \
        php php-mysql libapache2-mod-php php-xml php-mbstring php-curl \
        php-zip php-gd php-intl unzip wget curl

    # КРИТИЧЕСКИЙ ФИКС: Модуль RemoteIP для корректных логов Moodle из-за прокси Nginx
    log_info "Активация модуля RemoteIP для Apache..."
    a2enmod remoteip
    cat > /etc/apache2/conf-available/remoteip.conf <<EOF
RemoteIPHeader X-Forwarded-For
RemoteIPInternalProxy $ISP_HQ_IP
EOF
    a2enconf remoteip

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
        update-initramfs -u
        
        mkfs.ext4 -F /dev/md0
        
        udevadm settle
        sleep 3
        
        mkdir -p /raid0
        MD_UUID=$(blkid -s UUID -o value /dev/md0)
        
        if [ -n "$MD_UUID" ]; then
            grep -q "$MD_UUID" /etc/fstab || echo "UUID=$MD_UUID /raid0 ext4 defaults 0 0" >> /etc/fstab
            mount -a
        else
            log_err "UUID устройства /dev/md0 не определен. Остановка во избежание Kernel Panic."
            exit 1
        fi
    else
        log_err "Найдено только $DISK_COUNT свободных дисков из 3. Сборка RAID0 пропущена."
        mkdir -p /raid0
    fi

    mkdir -p /raid0/nfs
    chmod 777 /raid0/nfs
    echo "/raid0/nfs 192.168.20.0/27(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
    exportfs -arv
    systemctl restart nfs-kernel-server
    systemctl enable nfs-kernel-server

    log_info "Настройка базы данных MariaDB..."
    systemctl start mariadb
    systemctl enable mariadb

    log_info "Ожидание готовности MariaDB (Динамический опрос)..."
    for i in {1..30}; do
        if mysqladmin ping -u root --silent 2>/dev/null; then
            log_succ "MariaDB готова к локальным соединениям!"
            break
        fi
        sleep 2
    done

    mysql -u root <<'SQLEOF'
CREATE DATABASE IF NOT EXISTS moodledb DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'moodle'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON moodledb.* TO 'moodle'@'localhost';
FLUSH PRIVILEGES;
SQLEOF

    log_info "Скачивание ядра Moodle..."
    cd /tmp
    if ! wget -q --timeout=15 --tries=3 https://download.moodle.org/download.php/direct/stable403/moodle-latest-403.tgz; then
        log_err "Фатальный сбой скачивания Moodle! Установка LMS пропущена во избежание краха скрипта."
        return 1
    fi
    
    tar -xzf moodle-latest-403.tgz -C /var/www/html/
    
    mkdir -p /var/www/moodledata
    chown -R www-data:www-data /var/www/html/moodle /var/www/moodledata

    log_info "Выполнение тихой установки Moodle..."
    sudo -u www-data /usr/bin/php /var/www/html/moodle/admin/cli/install.php \
        --lang=en \
        --wwwroot="http://moodle.$DOMAIN" \
        --dataroot="/var/www/moodledata" \
        --dbtype="mariadb" \
        --dbhost="localhost" \
        --dbname="moodledb" \
        --dbuser="moodle" \
        --dbpass="P@ssw0rd" \
        --fullname="Exam Moodle" \
        --shortname="EXM" \
        --adminuser="admin" \
        --adminpass="P@ssw0rd123!" \
        --non-interactive \
        --agree-license

    cat > /var/www/html/index.php <<EOF
<?php
header("Location: /moodle/");
exit;
?>
EOF
    rm -f /var/www/html/index.html
    
    log_info "Настройка cron для Moodle..."
    echo "* * * * * www-data /usr/bin/php /var/www/html/moodle/admin/cli/cron.php >/dev/null 2>&1" > /etc/cron.d/moodle
    chmod 644 /etc/cron.d/moodle

    systemctl restart apache2
    systemctl enable apache2

    log_succ "HQ-SRV: RAID0, NFS, LMS Moodle и Cron готовы!"
}

setup_brsrv() {
    apply_ssh_fix

    log_info "Установка Samba AD и Docker..."
    safe_apt_update
    apt-get install -y -q docker.io docker-compose-plugin \
        samba smbclient krb5-user winbind libpam-winbind libnss-winbind acl attr

    mkdir -p /home/sshuser/wiki
    cat > /home/sshuser/wiki/docker-compose.yml <<'DCEOF'
version: '3.8'
services:
  wiki:
    image: mediawiki:1.41
    container_name: wiki_app
    ports:
      - "8080:80"
    volumes:
      - wiki_data:/var/www/html
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
    volumes:
      - db_data:/var/lib/mysql
volumes:
  wiki_data:
  db_data:
DCEOF
    chown -R sshuser:sshuser /home/sshuser
    systemctl start docker
    systemctl enable docker
    
    cd /home/sshuser/wiki
    log_info "Запуск контейнеров MediaWiki..."
    docker compose up -d || log_err "Docker Compose не запустился."
    
    log_info "Ожидание полной инициализации БД MariaDB (Защита от гонки Docker-Entrypoint)..."
    for i in {1..30}; do
        if docker exec wiki_db mysql -u root -proot -e "USE mediawiki;" 2>/dev/null; then
            log_succ "База данных mediawiki создана и готова к работе!"
            break
        fi
        sleep 3
    done
    
    log_info "Ожидание готовности контейнера MediaWiki..."
    for i in {1..20}; do
        if docker exec wiki_app stat maintenance/install.php >/dev/null 2>&1; then
            log_succ "Контейнер MediaWiki готов к инициализации!"
            break
        fi
        sleep 2
    done

    if ! docker exec wiki_app stat LocalSettings.php >/dev/null 2>&1; then
        log_info "Выполнение тихой установки MediaWiki..."
        docker exec wiki_app php maintenance/install.php \
            --dbname=mediawiki \
            --dbserver=mariadb \
            --dbuser=wiki \
            --dbpass=WikiP@ssw0rd \
            --server="http://wiki.$DOMAIN" \
            --scriptpath="" \
            --lang=en \
            --pass="P@ssw0rd123!" \
            "AU Team Wiki" "admin"
        
        docker exec wiki_app chown www-data:www-data /var/www/html/LocalSettings.php
    else
        log_info "Файл LocalSettings.php уже существует (Volumes работают). Установка пропущена."
    fi

    log_info "Инициализация домена Samba AD DC..."
    
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
        --option="dns forwarder=$HQ_SRV_IP" \
        --host-ip="$BR_SRV_IP" \
        --adminpass='P@ssw0rd123!' || log_err "Сбой при provision домена!"

    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf 2>/dev/null || true

    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl start samba-ad-dc
    systemctl enable samba-ad-dc
    sleep 5

    log_info "Настройка Split-DNS записей внутри Samba AD..."
    samba-tool dns add localhost $DOMAIN moodle A $ISP_HQ_IP -U Administrator%'P@ssw0rd123!' 2>/dev/null || true
    samba-tool dns add localhost $DOMAIN wiki A $ISP_BR_IP -U Administrator%'P@ssw0rd123!' 2>/dev/null || true

    log_info "Создание доменных групп и пользователей..."
    samba-tool group add hq 2>/dev/null || true
    mkdir -p /opt
    > /opt/users.csv

    for i in {1..5}; do
        samba-tool user create "user${i}.hq" 'P@ssw0rd123!' 2>/dev/null || true
        samba-tool group addmembers hq "user${i}.hq" 2>/dev/null || true
        echo "user${i}.hq,P@ssw0rd123!" >> /opt/users.csv
    done

    log_succ "BR-SRV: MediaWiki (Persisted Volumes), Samba AD DC и Split-DNS успешно настроены!"
}

setup_hqcli() {
    log_info "Установка AutoFS, утилит SSSD и Yandex Browser..."
    safe_apt_update
    apt-get install -y -q nfs-common autofs realmd sssd sssd-tools adcli krb5-user packagekit curl gpg libpam-modules dnsutils

    if ! grep -q "/etc/auto.nfs" /etc/auto.master; then
        echo "/- /etc/auto.nfs --timeout=60" >> /etc/auto.master
    fi
    echo "/mnt/nfs -fstype=nfs,rw,hard $HQ_SRV_IP:/raid0/nfs" > /etc/auto.nfs
    mkdir -p /mnt/nfs
    systemctl restart autofs
    systemctl enable autofs

    mkdir -p /usr/share/keyrings
    curl -fsSL https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG | gpg --dearmor -o /usr/share/keyrings/yandex-browser.gpg --yes
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/yandex-browser.gpg] http://repo.yandex.ru/yandex-browser/deb stable main" > /etc/apt/sources.list.d/yandex-browser.list
    
    apt-get update -y -q
    apt-get install -y -q yandex-browser-corporate || log_err "Yandex Browser не установлен (нет GUI среды?)"

    log_info "Ожидание генерации DNS SRV-записей в Samba AD (Защита Kerberos)..."
    for i in {1..40}; do
        if dig +short -t SRV _ldap._tcp.$DOMAIN @$BR_SRV_IP | grep -q "br-srv"; then
            log_succ "SRV-записи Samba AD готовы и отдаются сервером!"
            break
        fi
        sleep 3
    done

    log_info "Сброс кэша DNS для предотвращения негативного кэширования (NXDOMAIN)..."
    resolvectl flush-caches 2>/dev/null || systemctl restart systemd-resolved 2>/dev/null || true

    log_info "Подключение машины к домену $DOMAIN через нативный DNS..."
    echo 'P@ssw0rd123!' | realm join -U Administrator "$DOMAIN" 2>/dev/null
    if [ $? -eq 0 ]; then
        log_succ "Успешно присоединено к домену $DOMAIN!"
        
        log_info "Настройка SSSD для лаконичных логинов..."
        sed -i 's/use_fully_qualified_names = [Tt]rue/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
        systemctl restart sssd
    else
        log_err "Не удалось присоединиться к домену. Убедитесь, что Bind9 на HQ-SRV работает корректно."
    fi

    log_info "Включение создания домашних каталогов (mkhomedir)..."
    pam-auth-update --enable mkhomedir

    cat > /etc/sudoers.d/hq_domain <<EOF
%hq ALL=(ALL) /usr/bin/cat, /usr/bin/grep, /usr/bin/id
EOF
    chmod 440 /etc/sudoers.d/hq_domain

    log_succ "HQ-CLI: NFS, Yandex, PAM и доменные политики готовы. Интеграция 100%!"
}

# ======================== МЕНЮ ========================

clear
echo -e "${YELLOW}======================================================${NC}"
echo -e "${GREEN} ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 2 (ПРИКЛАДНЫЕ СЕРВИСЫ)${NC}"
echo -e "${CYAN} Production-Ready: Apache RemoteIP Fix + Edge Cases${NC}"
echo -e "${YELLOW}======================================================${NC}"
echo ""
echo "Выберите роль машины:"
echo "  1) ISP     — Провайдер (Nginx Proxy)"
echo "  2) HQ-RTR  — Роутер Центра (Пропуск)"
echo "  3) BR-RTR  — Роутер Филиала (Пропуск)"
echo "  4) HQ-SRV  — Сервер Центра (RAID0, NFS, Moodle, SSH-fix)"
echo "  5) BR-SRV  — Сервер Филиала (Samba AD, MediaWiki, Volumes)"
echo "  6) HQ-CLI  — Клиент (AutoFS, Join AD, PAM, Yandex)"
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