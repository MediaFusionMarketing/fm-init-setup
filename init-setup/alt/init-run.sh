#!/bin/bash

# Track tasks
taskCounter=0
failedTaskCounter=0
declare -a taskStatus

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

# vars###############################################
packageNames=("tailscale" "fail2ban" "sudo" "curl" "jq")
tailscale_auth_key="48989e3609e2554f667598ccdd2e0259da4978b70ab833d3"
adminUserName=""
adminUserPw=""
hostname=""
fm_model=""
api_url_generate_hostname="http://192.168.20.9:5000/api/v1/fm/generate-hostname"
api_url_update_data="http://192.168.20.9:5000/api/v1/fm/update"

# Generate random string
generateRandomString() {
    local lenght=$((RANDOM % 4 + 12))
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
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

# 2) Install required packages
((taskCounter++))
for packageName in "${packageNames[@]}"; do
    if ! command -v "${packageName}" >/dev/null 2>&1; then 
        echo "${packageName} is not installed. Starting installation..."
        apk update && apk add "${packageName}"
        recordStatus "Install package ${packageName}" $?
    else
        echo "${packageName} is already installed"
        recordStatus "Install package ${packageName} (already installed)" 0
    fi
done

# 3) Ask for FM model
((taskCounter++))
echo "Which FM model do you want to set up?"
echo "1. T5000"
echo "2. Wyse5070"
read -p "Enter the number of the FM model: " fm_modell_nr

case $fm_modell_nr in
    1)
        fm_model="1"
        ;;
    2)
        fm_model="2"
        ;;
    *)
        echo "The FM model is not valid"
        taskStatus["$taskCounter"]="Task #$taskCounter: Ask for FM model: FAILED"
        exit 1
        ;;
esac
taskStatus["$taskCounter"]="Task #$taskCounter: Ask for FM model: SUCCESS"

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
setup-keymap de de
recordStatus "Set keymap to german" $?

# 7) Set hostname
((taskCounter++))
echo "Setting the hostname to $hostname"
setup-hostname -n "$hostname.mf-support.de"
recordStatus "Set system hostname" $?

# 8) Set up network interface
((taskCounter++))
echo "Setting up the network interface..."
cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    hostname $hostname.mf-support.de
EOF
recordStatus "Configure network interface" $?

# 9) Set up timezone
((taskCounter++))
echo "Setting up the timezone..."
setup-timezone -z Europe/Berlin
recordStatus "Set timezone to Europe/Berlin" $?

# 10) Restart hostname service
((taskCounter++))
rc-service hostname --quiet restart
recordStatus "Restart hostname service" $?
sleep 20

# # 11) Set up proxy
# ((taskCounter++))
# setup-proxy -q
# recordStatus "Configure proxy" $?

# 12) Set up apk repositories
((taskCounter++))
setup-apkrepos -c -f
recordStatus "Configure apk repositories" $?

# 13) Set up sshd
((taskCounter++))
setup-sshd -c openssh
recordStatus "Configure sshd" $?

# 14) Set up ntpd
((taskCounter++))
setup-ntp -h chrony
recordStatus "Configure ntp" $?

# # 15) Set up disk
# ((taskCounter++))
# setup-disk -m sys /dev/sda
# recordStatus "Configure disk" $?

# 16) Update the system
((taskCounter++))
apk update && apk upgrade
recordStatus "Update the system" $?

# 17) Re-install required packages (again)
((taskCounter++))
for packageName in "${packageNames[@]}"; do
    if ! command -v "${packageName}" >/dev/null 2>&1; then 
        echo "${packageName} is not installed. The installation is started..."
        apk update && apk add "${packageName}"
        recordStatus "Install package ${packageName} (second time)" $?
    else
        echo "${packageName} is already installed"
        recordStatus "Install package ${packageName} (already installed second time)" 0
    fi
done

# 18) Configure tailscale
((taskCounter++))
if command -v tailscale >/dev/null 2>&1; then
    echo "tailscale will be configured..."
    rc-update add tailscale
    service tailscale start
    recordStatus "Start tailscale service" $?

    ((taskCounter++))
    if [ -z "$tailscale_auth_key" ]; then
        echo "Error: tailscale_auth_key is not set."
        taskStatus["$taskCounter"]="Task #$taskCounter: Check tailscale_auth_key: FAILED"
        exit 1
    else
        tailscale up --advertise-exit-node --login-server=https://headscale.mf-support.de/ --authkey "$tailscale_auth_key"
        echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
        echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
        sysctl -p /etc/sysctl.d/99-tailscale.conf
        recordStatus "Configure tailscale" $?
    fi
else
    echo "Tailscale is not installed."
    taskStatus["$taskCounter"]="Task #$taskCounter: tailscale not installed: FAILED"
fi
sleep 20

# 19) Create random admin user
((taskCounter++))
adminUserName=$(generateRandomString)
adminUserPw=$(generateRandomString)
adduser -D "$adminUserName"
echo "$adminUserName:$adminUserPw" | chpasswd
recordStatus "Create admin user ($adminUserName)" $?

# 20) Create sudo group
((taskCounter++))
echo "Create sudo group..."
if grep -q "^sudo" /etc/group; then
    echo "The group sudo already exists."
    recordStatus "Create sudo group (already exists)" 0
else
    addgroup sudo
    recordStatus "Create sudo group" $?
fi

# 21) Add sudo group to sudoers
((taskCounter++))
sudo cp /etc/sudoers /etc/sudoers.bak
if sudo grep -Fxq "%sudo ALL=(ALL) ALL" /etc/sudoers; then
    echo "Entry already in /etc/sudoers."
    recordStatus "Add sudo group to sudoers (already present)" 0
else
    echo "%sudo ALL=(ALL) ALL" | sudo EDITOR='tee -a' visudo
    recordStatus "Add sudo group to sudoers" $?
fi

# 22) Add admin user to sudo group
((taskCounter++))
echo "Add user to sudo group..."
addgroup "$adminUserName" sudo
recordStatus "Add $adminUserName to sudo" $?

# 23) Secure SSH configuration
((taskCounter++))
echo "Securing SSH configuration..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
echo "AllowUsers $adminUserName" >> /etc/ssh/sshd_config
service sshd restart
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

rc-update add fail2ban
service fail2ban start
service sshd restart
recordStatus "Configure Fail2Ban" $?

# 25) Grafana agent / Node exporter
((taskCounter++))
wget https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-386.tar.gz
tar xvfz node_exporter-1.8.2.linux-386.tar.gz
cd node_exporter-1.8.2.linux-386.tar.gz
./node_exporter &
recordStatus "Start node_exporter" $?
cd ..

# systemd-Service-Datei erstellen
echo "[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
ExecStart=/root/node_exporter-1.8.2.linux-386/node_exporter --web.listen-address=\":9100\"
Restart=always
User=nobody
Group=nogroup
EnvironmentFile=-/etc/default/node_exporter

[Install]
WantedBy=multi-user.target" | sudo tee /etc/systemd/system/node_exporter.service > /dev/null

sudo systemctl daemon-reload

sudo systemctl start node_exporter
sudo systemctl enable node_exporter

sudo systemctl status node_exporter

# 26) Send data to the API
((taskCounter++))
curl -X POST $api_url_update_data \
  -H "Content-Type: application/json" \
  -d "{
    \"hostname\": \"$hostname\",
    \"adminUserName\": \"$adminUserName\",
    \"adminUserPw\": \"$adminUserPw\"
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
    echo "$failedTaskCounter/$taskCounter tasks failed" | tee -a ./init-run.log
else
    :
    #echo "$taskCounter/$taskCounter tasks completed" | tee -a ./init-run.log
fi

# # Reboot after one minute
# echo "Setup finished. Rebooting in 1 minute..."
# sleep 60
# reboot
