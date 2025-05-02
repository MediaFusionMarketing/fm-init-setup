#!/bin/bash

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


# vars###############################################
node_exporter_version="1.8.2"
node_exporter_release="linux-amd64"  # Changed to amd64 for 64-bit systems
packageNames=("tailscale" "fail2ban" "sudo" "curl" "jq" "tar")
auth_key="98b1982ee5d3b31853ec01bb2276292f84443f6b95c0d71c"
adminUserName=""
adminUserPw=""
hostname=""
fm_model="o1"
api_url_generate_hostname="http://192.168.20.9:5000/api/v1/fm/generate-hostname"
api_url_update_data="http://192.168.20.9:5000/api/v1/fm/update"
rootUserPw= ""

# Helper function to record each task's status
recordStatus() {
    local description="$1"
    local exitCode="$2"
    if [ "$exitCode" -eq 0 ]; then
        taskStatus["$taskCounter"]="$description: SUCCESS"
    else
        taskStatus["$taskCounter"]="$description: FAILED"
        ((failedTaskCounter++))
    fi
}

# Install Tailscale if it is not already installed
function install_tailscale() {
    if ! command -v tailscale &>/dev/null; then
        echo -e "${YELLOW}Tailscale not found. Installing...${RESET}"
        apt install curl -y
        curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
        apt update
        apt install tailscale -y
    else
        # echo -e "${GREEN}Tailscale is already installed.${RESET}"
        :
    fi
}

# Bring up Tailscale
function start_tailscale() {
    echo -e "${GREEN}Starting Tailscale with --advertise-tags 'tag:tailmox'...${RESET}"

    echo -e "tailscale will be configured..."
    systemctl enable tailscaled  # Using systemctl for Debian
    systemctl start tailscaled
    recordStatus "Start tailscale service" $?

    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf
    
    if [ -n "$auth_key" ]; then
        # Use the provided auth key
        tailscale up --login-server https://headscale.mf-support.de/ --auth-key="$auth_key"  --advertise-exit-node --reset
    else
        # Fall back to interactive authentication
        tailscale up --advertise-tags "tag:test" --advertise-exit-node --reset
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to start Tailscale.${RESET}"
        exit 1
    fi

    # Retrieve the assigned Tailscale IPv4 address
    local TAILSCALE_IP=""
    while [ -z "$TAILSCALE_IP" ]; do
        echo -e "${YELLOW}Waiting for Tailscale to come online...${RESET}"
        sleep 1
        TAILSCALE_IP=$(tailscale ip -4)
    done

    TAILSCALE_DNS_NAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    echo -e "${GREEN}This host's Tailscale IPv4 address: $TAILSCALE_IP ${RESET}"
    echo -e "${GREEN}This host's Tailscale MagicDNS name: $TAILSCALE_DNS_NAME ${RESET}"
}


# Generate random string
generateRandomString() {
    local lenght=$((RANDOM % 4 + 12))
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local randomString=""
    for ((i = 0; i < lenght; i++)); do
        randomIndex=$((RANDOM % ${#chars}))
        randomString+=${chars:randomIndex:1}
    done
    echo "$randomString"
}

# 1) Check if script is run as root
((taskCounter++))
if [ "$EUID" -ne 0 ]; then
    echo "FAILED: Please execute the Script as root user"
    taskStatus["$taskCounter"]="Task #$taskCounter: Check for root user: FAILED"
    exit 1
else
    echo "NOTE: the script will be executed as root"
    taskStatus["$taskCounter"]="Task #$taskCounter: Check for root user: SUCCESS"
fi

((taskCounter++))
install_tailscale
recordStatus "CINstalling Tailscale..." $?

# 2) Install required packages
((taskCounter++))
for packageName in "${packageNames[@]}"; do
    if ! command -v "${packageName}" >/dev/null 2>&1; then
        echo "${packageName} is not installed. Starting installation..."
        apt update && apt install -y "${packageName}"  # Changed to apt
        recordStatus "Install package ${packageName}" $?
    else
        echo "${packageName} is already installed"
        recordStatus "Install package ${packageName} (already installed)" 0
    fi
done

# 4) Get hostname from API
((taskCounter++))
response=$(curl -s -X POST "$api_url_generate_hostname" \
    -H "Content-Type: application/json" \
    -d "{\"fm-model\":\"$fm_model\"}")
sleep 20
hostname=$(echo "$response" | jq -r '.hostname')
sleep 20
if [ -z "$hostname" ]; then
    echo "No hostname received from API"
    taskStatus["$taskCounter"]="Task #$taskCounter: Get hostname from API: FAILED"
    exit 1
else
    echo "The hostname is: $hostname"
    taskStatus["$taskCounter"]="Task #$taskCounter: Get hostname from API: SUCCESS"
fi
recordStatus "Get hostname from api" $?

# 5) Check if the hostname is set
((taskCounter++))
if [ -z "$hostname" ]; then
    echo "The hostname is not set, generating now..."
    response=$(curl -s $api_url_generate_hostname)
    hostname=$(echo $response | jq -r '.hostname')
    echo "The hostname is: $hostname"
else
    echo "The hostname is set"
fi
if [ -z "$hostname" ]; then
    taskStatus["$taskCounter"]="Task #$taskCounter: Check if hostname is set: FAILED"
    ((failedTaskCounter++))
else
    taskStatus["$taskCounter"]="Task #$taskCounter: Check if hostname is set: SUCCESS"
fi

# 6) Set keymap
((taskCounter++))
echo "Setting the keymap to german..."
# Debian method for setting keyboard layout
sed -i 's/XKBLAYOUT="[^"]*"/XKBLAYOUT="de"/g' /etc/default/keyboard
dpkg-reconfigure -f noninteractive keyboard-configuration
service keyboard-setup restart
recordStatus "Set keymap to german" $?

# 7) Set hostname
((taskCounter++))
echo "Setting the hostname to $hostname"
hostnamectl set-hostname "$hostname.mf-support.de"  # Using hostnamectl for Debian
recordStatus "Set system hostname" $?

# 8) Set up network interface
((taskCounter++))
echo "Setting up the network interface..."
# Debian network configuration
cat <<EOF > /etc/network/interfaces.d/eth0
auto eth0
iface eth0 inet dhcp
EOF
recordStatus "Configure network interface" $?

# 9) Set up timezone
((taskCounter++))
echo "Setting up the timezone..."
timedatectl set-timezone Europe/Berlin  # Using timedatectl for Debian
recordStatus "Set timezone to Europe/Berlin" $?

# 10) Restart hostname service
((taskCounter++))
echo "Restarting hostname service..."
systemctl restart systemd-hostnamed  # Using systemctl for Debian
recordStatus "Restart hostname service" $?

# 13) Set up sshd
((taskCounter++))
apt install -y openssh-server  # Direct installation in Debian
systemctl enable ssh
systemctl start ssh
recordStatus "Configure sshd" $?

# 14) Set up ntp
((taskCounter++))
apt install -y systemd-timesyncd  # Using systemd-timesyncd for Debian
systemctl enable systemd-timesyncd
systemctl start systemd-timesyncd
recordStatus "Configure ntp" $?

# 16) Update the system
((taskCounter++))
apt update && apt upgrade -y  # Changed to apt
recordStatus "Update the system" $?

((taskCounter++))
start_tailscale
recordStatus "Starting Tailscale..." $?

# 17) Re-install required packages (again)
((taskCounter++))
for packageName in "${packageNames[@]}"; do
    if ! command -v "${packageName}" >/dev/null 2>&1; then
        echo "${packageName} is not installed. The installation is started..."
        apt update && apt install -y "${packageName}"  # Changed to apt
        recordStatus "Install package ${packageName} (second time)" $?
    else
        echo "${packageName} is already installed"
        recordStatus "Install package ${packageName} (already installed second time)" 0
    fi
done

# Set Root User PW
((taskCounter++))
$rootUserPw="edcrfv"
rootUserPw=$(generateRandomString)
echo "root:$rootUserPw" | chpasswd

# 19) Create random admin user
((taskCounter++))
adminUserName=$(generateRandomString)
adminUserPw=$(generateRandomString)
useradd -m "$adminUserName"  # Using useradd with -m to create home directory
echo "$adminUserName:$adminUserPw" | chpasswd
recordStatus "Create admin user ($adminUserName)" $?

# 20) Create sudo group
((taskCounter++))
echo "Create sudo group..."
if grep -q "^sudo" /etc/group; then
    echo "The group sudo already exists."
    recordStatus "Create sudo group (already exists)" 0
else
    groupadd sudo  # Using groupadd for Debian
    recordStatus "Create sudo group" $?
fi

# 21) Add sudo group to sudoers
((taskCounter++))
cp /etc/sudoers /etc/sudoers.bak
if grep -Fxq "%sudo ALL=(ALL:ALL) ALL" /etc/sudoers; then  # Debian sudo format
    echo "Entry already in /etc/sudoers."
    recordStatus "Add sudo group to sudoers (already present)" 0
else
    echo "%sudo ALL=(ALL:ALL) ALL" | tee -a /etc/sudoers
    recordStatus "Add sudo group to sudoers" $?
fi

# 22) Add admin user to sudo group
((taskCounter++))
echo "Add user to sudo group..."
usermod -aG sudo "$adminUserName"  # Using usermod for Debian
recordStatus "Add $adminUserName to sudo" $?

# 23) Secure SSH configuration
((taskCounter++))
echo "Securing SSH configuration..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
echo "AllowUsers $adminUserName" >> /etc/ssh/sshd_config
systemctl restart ssh  # Using systemctl for Debian
recordStatus "Secure SSH configuration" $?

# 24) Configure fail2ban
((taskCounter++))
echo "configuring Fail2Ban..."

cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = 600
findtime  = 600
maxretry = 5

[sshd]
enabled = true
EOF

systemctl enable fail2ban  # Using systemctl for Debian
systemctl start fail2ban
systemctl restart ssh
recordStatus "Configure Fail2Ban" $?

# 25) Grafana agent / Node exporter
((taskCounter++))
wget https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/node_exporter-${node_exporter_version}.${node_exporter_release}.tar.gz
tar -xvf node_exporter-${node_exporter_version}.${node_exporter_release}.tar.gz
mv node_exporter-${node_exporter_version}.${node_exporter_release}/node_exporter /usr/local/bin/
rm -rf node_exporter-${node_exporter_version}.${node_exporter_release} node_exporter-${node_exporter_version}.${node_exporter_release}.tar.gz

# Create system user for node_exporter
useradd -r -s /bin/false node_exporter  # Debian way to create system user

# Konfigurationsverzeichnis und Datei anlegen
mkdir -p /etc/prometheus_node_exporter/
chmod 700 /etc/prometheus_node_exporter
chown -R node_exporter:node_exporter /etc/prometheus_node_exporter

# Create systemd service file for Debian
cat << EOF > /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
systemctl daemon-reload
systemctl enable node_exporter
systemctl start node_exporter
recordStatus "Start node_exporter" $?

#Send data to the API
((taskCounter++))
curl -X POST $api_url_update_data \
  -H "Content-Type: application/json" \
  -d "{
    \"hostname\": \"$hostname\",
    \"adminUserName\": \"$adminUserName\",
    \"adminUserPw\": \"$adminUserPw\",
    \"rootUserPw\": \"$rootUserPw\"
  }"

recordStatus "Send data to the API" $?

# Print summary of every task
echo
echo "========================================"
echo "Task summary:"
for i in "${!taskStatus[@]}"; do
    echo " - ${taskStatus[$i]}"
done
echo "========================================"
# Print final counters
if [ $failedTaskCounter -ne 0 ]; then
    echo "$failedTaskCounter/$taskCounter tasks failed"
else
    echo "$taskCounter/$taskCounter tasks completed"
fi

# Reboot after one minute
#echo "Setup finished. Rebooting in 1 minute..."
#sleep 60
#reboot
