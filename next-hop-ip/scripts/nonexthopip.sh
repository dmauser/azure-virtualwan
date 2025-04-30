#!/bin/bash

sudo vtysh << EOVTYSH
conf t
router bgp 65002
 address-family ipv4 unicast
  no neighbor 192.168.1.68 route-map lbnexthop out
  no neighbor 192.168.1.69 route-map lbnexthop out
 exit-address-family
exit
write memory
EOVTYSH
