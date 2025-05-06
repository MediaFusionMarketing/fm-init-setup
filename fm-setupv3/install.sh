#!/bin/bash

#set -euo pipefail

# Define color variables
YELLOW="\e[33m"
RED="\e[31m"
GREEN="\e[32m"
BLUE="\e[34m"
PURPLE="\e[35m"
RESET="\e[0m"

# Track tasks
taskCounter=0
failedTaskCounter=0
declare -a taskStatus

# vars ###############################################
node_exporter_version="1.8.2"
node_exporter_release="linux-amd64"
packageNames=( "tailscale" "fail2ban" "sudo" "curl" "jq" "tar" )
auth_key="f40e4813813bd39fb66667c32082515e2df1c0e6ebe9404e"
adminUserName=""
adminUserPw=""
hostname=""
fm_model="o1"
api_url_generate_hostname="http://192.168.20.9:5000/api/v1/fm/generate-hostname"
api_url_update_data="http://192.168.20.9:5000/api/v1/fm/update"
rootUserPw=""

# Helper: record each task’s status
recordStatus() {
    local desc="$1"
    local code="$2"
    if [ "$code" -eq 0 ]; then
        taskStatus["$taskCounter"]="$desc: SUCCESS"
    else
        taskStatus["$taskCounter"]="$desc: FAILED"
        ((failedTaskCounter++))
    fi
}

# 0) Install Tailscale if missing
install_tailscale() {
    if ! command -v tailscale &>/dev/null; then
        echo -e "${YELLOW}Tailscale not found. Installing...${RESET}"
        apt update -y
        apt install -y curl
        curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
            | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
            | tee /etc/apt/sources.list.d/tailscale.list
        apt update -y
        apt install -y tailscale
    fi
}

# 1) Manual start of tailscaled (systemd is ignored in chroot)
start_tailscale() {
    echo -e "${GREEN}Starte tailscaled manuell...${RESET}"
    nohup tailscaled --tun=userspace-networking \
        --state=/var/lib/tailscale/tailscaled.state \
        >/var/log/tailscaled.log 2>&1 &
    sleep 2
    recordStatus "Start tailscale daemon" $?

    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf || true

    if [ -n "$auth_key" ]; then
        tailscale up --login-server https://headscale.mf-support.de/ \
                     --auth-key="$auth_key" \
                     --advertise-exit-node --reset
    else
        tailscale up --advertise-exit-node --reset
    fi
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to run 'tailscale up'.${RESET}"
        exit 1
    fi

    local TAILSCALE_IP=""
    while [ -z "$TAILSCALE_IP" ]; do
        echo -e "${YELLOW}Waiting for Tailscale to come online...${RESET}"
        sleep 1
        TAILSCALE_IP=$(tailscale ip -4)
    done

    local DNSNAME
    DNSNAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    echo -e "${GREEN}Tailscale IPv4: $TAILSCALE_IP${RESET}"
    echo -e "${GREEN}MagicDNS name: $DNSNAME${RESET}"
}

install_fail2ban() {
  # Prüfen, ob das Skript als root läuft
  if [[ $EUID -ne 0 ]]; then
    echo "Dieses Skript muss als root ausgeführt werden." >&2
    return 1
  fi

  # 1) Paketliste aktualisieren und fail2ban installieren
  apt-get update
  apt-get install -y fail2ban
  apt-get update
  apt-get install -y rsyslog
  systemctl enable rsyslog
  systemctl start rsyslog

  # 2) Backup bestehender Konfiguration (falls vorhanden)
  local TIMESTAMP
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  if [[ -e /etc/fail2ban/jail.local ]]; then
    cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak.$TIMESTAMP
    echo "Backup der alten jail.local: /etc/fail2ban/jail.local.bak.$TIMESTAMP"
  fi

  # 3) Neue Standard-Konfiguration schreiben
  cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = 3600
findtime = 900
maxretry = 5
destemail = root@localhost
sender = fail2ban@%H
protocol = tcp
banaction = iptables-multiport
mta = mail
loglevel = INFO
logtarget = /var/log/fail2ban.log
backend = systemd

[sshd]
enabled   = true
port      = ssh
maxretry  = 5

[recidive]
enabled   = true
logpath   = /var/log/fail2ban.log
bantime   = 604800
findtime  = 86400
maxretry  = 10
EOF

  # 4) Dateiberechtigungen setzen
  chown root:root /etc/fail2ban/jail.local
  chmod 644       /etc/fail2ban/jail.local

  # 5) Dienst aktivieren und neu starten
  systemctl enable fail2ban
  systemctl restart fail2ban

  echo "fail2ban wurde installiert und mit der Standard-Konfiguration eingerichtet."
}


# 2) Random string generator
generateRandomString() {
    local len=$((RANDOM % 4 + 12))
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c"$len"
}

# 3) Ensure we run as root
((taskCounter++))
if [ "$EUID" -ne 0 ]; then
    echo "FAILED: Please run as root"
    taskStatus["$taskCounter"]="Check for root: FAILED"
    exit 1
else
    taskStatus["$taskCounter"]="Check for root: SUCCESS"
fi

# 4) Install Tailscale
((taskCounter++))
install_tailscale
recordStatus "Installing Tailscale" $?

# 5) Install required packages
((taskCounter++))
for pkg in "${packageNames[@]}"; do
    if ! command -v "$pkg" &>/dev/null; then
        echo -e "${YELLOW}$pkg not found, installing...${RESET}"
        apt update -y && apt install -y "$pkg"
        recordStatus "Install package $pkg" $?
    else
        recordStatus "Install package $pkg (already present)" 0
    fi
done

# 6) Fetch hostname from API
((taskCounter++))
resp=$(curl -s -X POST "$api_url_generate_hostname" \
    -H "Content-Type: application/json" \
    -d "{\"fm-model\":\"$fm_model\"}")
hostname=$(echo "$resp" | jq -r '.hostname')
if [ -z "$hostname" ] || [ "$hostname" = "null" ]; then
    recordStatus "Get hostname from API" 1
    echo "ERROR: no hostname received"
    exit 1
else
    recordStatus "Get hostname from API" 0
fi

# # 7) Set system keymap to German
((taskCounter++))
dpkg-reconfigure -f noninteractive keyboard-configuration && service keyboard-setup restart
recordStatus "Set keymap to German" $?

#((taskCounter++))
echo "$hostname" > /etc/hostname
sed -i "/127.0.1.1/d" /etc/hosts
echo "127.0.1.1 $hostname.mf-support.de $hostname" >> /etc/hosts
recordStatus "Set system hostname" $?

# 8) Set hostname
((taskCounter++))
hostnamectl set-hostname "$hostname.mf-support.de"
recordStatus "Set system hostname" $?

# 9) Configure network (DHCP on eth0)
((taskCounter++))
cat >/etc/network/interfaces.d/eth0 <<EOF
auto eth0
iface eth0 inet dhcp
EOF
recordStatus "Configure network interface" $?

# 10) Set timezone
((taskCounter++))
timedatectl set-timezone Europe/Berlin
recordStatus "Set timezone to Europe/Berlin" $?

# 11) Restart hostname service
((taskCounter++))
systemctl restart systemd-hostnamed
recordStatus "Restart hostname service" $?

# 12) Install & configure SSH
((taskCounter++))
apt install -y openssh-server
systemctl enable ssh && systemctl start ssh
recordStatus "Configure sshd" $?

# 13) Install & configure NTP
((taskCounter++))
apt install -y systemd-timesyncd
systemctl enable systemd-timesyncd && systemctl start systemd-timesyncd
recordStatus "Configure NTP" $?

# 14) Update & upgrade system
((taskCounter++))
apt update -y && apt upgrade -y
recordStatus "Update & upgrade system" $?

# 15) Start Tailscale
((taskCounter++))
start_tailscale
recordStatus "Start Tailscale" $?

# 16) Re-install required packages (idempotency)
((taskCounter++))
for pkg in "${packageNames[@]}"; do
    if ! command -v "$pkg" &>/dev/null; then
        apt update -y && apt install -y "$pkg"
        recordStatus "Re-install package $pkg" $?
    else
        recordStatus "Re-install package $pkg (already present)" 0
    fi
done

# 17) Set root password
((taskCounter++))
rootUserPw=$(generateRandomString)
echo "root:$rootUserPw" | chpasswd
recordStatus "Set root password" $?

# 18) Create random admin user
((taskCounter++))
adminUserName=$(generateRandomString)
adminUserPw=$(generateRandomString)
useradd -m "$adminUserName"
echo "$adminUserName:$adminUserPw" | chpasswd
recordStatus "Create admin user $adminUserName" $?

# 19) Ensure sudo group exists
((taskCounter++))
if grep -q "^sudo:" /etc/group; then
    recordStatus "Ensure sudo group exists" 0
else
    groupadd sudo
    recordStatus "Create sudo group" $?
fi

# 20) Grant sudo privileges
((taskCounter++))
cp /etc/sudoers /etc/sudoers.bak
if grep -q "^%sudo ALL=(ALL:ALL) ALL" /etc/sudoers; then
    recordStatus "Add sudo group to sudoers" 0
else
    echo "%sudo ALL=(ALL:ALL) ALL" >> /etc/sudoers
    recordStatus "Add sudo group to sudoers" $?
fi

# 21) Add admin user to sudo
((taskCounter++))
usermod -aG sudo "$adminUserName"
recordStatus "Add $adminUserName to sudo group" $?

# 22) Harden SSH
((taskCounter++))
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i 's/#PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
echo "AllowUsers $adminUserName" >> /etc/ssh/sshd_config
systemctl restart ssh
recordStatus "Harden SSH configuration" $?

# 23) Configure Fail2Ban
((taskCounter++))
install_fail2ban
recordStatus "Configure Fail2Ban" $?

# 24) Install & start Node Exporter
((taskCounter++))
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/node_exporter-${node_exporter_version}.${node_exporter_release}.tar.gz"
tar -xzf node_exporter-${node_exporter_version}.${node_exporter_release}.tar.gz
mv node_exporter-${node_exporter_version}.${node_exporter_release}/node_exporter /usr/local/bin/
rm -rf node_exporter-${node_exporter_version}.${node_exporter_release}*

useradd -r -s /bin/false node_exporter
mkdir -p /etc/prometheus_node_exporter
chown node_exporter:node_exporter /etc/prometheus_node_exporter

cat >/etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter && systemctl start node_exporter
recordStatus "Start node_exporter" $?

# 25) Send setup data to API
((taskCounter++))
curl -s -X POST "$api_url_update_data" \
     -H "Content-Type: application/json" \
     -d "{\"hostname\":\"$hostname\",\"adminUserName\":\"$adminUserName\",\"adminUserPw\":\"$adminUserPw\",\"rootUserPw\":\"$rootUserPw\"}"
recordStatus "Send data to API" $?

# === Summary ===
echo -e "\n========================================"
echo "Task summary:"
for i in "${!taskStatus[@]}"; do
    echo " - ${taskStatus[$i]}"
done
echo "========================================"

if [ $failedTaskCounter -ne 0 ]; then
    echo "$failedTaskCounter/$taskCounter tasks failed"
    exit 1
else
    systemctl disable install.service
    rm -f /etc/systemd/system/install.service
    echo "$taskCounter/$taskCounter tasks completed successfully"
    # echo -n "Press [ENTER] to power off..."
    # read
    # poweroff
fi
