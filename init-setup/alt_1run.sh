#!/bin/sh

apk update
apk add --no-cache bash
wget http://webspace.mf-support.de/2.sh
chmod +x ./2.sh
cat <<EOF > answersfile
KEYMAPOPTS="de de"
HOSTNAMEOPTS="-n alpine"
INTERFACESOPTS="auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp"
TIMEZONEOPTS="-z Europe/Berlin"
PROXYOPTS="none"
APKREPOSOPTS="-1"
SSHDOPTS="-c openssh"
NTPOPTS="-c chrony"
DISKOPTS="-m sys /dev/sda"
USEROPTS="-e no"
ROOTPASSWORDOPTS="-p 'alpine'"
EOF
setup-alpine -f answersfile