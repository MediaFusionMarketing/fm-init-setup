#!/usr/bin/env bash
set -e

install -m0755 /root/install.sh /usr/local/bin/install.sh

cat > /etc/systemd/system/install.service <<'EOF'
[Unit]
Description=Run initial configuration at next boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/install.sh
ExecStartPost=/usr/bin/systemctl disable install.service
ExecStartPost=/usr/bin/systemctl daemon-reload

[Install]
WantedBy=multi-user.target
EOF

# Neu laden, aktivieren
systemctl daemon-reload
systemctl enable install.service
