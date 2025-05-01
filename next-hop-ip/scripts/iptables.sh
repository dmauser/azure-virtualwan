#!/bin/sh

# This script configures iptables rules for a Linux-based NVA (Network Virtual Appliance) VM.
apt-get update -y
apt-get install iptables-persistent -y

# Flush existing rules (optional, depending on use case)
iptables -F FORWARD

# Set default policy to DROP (optional but recommended for security)
iptables -P FORWARD DROP

# Allow all already established and related connections (stateful)
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow new connections (state tracked)
iptables -A FORWARD -m conntrack --ctstate NEW -j ACCEPT

# Drop invalid packets explicitly
iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP

# Save for persistence (ensure iptables-persistent is installed)
iptables-save > /etc/iptables/rules.v4
