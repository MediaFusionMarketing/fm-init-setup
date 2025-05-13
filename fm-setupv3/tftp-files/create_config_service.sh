#!/usr/bin/env bash
set -e

# 0) Zeilenenden konvertieren & Shebang prüfen
# (nur nötig, wenn dein install.sh von Windows kommt)
sed -i '1s|.*|#!/usr/bin/env bash|' /root/install.sh
sed -i 's/\r$//' /root/install.sh
chmod +x /root/install.sh

# 1) Skript ins systemweite bin-Verzeichnis kopieren
install -m0755 /root/install.sh /usr/local/bin/install.sh

# 2) systemd-Unit anlegen
cat > /etc/systemd/system/install.service <<'EOF'
[Unit]
Description=Run initial configuration at next boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# explizit über bash starten
ExecStart=/usr/bin/env bash /usr/local/bin/install.sh
ExecStartPost=/usr/bin/systemctl disable install.service
ExecStartPost=/usr/bin/systemctl daemon-reload

[Install]
WantedBy=multi-user.target
EOF

# 3) Unit neu laden und Service aktivieren
systemctl daemon-reload
systemctl enable install.service
