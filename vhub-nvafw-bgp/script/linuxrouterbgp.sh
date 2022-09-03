#!/bin/sh
# Enable IPv4 and IPv6 forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
sed -i "/net.ipv4.ip_forward=1/ s/# *//" /etc/sysctl.conf
sed -i "/net.ipv6.conf.all.forwarding=1/ s/# *//" /etc/sysctl.conf

# Parameters
asn_quagga=$1
bgp_routerId=$2
bgp_network1=$3
bgp_network2=$4
routeserver_IP1=$5
routeserver_IP2=$6

sudo apt-get -y update

## Install the Quagga routing daemon
echo "Installing quagga"
sudo apt-get -y install quagga

##  run the updates and ensure the packages are up to date and there is no new version available for the packages
sudo apt-get -y update --fix-missing

echo "Installing IPTables-Persistent"
echo iptables-persistent iptables-persistent/autosave_v4 boolean false | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | sudo debconf-set-selections
apt-get -y install iptables-persistent

# Enable NAT to Internet
iptables -t nat -A POSTROUTING -d 10.0.0.0/8 -j ACCEPT
iptables -t nat -A POSTROUTING -d 172.16.0.0/12 -j ACCEPT
iptables -t nat -A POSTROUTING -d 192.168.0.0/16 -j ACCEPT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Save to IPTables file for persistence on reboot
iptables-save > /etc/iptables/rules.v4

## Create a folder for the quagga logs
echo "creating folder for quagga logs"
sudo mkdir -p /var/log/quagga && sudo chown quagga:quagga /var/log/quagga
sudo touch /var/log/zebra.log
sudo chown quagga:quagga /var/log/zebra.log

## Create the configuration files for Quagga daemon
echo "creating empty quagga config files"
sudo touch /etc/quagga/babeld.conf
sudo touch /etc/quagga/bgpd.conf
sudo touch /etc/quagga/isisd.conf
sudo touch /etc/quagga/ospf6d.conf
sudo touch /etc/quagga/ospfd.conf
sudo touch /etc/quagga/ripd.conf
sudo touch /etc/quagga/ripngd.conf
sudo touch /etc/quagga/vtysh.conf
sudo touch /etc/quagga/zebra.conf

## Change the ownership and permission for configuration files, under /etc/quagga folder
echo "assign to quagga user the ownership of config files"
sudo chown quagga:quagga /etc/quagga/babeld.conf && sudo chmod 640 /etc/quagga/babeld.conf
sudo chown quagga:quagga /etc/quagga/bgpd.conf && sudo chmod 640 /etc/quagga/bgpd.conf
sudo chown quagga:quagga /etc/quagga/isisd.conf && sudo chmod 640 /etc/quagga/isisd.conf
sudo chown quagga:quagga /etc/quagga/ospf6d.conf && sudo chmod 640 /etc/quagga/ospf6d.conf
sudo chown quagga:quagga /etc/quagga/ospfd.conf && sudo chmod 640 /etc/quagga/ospfd.conf
sudo chown quagga:quagga /etc/quagga/ripd.conf && sudo chmod 640 /etc/quagga/ripd.conf
sudo chown quagga:quagga /etc/quagga/ripngd.conf && sudo chmod 640 /etc/quagga/ripngd.conf
sudo chown quagga:quaggavty /etc/quagga/vtysh.conf && sudo chmod 660 /etc/quagga/vtysh.conf
sudo chown quagga:quagga /etc/quagga/zebra.conf && sudo chmod 640 /etc/quagga/zebra.conf

## initial startup configuration for Quagga daemons are required
echo "Setting up daemon startup config"
echo 'zebra=yes' > /etc/quagga/daemons
echo 'bgpd=yes' >> /etc/quagga/daemons
echo 'ospfd=no' >> /etc/quagga/daemons
echo 'ospf6d=no' >> /etc/quagga/daemons
echo 'ripd=no' >> /etc/quagga/daemons
echo 'ripngd=no' >> /etc/quagga/daemons
echo 'isisd=no' >> /etc/quagga/daemons
echo 'babeld=no' >> /etc/quagga/daemons

echo "add zebra config"
cat <<EOF > /etc/quagga/zebra.conf
!
interface eth0
!
interface lo
!
ip forwarding
!
line vty
!
EOF


echo "add quagga config"
cat <<EOF > /etc/quagga/bgpd.conf
!
log file /var/log/quagga/bgpd.log informational
!
router bgp $asn_quagga
 bgp router-id $bgp_routerId
 network $bgp_network1
 network $bgp_network2
 neighbor $routeserver_IP1 remote-as 65515
 neighbor $routeserver_IP1 ebgp-multihop 255
 neighbor $routeserver_IP1 soft-reconfiguration inbound
 neighbor $routeserver_IP2 remote-as 65515
 neighbor $routeserver_IP2 ebgp-multihop 255
 neighbor $routeserver_IP2 soft-reconfiguration inbound
!
 address-family ipv6
 exit-address-family
 exit
!
line vty
!
EOF

## to start daemons at system startup
echo "enable zebra and quagga daemons at system startup"
systemctl enable zebra.service
systemctl enable bgpd.service

## run the daemons
echo "start zebra and quagga daemons"
systemctl restart zebra
systemctl restart bgpd 
systemctl start zebra
systemctl start bgpd 