#!/bin/sh
# Allow all traffic, but keep it state‑tracked
# Accept already established / related flows first
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Track and allow new flows
iptables -A FORWARD -m conntrack --ctstate NEW -j ACCEPT

# (Optional) drop anything that is marked INVALID by conntrack
iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP

# Save to IPTables file for persistence on reboot
iptables-save > /etc/iptables/rules.v4