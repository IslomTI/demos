Если на экзамене тебе запретят пользоваться готовыми скриптами (или ты просто захочешь сделать всё руками, чтобы полностью контролировать процесс), вот подробная пошаговая инструкция.
Это перевод нашего идеального скрипта в ручные команды. Я сгруппировал их так, чтобы ты мог просто копировать и вставлять блоки текста.
⚠️ Подготовка (ОБЩЕЕ ДЛЯ ВСЕХ МАШИН)
Сразу после входа в систему на каждой машине сделай это:
 * Перейди в режим суперпользователя: sudo su
 * Посмотри, как называются твои сетевые интерфейсы: ip a (запомни их, например ens33 или ens37, они понадобятся для Netplan).
 * Временно дай машине интернет для скачивания пакетов:
   echo "nameserver 8.8.8.8" > /etc/resolv.conf
apt-get update

🖥️ Машина 1: ISP (Провайдер)
1. Имя и время:
hostnamectl set-hostname isp.au-team.irpo
timedatectl set-timezone Europe/Moscow

2. Настройка сети (Netplan):
Открой файл: nano /etc/netplan/00-config.yaml и впиши (замени ensXX на свои):
network:
  version: 2
  ethernets:
    ens_internet:
      dhcp4: true
    ens_hq:
      addresses: [172.16.40.1/28]
    ens_br:
      addresses: [172.16.50.1/28]

Примени: netplan apply
3. Маршрутизация и NAT:
# Включаем пересылку пакетов
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Включаем NAT (замени ens_internet на интерфейс, смотрящий в инет)
iptables -t nat -A POSTROUTING -o ens_internet -j MASQUERADE

# Указываем, где искать внутренние сети офисов
ip route add 192.168.10.0/24 via 172.16.40.2
ip route add 192.168.20.0/24 via 172.16.40.2
ip route add 192.168.30.0/24 via 172.16.50.2

🖥️ Машина 2: HQ-RTR (Роутер Центра)
1. Имя, время и учетка:
hostnamectl set-hostname hq-rtr.au-team.irpo
timedatectl set-timezone Europe/Moscow

useradd -m -s /bin/bash net_admin
echo "net_admin:P@\$\$w0rd" | chpasswd
usermod -aG sudo net_admin
echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin

2. Установка пакетов:
apt-get install -y isc-dhcp-server frr

3. Сеть, VLAN и GRE (Netplan):
nano /etc/netplan/00-config.yaml
network:
  version: 2
  ethernets:
    ens_isp:
      addresses: [172.16.40.2/28]
      routes:
        - to: default
          via: 172.16.40.1
    ens_lan:
      dhcp4: false
  vlans:
    vlan10:
      id: 10
      link: ens_lan
      addresses: [192.168.10.1/27]
    vlan20:
      id: 20
      link: ens_lan
      addresses: [192.168.20.1/27]
    vlan99:
      id: 99
      link: ens_lan
      addresses: [192.168.99.1/29]
  tunnels:
    gre1:
      mode: gre
      local: 172.16.40.2
      remote: 172.16.50.2
      addresses: [10.0.0.1/30]
      mtu: 1400

Примени: netplan apply
4. Фиксы маршрутизации:
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > $f; done
sed -i 's/rp_filter=1/rp_filter=0/g' /etc/sysctl.conf
sysctl -p

iptables -t nat -A POSTROUTING -o ens_isp -j MASQUERADE
iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

5. DHCP сервер:
В файле nano /etc/default/isc-dhcp-server измени: INTERFACESv4="vlan20"
В файле nano /etc/dhcp/dhcpd.conf добавь в конец:
authoritative;
subnet 192.168.20.0 netmask 255.255.255.224 {
  range 192.168.20.10 192.168.20.30;
  option routers 192.168.20.1;
  option domain-name-servers 192.168.10.2;
  option domain-name "au-team.irpo";
}

Перезапусти: systemctl restart isc-dhcp-server
6. OSPF (FRR):
nano /etc/frr/daemons (поменяй ospfd=no на ospfd=yes), затем systemctl restart frr. Зайди в vtysh:
vtysh
conf t
router ospf
 ospf router-id 1.1.1.1
 network 10.0.0.0/30 area 0
 network 192.168.10.0/27 area 0
 network 192.168.20.0/27 area 0
 network 192.168.99.0/29 area 0
 passive-interface default
 no passive-interface gre1
exit
interface gre1
 ip ospf network point-to-point
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
end
write
exit

🖥️ Машина 3: BR-RTR (Роутер Филиала)
Делается почти идентично HQ-RTR.
1. Имя, учетка, пакеты:
hostnamectl set-hostname br-rtr.au-team.irpo
timedatectl set-timezone Europe/Moscow
useradd -m -s /bin/bash net_admin
echo "net_admin:P@\$\$w0rd" | chpasswd
usermod -aG sudo net_admin
echo "net_admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/net_admin
apt-get install -y frr

2. Сеть (Netplan):
network:
  version: 2
  ethernets:
    ens_isp:
      addresses: [172.16.50.2/28]
      routes:
        - to: default
          via: 172.16.50.1
    ens_lan:
      addresses: [192.168.30.1/28]
  tunnels:
    gre1:
      mode: gre
      local: 172.16.50.2
      remote: 172.16.40.2
      addresses: [10.0.0.2/30]
      mtu: 1400

Примени: netplan apply. Повтори "Фиксы маршрутизации" из HQ-RTR.
3. OSPF (FRR): (Включи ospfd=yes в /etc/frr/daemons, рестарт).
vtysh
conf t
router ospf
 ospf router-id 2.2.2.2
 network 10.0.0.0/30 area 0
 network 192.168.30.0/28 area 0
 passive-interface default
 no passive-interface gre1
exit
interface gre1
 ip ospf network point-to-point
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
end
write
exit

🖥️ Машины 4 и 5: HQ-SRV и BR-SRV (Серверы)
(Здесь показываю на примере HQ-SRV, на BR-SRV делай то же самое, но с его IP: 192.168.30.2 и шлюзом 192.168.30.1, без настройки DNS)
1. Имя, SSH и пользователи:
hostnamectl set-hostname hq-srv.au-team.irpo
timedatectl set-timezone Europe/Moscow

useradd -m -s /bin/bash -u 1015 sshuser
echo "sshuser:P@ssw0rd" | chpasswd
usermod -aG sudo sshuser
echo "sshuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sshuser

apt-get install -y openssh-server bind9 bind9utils
echo "Authorized access only" > /etc/issue.net

В файле nano /etc/ssh/sshd_config раскомментируй/измени:
 * Port 3015
 * Banner /etc/issue.net
 * MaxAuthTries 2
 * Добавь в конец: AllowUsers sshuser
   Рестарт: systemctl restart ssh
2. Сеть (Netplan на HQ-SRV):
network:
  version: 2
  ethernets:
    ens_lan:
      dhcp4: false
  vlans:
    vlan10:
      id: 10
      link: ens_lan
      addresses: [192.168.10.2/27]
      routes:
        - to: default
          via: 192.168.10.1

netplan apply
3. Настройка DNS (Только на HQ-SRV):
nano /etc/bind/named.conf.options: Внутри блока options { ... } добавь forwarders { 8.8.8.8; }; и allow-query { any; };
nano /etc/bind/named.conf.local:
zone "au-team.irpo" { type master; file "/etc/bind/db.forward"; };
zone "10.168.192.in-addr.arpa" { type master; file "/etc/bind/db.rev10"; };
zone "20.168.192.in-addr.arpa" { type master; file "/etc/bind/db.rev20"; };

Создай 3 файла зон в /etc/bind/.
Прямая (db.forward):
$TTL 604800
@ IN SOA hq-srv.au-team.irpo. admin.au-team.irpo. ( 2 604800 86400 2419200 604800 )
@ IN NS hq-srv.au-team.irpo.
hq-rtr IN A 192.168.10.1
br-rtr IN A 192.168.30.1
hq-srv IN A 192.168.10.2
hq-cli IN A 192.168.20.10
br-srv IN A 192.168.30.2
moodle IN A 172.16.40.1
wiki   IN A 172.16.50.1

Обратная 10 (db.rev10):
$TTL 604800
@ IN SOA hq-srv.au-team.irpo. admin.au-team.irpo. ( 2 604800 86400 2419200 604800 )
@ IN NS hq-srv.au-team.irpo.
1 IN PTR hq-rtr.au-team.irpo.
2 IN PTR hq-srv.au-team.irpo.

Обратная 20 (db.rev20):
$TTL 604800
@ IN SOA hq-srv.au-team.irpo. admin.au-team.irpo. ( 2 604800 86400 2419200 604800 )
@ IN NS hq-srv.au-team.irpo.
10 IN PTR hq-cli.au-team.irpo.

systemctl restart bind9
🖥️ Машина 6: HQ-CLI (Клиент)
1. Имя и время:
hostnamectl set-hostname hq-cli.au-team.irpo
timedatectl set-timezone Europe/Moscow

2. Сеть (Netplan):
network:
  version: 2
  ethernets:
    ens_lan:
      dhcp4: false
  vlans:
    vlan20:
      id: 20
      link: ens_lan
      dhcp4: true

Примени netplan apply и машина сама получит IP адрес, маршрут и DNS сервер от твоего HQ-RTR!

