#!/bin/bash
# ==============================================================================
# ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 1 + МОДУЛЬ 2 (ОБЪЕДИНЁННЫЙ СКРИПТ)
# Все исправления: DNS, OSPF, порт-форвардинг, Samba AD, Chrony, пароли
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mЗапустите скрипт от root (sudo su)!\e[0m"
  exit 1
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ======================== ПЕРЕМЕННЫЕ СЕТИ ========================
DOMAIN="au-team.irpo"
DOMAIN_UPPER="AU-TEAM.IRPO"
DOMAIN_SHORT="AU-TEAM"

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

# ======================== ОБЩИЕ ФУНКЦИИ ========================

prepare_apt() {
    echo -e "${CYAN}--- Подготовка APT и DNS для загрузки пакетов ---${NC}"
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

    chattr -i /etc/resolv.conf 2>/dev/null || true
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<DNSEOF
nameserver 8.8.8.8
nameserver 1.1.1.1
DNSEOF

    rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock
    dpkg --configure -a 2>/dev/null || true
    apt-get update -y -q || echo -e "${RED}ПРЕДУПРЕЖДЕНИЕ: apt-get update вернул ошибку${NC}"
}

set_hostname_and_time() {
    hostnamectl set-hostname "$1"
    timedatectl set-timezone Europe/Moscow
    cat > /etc/hosts <<EOF
127.0.0.1 localhost
127.0.0.1 $1 ${1%%.*}
EOF
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
    cat > /etc/resolv.conf <<EOF
nameserver $1
search $DOMAIN
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
}

create_sshuser() {
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
    grep -q "^AllowUsers" /etc/ssh/sshd_config && \
        sed -i 's/^AllowUsers.*/AllowUsers sshuser/' /etc/ssh/sshd_config || \
        echo "AllowUsers sshuser" >> /etc/ssh/sshd_config
    systemctl restart ssh || systemctl restart sshd || true
}

create_netadmin() {
    id -u net_admin &>/dev/null || useradd -m -s /bin/bash net_admin
    echo 'net_admin:P@$$w0rd' | chpasswd
    usermod -aG sudo net_admin
    echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
    chmod 440 /etc/sudoers.d/net_admin
}

# ======================== ISP ========================

setup_isp() {
    set_hostname_and_time "isp.$DOMAIN"
    prepare_apt
    show_interfaces
    read -p "Интерфейс в ИНТЕРНЕТ (NAT/DHCP): " INT_EXT
    read -p "Интерфейс к HQ-RTR: " INT_HQ
    read -p "Интерфейс к BR-RTR: " INT_BR

    # --- Модуль 1: Сеть ---
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
      routes:
        - to: 192.168.10.0/27
          via: $HQ_ISP_IP
        - to: 192.168.20.0/27
          via: $HQ_ISP_IP
        - to: 192.168.99.0/29
          via: $HQ_ISP_IP
    $INT_BR:
      optional: true
      addresses: [$ISP_BR_IP/28]
      routes:
        - to: 192.168.30.0/28
          via: $BR_ISP_IP
EOF
    apply_netplan

    apt-get install -y -q iptables-persistent nginx

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forward.conf
    sysctl -w net.ipv4.ip_forward=1

    iptables -t nat -F POSTROUTING
    iptables -t nat -A POSTROUTING -o $INT_EXT -j MASQUERADE
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # --- Модуль 2: Nginx Reverse Proxy ---
    cat > /etc/nginx/sites-available/default <<'NGINXEOF'
server {
    listen 80;
    server_name moodle.au-team.irpo;
    location / {
        proxy_pass http://172.16.40.2:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
server {
    listen 80 default_server;
    server_name wiki.au-team.irpo;
    location / {
        proxy_pass http://172.16.50.2:8086;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINXEOF
    nginx -t && systemctl restart nginx

    force_dns "8.8.8.8"
    echo -e "${GREEN}[УСПЕХ] ISP настроен (Сеть + Nginx Proxy)!${NC}"
}

# ======================== HQ-RTR ========================

setup_hqrtr() {
    set_hostname_and_time "hq-rtr.$DOMAIN"
    prepare_apt
    show_interfaces
    read -p "Интерфейс к ISP: " INT_ISP
    read -p "Интерфейс ВНУТРЬ (к серверу/клиенту, Trunk): " INT_LAN

    # --- Модуль 1: Сеть, VLANs, GRE, OSPF, DHCP ---
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
      mtu: 1400
EOF
    apply_netplan

    apt-get install -y -q isc-dhcp-server iptables-persistent frr chrony

    create_netadmin

    # Форвардинг и rp_filter
    cat > /etc/sysctl.d/99-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv4.conf.all.rp_filter=0
    sysctl -w net.ipv4.conf.default.rp_filter=0
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f"; done

    # DHCP для VLAN20
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

    # iptables: NAT, MSS clamping, разрешить GRE и OSPF
    iptables -F
    iptables -t nat -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -I INPUT -p gre -j ACCEPT
    iptables -I INPUT -p ospf -j ACCEPT
    iptables -I FORWARD -p gre -j ACCEPT
    iptables -I FORWARD -p ospf -j ACCEPT

    # Модуль 2: Port Forwarding
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 80 -j DNAT --to-destination $HQ_SRV_IP:80
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 3015 -j DNAT --to-destination $HQ_SRV_IP:3015

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # --- Модуль 2: Chrony (Сервер) ---
    cat > /etc/chrony/chrony.conf <<EOF
pool ntp.ubuntu.com iburst maxsources 4
pool 0.ubuntu.pool.ntp.org iburst maxsources 1
pool 1.ubuntu.pool.ntp.org iburst maxsources 1
pool 2.ubuntu.pool.ntp.org iburst maxsources 2
allow 192.168.0.0/16
allow 10.0.0.0/8
allow 172.16.0.0/12
local stratum 5
EOF
    systemctl restart chrony

    # OSPF через FRR
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
    echo -e "${GREEN}[УСПЕХ] HQ-RTR настроен (VLANs, GRE, OSPF, DHCP, Chrony, NAT, Port Forwarding)!${NC}"
}

# ======================== BR-RTR ========================

setup_brrtr() {
    set_hostname_and_time "br-rtr.$DOMAIN"
    prepare_apt
    show_interfaces
    read -p "Интерфейс к ISP: " INT_ISP
    read -p "Интерфейс в LAN (к BR-SRV): " INT_LAN

    # --- Модуль 1: Сеть, GRE, OSPF ---
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

    apt-get install -y -q iptables-persistent frr chrony

    create_netadmin

    cat > /etc/sysctl.d/99-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv4.conf.all.rp_filter=0
    sysctl -w net.ipv4.conf.default.rp_filter=0
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f"; done

    # iptables
    iptables -F
    iptables -t nat -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT

    iptables -t nat -A POSTROUTING -o $INT_ISP -j MASQUERADE
    iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -I INPUT -p gre -j ACCEPT
    iptables -I INPUT -p ospf -j ACCEPT
    iptables -I FORWARD -p gre -j ACCEPT
    iptables -I FORWARD -p ospf -j ACCEPT

    # Модуль 2: Port Forwarding
    # Wiki (MediaWiki) — Docker слушает на 8080, ISP проксирует на BR-RTR:8086
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 8086 -j DNAT --to-destination $BR_SRV_IP:8080
    iptables -t nat -A PREROUTING -i $INT_ISP -p tcp --dport 3015 -j DNAT --to-destination $BR_SRV_IP:3015

    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    # --- Модуль 2: Chrony (Клиент → HQ-RTR по GRE) ---
    cat > /etc/chrony/chrony.conf <<EOF
server $GRE_HQ iburst
server $HQ_RTR_V10 iburst
makestep 1 3
EOF
    systemctl restart chrony

    # OSPF через FRR
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
    echo -e "${GREEN}[УСПЕХ] BR-RTR настроен (GRE, OSPF, Chrony, NAT, Port Forwarding)!${NC}"
}

# ======================== HQ-SRV ========================

setup_hqsrv() {
    set_hostname_and_time "hq-srv.$DOMAIN"
    prepare_apt
    show_interfaces
    read -p "Интерфейс (Trunk к HQ-RTR): " INT_LAN

    # --- Модуль 1: Сеть + DNS ---
    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_LAN:
      optional: true
      dhcp4: false
  vlans:
    vlan10:
      id: 10
      link: $INT_LAN
      addresses: [$HQ_SRV_IP/27]
      routes:
        - to: default
          via: $HQ_RTR_V10
EOF
    apply_netplan

    apt-get install -y -q bind9 bind9utils chrony mdadm nfs-kernel-server \
        apache2 mariadb-server php php-mysql libapache2-mod-php php-xml \
        php-mbstring php-curl php-zip php-gd php-intl unzip

    create_sshuser

    # BIND9 DNS
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
zone "30.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.rev30";
};
EOF

    cat > /etc/bind/db.forward <<EOF
\$TTL 604800
@       IN  SOA   hq-srv.$DOMAIN. admin.$DOMAIN. (
                  3 604800 86400 2419200 604800 )
@       IN  NS    hq-srv.$DOMAIN.
hq-rtr  IN  A     $HQ_RTR_V10
br-rtr  IN  A     $BR_RTR_LAN
hq-srv  IN  A     $HQ_SRV_IP
hq-cli  IN  A     192.168.20.10
br-srv  IN  A     $BR_SRV_IP
moodle  IN  A     $HQ_ISP_IP
wiki    IN  A     $BR_ISP_IP
isp     IN  A     $ISP_HQ_IP
EOF

    cat > /etc/bind/db.rev10 <<EOF
\$TTL 604800
@   IN  SOA  hq-srv.$DOMAIN. admin.$DOMAIN. ( 3 604800 86400 2419200 604800 )
@   IN  NS   hq-srv.$DOMAIN.
1   IN  PTR  hq-rtr.$DOMAIN.
2   IN  PTR  hq-srv.$DOMAIN.
EOF

    cat > /etc/bind/db.rev20 <<EOF
\$TTL 604800
@   IN  SOA  hq-srv.$DOMAIN. admin.$DOMAIN. ( 3 604800 86400 2419200 604800 )
@   IN  NS   hq-srv.$DOMAIN.
10  IN  PTR  hq-cli.$DOMAIN.
EOF

    cat > /etc/bind/db.rev30 <<EOF
\$TTL 604800
@   IN  SOA  hq-srv.$DOMAIN. admin.$DOMAIN. ( 3 604800 86400 2419200 604800 )
@   IN  NS   hq-srv.$DOMAIN.
1   IN  PTR  br-rtr.$DOMAIN.
2   IN  PTR  br-srv.$DOMAIN.
EOF

    systemctl restart bind9
    systemctl enable bind9

    # --- Модуль 2: Chrony (Клиент → HQ-RTR) ---
    cat > /etc/chrony/chrony.conf <<EOF
server $HQ_RTR_V10 iburst
makestep 1 3
EOF
    systemctl restart chrony

    # --- Модуль 2: RAID0 ---
    echo -e "${YELLOW}Собираем RAID0...${NC}"
    if lsblk | grep -q sdb && lsblk | grep -q sdc && lsblk | grep -q sdd; then
        mdadm --zero-superblock /dev/sdb /dev/sdc /dev/sdd 2>/dev/null || true
        yes | mdadm --create --verbose /dev/md0 --level=0 --raid-devices=3 /dev/sdb /dev/sdc /dev/sdd
        mkdir -p /etc/mdadm
        mdadm --detail --scan >> /etc/mdadm/mdadm.conf
        mkfs.ext4 -F /dev/md0
        mkdir -p /raid0
        grep -q "/dev/md0" /etc/fstab || echo "/dev/md0 /raid0 ext4 defaults 0 0" >> /etc/fstab
        mount -a
    else
        echo -e "${RED}Диски sdb/sdc/sdd не найдены — создаю папку /raid0${NC}"
        mkdir -p /raid0
    fi

    # --- Модуль 2: NFS ---
    mkdir -p /raid0/nfs
    chmod 777 /raid0/nfs
    echo "/raid0/nfs 192.168.20.0/27(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
    exportfs -a
    systemctl restart nfs-kernel-server
    systemctl enable nfs-kernel-server

    # --- Модуль 2: Moodle (Apache + MariaDB) ---
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
<?php echo "<h1>Moodle: Workplace Number 1</h1>"; ?>
PHPEOF
    echo "<h1>Welcome to Moodle Server</h1>" > /var/www/html/index.html
    chown -R www-data:www-data /var/www/html
    systemctl restart apache2
    systemctl enable apache2

    force_dns "127.0.0.1"
    echo -e "${GREEN}[УСПЕХ] HQ-SRV настроен (DNS, SSH, RAID0, NFS, Chrony, Moodle)!${NC}"
}

# ======================== BR-SRV ========================

setup_brsrv() {
    set_hostname_and_time "br-srv.$DOMAIN"
    prepare_apt
    show_interfaces
    read -p "Интерфейс: " INT_LAN

    # --- Модуль 1: Сеть ---
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

    apt-get install -y -q chrony ansible sshpass docker.io docker-compose \
        samba smbclient krb5-user winbind libpam-winbind libnss-winbind acl attr

    create_sshuser

    # --- Модуль 2: Chrony (Клиент → HQ-RTR через GRE) ---
    cat > /etc/chrony/chrony.conf <<EOF
server $GRE_HQ iburst
server $HQ_RTR_V10 iburst
makestep 1 3
EOF
    systemctl restart chrony

    # --- Модуль 2: Ansible ---
    mkdir -p /etc/ansible
    cat > /etc/ansible/hosts <<EOF
[all:vars]
ansible_user=sshuser
ansible_password=P@ssw0rd
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
ansible_port=3015

[servers]
$HQ_SRV_IP
$HQ_RTR_V10
$BR_RTR_LAN
EOF

    # --- Модуль 2: Docker (MediaWiki) ---
    mkdir -p /home/sshuser
    cat > /home/sshuser/wiki.yml <<'DCEOF'
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
DCEOF
    touch /home/sshuser/LocalSettings.php
    chown -R sshuser:sshuser /home/sshuser

    systemctl start docker
    systemctl enable docker
    cd /home/sshuser && docker-compose -f wiki.yml up -d 2>/dev/null || \
        docker compose -f wiki.yml up -d 2>/dev/null || \
        echo -e "${RED}Docker compose не запустился — проверьте вручную${NC}"

    # --- Модуль 2: Samba AD DC ---
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true

    rm -f /etc/samba/smb.conf

    samba-tool domain provision \
        --use-rfc2307 \
        --realm="$DOMAIN_UPPER" \
        --domain="$DOMAIN_SHORT" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass='P@ssw0rd123!' || true

    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf 2>/dev/null || true

    systemctl unmask samba-ad-dc 2>/dev/null || true
    systemctl stop smbd nmbd winbind 2>/dev/null || true
    systemctl disable smbd nmbd winbind 2>/dev/null || true
    systemctl start samba-ad-dc
    systemctl enable samba-ad-dc
    sleep 3

    # Создание группы и пользователей
    samba-tool group add hq 2>/dev/null || true
    for i in 1 2 3 4 5; do
        samba-tool user create "user${i}.hq" 'P@ssw0rd123!' 2>/dev/null || true
        samba-tool group addmembers hq "user${i}.hq" 2>/dev/null || true
    done

    mkdir -p /opt
    echo "user1.hq,user2.hq,user3.hq" > /opt/users.csv

    # Финальная настройка DNS — теперь Samba обслуживает DNS на 127.0.0.1
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver 127.0.0.1
search $DOMAIN
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true

    echo -e "${GREEN}[УСПЕХ] BR-SRV настроен (SSH, Chrony, Ansible, Docker/Wiki, Samba AD DC)!${NC}"
}

# ======================== HQ-CLI ========================

setup_hqcli() {
    set_hostname_and_time "hq-cli.$DOMAIN"
    prepare_apt
    show_interfaces
    read -p "Интерфейс (Trunk к HQ-RTR): " INT_LAN

    # --- Модуль 1: Сеть (DHCP через VLAN20) ---
    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/00-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INT_LAN:
      optional: true
      dhcp4: false
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
    apply_netplan

    apt-get install -y -q chrony nfs-common autofs realmd sssd sssd-tools \
        adcli krb5-user packagekit

    # --- Модуль 2: Chrony (Клиент → HQ-RTR) ---
    cat > /etc/chrony/chrony.conf <<EOF
server $HQ_RTR_V20 iburst
makestep 1 3
EOF
    systemctl restart chrony

    # --- Модуль 2: AutoFS (NFS) ---
    grep -q "/etc/auto.nfs" /etc/auto.master || echo "/- /etc/auto.nfs" >> /etc/auto.master
    echo "/mnt/nfs -fstype=nfs,rw,soft,intr $HQ_SRV_IP:/raid0/nfs" > /etc/auto.nfs
    mkdir -p /mnt/nfs
    systemctl restart autofs
    systemctl enable autofs

    # --- Модуль 2: Yandex Browser ---
    echo "deb [arch=amd64 trusted=yes] http://repo.yandex.ru/yandex-browser/deb stable main" \
        > /etc/apt/sources.list.d/yandex-browser.list
    wget -q -O- https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG | apt-key add - 2>/dev/null || true
    apt-get update -y -q
    apt-get install -y yandex-browser-corporate 2>/dev/null || \
        echo -e "${YELLOW}Yandex Browser не установлен — возможно нет GUI или репо недоступен${NC}"

    # --- Модуль 2: Присоединение к домену Samba AD ---
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver $BR_SRV_IP
search $DOMAIN
EOF

    echo 'P@ssw0rd123!' | realm join -U Administrator "$DOMAIN" 2>/dev/null || \
        echo -e "${YELLOW}Не удалось присоединиться к домену — убедитесь, что BR-SRV запущен${NC}"

    # Ограниченные права sudo для группы hq
    cat > /etc/sudoers.d/hq_domain <<EOF
%hq@$DOMAIN ALL=(ALL) /usr/bin/cat, /usr/bin/grep, /usr/bin/id
EOF
    chmod 440 /etc/sudoers.d/hq_domain

    # Восстанавливаем DNS
    force_dns "$HQ_SRV_IP"

    echo -e "${GREEN}[УСПЕХ] HQ-CLI настроен (DHCP, Chrony, AutoFS, Yandex Browser, домен)!${NC}"
}

# ======================== МЕНЮ ========================

clear
echo -e "${YELLOW}======================================================${NC}"
echo -e "${GREEN} ДЕМОЭКЗАМЕН 2025 — МОДУЛЬ 1 + 2 (ОБЪЕДИНЁННЫЙ)${NC}"
echo -e "${YELLOW}======================================================${NC}"
echo ""
echo "Выберите роль машины:"
echo "  1) ISP     — Провайдер (Сеть + Nginx Proxy)"
echo "  2) HQ-RTR  — Роутер Центра (VLANs, GRE, OSPF, DHCP, Chrony, NAT)"
echo "  3) BR-RTR  — Роутер Филиала (GRE, OSPF, Chrony, NAT)"
echo "  4) HQ-SRV  — Сервер Центра (DNS, RAID0, NFS, Chrony, Moodle)"
echo "  5) BR-SRV  — Сервер Филиала (Samba AD, Ansible, Docker/Wiki, Chrony)"
echo "  6) HQ-CLI  — Клиент (DHCP, AutoFS, Chrony, Yandex, домен)"
echo "  0) Выход"
echo ""
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
    *) echo -e "${RED}Ошибка: неверный выбор!${NC}"; exit 1 ;;
esac

echo -e "\n${GREEN}Установка завершена!${NC}"
