#!/usr/bin/env bash
set -e
 
# 1. Mount-Punkt der Ziel-Installation (Standard: /target)
TARGET="${1:-/target}"
 
# 2. Nextboot-Skript kopieren
install -m0755 install.sh "${TARGET}/usr/local/bin/install.sh"
 
# 3. systemd-Unit schreiben
cat > "${TARGET}/etc/systemd/system/install.service" <<EOF
[Unit]
Description=Run initial configuration at next boot
After=network-online.target
Wants=network-online.target
 
[Service]
Type=oneshot
ExecStart=/usr/local/bin/install.sh
 
[Install]
WantedBy=multi-user.target
EOF
 
# 4. Service in der Ziel-Installation aktivieren
chroot "${TARGET}" systemctl enable install.service
