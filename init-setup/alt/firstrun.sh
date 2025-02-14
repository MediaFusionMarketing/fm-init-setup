#!/bin/sh

apk update
apk add --no-cache bash
wget http://webspace.mf-support.de/2.sh
chmod +x ./2.sh
setup-disk -m sys /dev/sda