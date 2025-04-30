#!/bin/bash

ip=$1
sudo vtysh << EOVTYSH
conf t
route-map lbnexthop permit 10
 set ip next-hop $ip
exit

router bgp 65002
 address-family ipv4 unicast
  neighbor 192.168.1.68 route-map lbnexthop out
  neighbor 192.168.1.69 route-map lbnexthop out
 exit-address-family
exit
write memory
EOVTYSH
