#!/bin/sh
pkg install -y os-frr

fetch $1/config-branch.xml
fetch $1/get_nic_gw.py
gwip=$(python get_nic_gw.py $2)
sed -i "" "s/yyy.yyy.yyy.yyy/$gwip/" config-branch.xml
sed -i "" "s/aa.aa.aa.aa/$3/" config-branch.xml
sed -i "" "s/bb.bb.bb.bb/$4/" config-branch.xml
sed -i "" "s/cc.cc.cc.cc/$5/" config-branch.xml
cp config-branch.xml /usr/local/etc/config.xml