#!/bin/sh
# IPtables rules:
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i eth0 -p tcp --dport 80 -j ACCEPT
iptables -A FORWARD -i eth0 -p tcp --dport 443 -j ACCEPT
iptables -A FORWARD -i eth0 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i eth0 -p tcp --dport 22 -j ACCEPT
iptables -A FORWARD -i eth0 -p tcp --dport 5201 -j ACCEPT
iptables -A FORWARD -j DROP

# Save to IPTables file for persistence on reboot
iptables-save > /etc/iptables/rules.v4