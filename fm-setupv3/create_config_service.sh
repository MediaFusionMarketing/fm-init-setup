#!/usr/bin/env bash
set -e

# 1) Skript aus /root ins systemweite bin-Verzeichnis kopieren
install -m0755 /root/install.sh /usr/local/bin/install.sh

# 2) systemd-Unit anlegen
cat > /etc/systemd/system/install.service <<'EOF'
[Unit]
Description=Run initial configuration at next boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/install.sh
# Nach erfolgreichem Lauf den Dienst deaktivieren und systemd neu laden
ExecStartPost=/usr/bin/systemctl disable install.service
ExecStartPost=/usr/bin/systemctl daemon-reload

[Install]
WantedBy=multi-user.target
EOF

# 3) Service aktivieren
systemctl enable install.service
