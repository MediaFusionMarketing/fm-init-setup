#!/bin/bash
touch rtest.txt
# Constants and variables
NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_RELEASE="linux-amd64"  # Updated to 64-bit
PACKAGE_NAMES=("tailscale" "fail2ban" "sudo" "curl" "jq" "tar")
TAILSCALE_AUTH_KEY="a40b64256e364c27d806b2222c104a030a7a1ab53cc6099e"
ADMIN_USER_NAME=""
ADMIN_USER_PW=""
HOSTNAME=""
FM_MODEL=""
API_URL_GENERATE_HOSTNAME="http://192.168.20.9:5000/api/v1/fm/generate-hostname"
API_URL_UPDATE_DATA="http://192.168.20.9:5000/api/v1/fm/update"
ROOT_USER_PW=""

# Track tasks
TASK_COUNTER=0
FAILED_TASK_COUNTER=0
declare -a TASK_STATUS

# Logging function
function log_message() {
    local level=$1
    local message=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Helper function to record each task's status
function record_status() {
    local description="$1"
    local exit_code="$2"
    
    if [ "$exit_code" -eq 0 ]; then
        log_message "SUCCESS" "$description"
        TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: $description: SUCCESS"
    else
        log_message "FAILED" "$description"
        TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: $description: FAILED"
        ((FAILED_TASK_COUNTER++))
    fi
}

# Generate random string for passwords and usernames
function generate_random_string() {
    local length=$((RANDOM % 4 + 12))
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local random_string=""
    
    for ((i = 0; i < length; i++)); do
        local random_index=$((RANDOM % ${#chars}))
        random_string+=${chars:random_index:1}
    done
    
    echo "$random_string"
}

# Check if user is root
function check_if_user_is_root() {
    ((TASK_COUNTER++))
    log_message "INFO" "Checking if script is run as root..."
    
    if [ "$EUID" -ne 0 ]; then
        log_message "ERROR" "Please execute the script as root user"
        TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: Check for root user: FAILED"
        exit 1
    else
        log_message "INFO" "The script will be executed as root"
        TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: Check for root user: SUCCESS"
    fi
}

# Get hostname from API
function get_hostname_from_api() {
    ((TASK_COUNTER++))
    log_message "INFO" "Getting hostname from API..."
    
    local response=$(curl -s -X GET "$API_URL_GENERATE_HOSTNAME")
    HOSTNAME=$(echo "$response" | jq -r '.hostname')
    
    if [ -z "$HOSTNAME" ]; then
        log_message "ERROR" "No hostname received from API"
        TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: Get hostname from API: FAILED"
        exit 1
    else
        log_message "INFO" "The hostname is: $HOSTNAME"
        TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: Get hostname from API: SUCCESS"
    fi
}

# Check if hostname is set
function check_if_hostname_is_set() {
    ((TASK_COUNTER++))
    log_message "INFO" "Checking if hostname is set..."
    
    if [ -z "$HOSTNAME" ]; then
        log_message "INFO" "The hostname is not set, generating now..."
        local response=$(curl -s -X GET "$API_URL_GENERATE_HOSTNAME")
        HOSTNAME=$(echo "$response" | jq -r '.hostname')
        log_message "INFO" "The hostname is: $HOSTNAME"
    else
        log_message "INFO" "The hostname is set"
    fi
    
    if [ -z "$HOSTNAME" ]; then
        TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: Check if hostname is set: FAILED"
        ((FAILED_TASK_COUNTER++))
    else
        TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: Check if hostname is set: SUCCESS"
    fi
}

# Set keyboard layout
function set_keyboard_layout() {
    ((TASK_COUNTER++))
    log_message "INFO" "Setting keyboard layout to German (de) for Debian..."
    
    # Update keyboard configuration file
    sed -i 's/XKBLAYOUT="[^"]*"/XKBLAYOUT="de"/g' /etc/default/keyboard
    
    # Apply changes
    dpkg-reconfigure -f noninteractive keyboard-configuration
    systemctl restart keyboard-setup
    
    # Set for current session too
    loadkeys de
    
    local exit_code=$?
    record_status "Set keyboard layout to German" $exit_code
}

# Install required packages
function install_required_packages() {
    ((TASK_COUNTER++))
    log_message "INFO" "Installing required packages..."
    
    apt update
    
    for package_name in "${PACKAGE_NAMES[@]}"; do
        if ! command -v "${package_name}" >/dev/null 2>&1; then
            log_message "INFO" "${package_name} is not installed. Starting installation..."
            apt install -y "${package_name}"
            record_status "Install package ${package_name}" $?
        else
            log_message "INFO" "${package_name} is already installed"
            record_status "Install package ${package_name} (already installed)" 0
        fi
    done
}

# Set hostname
function set_hostname() {
    ((TASK_COUNTER++))
    log_message "INFO" "Setting the hostname to $HOSTNAME.mf-support.de"
    
    # Set hostname using Debian way
    hostnamectl set-hostname "$HOSTNAME.mf-support.de"
    
    # Update /etc/hosts
    sed -i "s/127.0.1.1.*/127.0.1.1\t$HOSTNAME.mf-support.de\t$HOSTNAME/" /etc/hosts
    
    record_status "Set system hostname" $?
}

# Set up network interface
function setup_network_interface() {
    ((TASK_COUNTER++))
    log_message "INFO" "Setting up the network interface..."
    
    # For Debian 12 using NetworkManager or systemd-networkd
    cat <<EOF > /etc/network/interfaces.d/eth0
auto eth0
iface eth0 inet dhcp
EOF
    
    # Restart networking
    systemctl restart networking
    
    record_status "Configure network interface" $?
}

# Set up timezone
function setup_timezone() {
    ((TASK_COUNTER++))
    log_message "INFO" "Setting up the timezone..."
    
    # Debian way to set timezone
    timedatectl set-timezone Europe/Berlin
    
    record_status "Set timezone to Europe/Berlin" $?
}

# Set up proxy (if needed)
function setup_proxy() {
    ((TASK_COUNTER++))
    log_message "INFO" "Setting up proxy configuration..."
    
    # Add proxy settings if needed
    # For example:
    # export http_proxy="http://proxy.example.com:8080"
    # export https_proxy="http://proxy.example.com:8080"
    
    record_status "Configure proxy" $?
}

# Configure sshd
function setup_sshd() {
    ((TASK_COUNTER++))
    log_message "INFO" "Setting up SSH server..."
    
    apt install -y openssh-server
    systemctl enable ssh
    systemctl start ssh
    
    record_status "Configure sshd" $?
}

# Configure NTP
function setup_ntp() {
    ((TASK_COUNTER++))
    log_message "INFO" "Setting up NTP with systemd-timesyncd..."
    
    apt install -y systemd-timesyncd
    systemctl enable systemd-timesyncd
    systemctl start systemd-timesyncd
    
    record_status "Configure ntp" $?
}

# Update the system
function update_system() {
    ((TASK_COUNTER++))
    log_message "INFO" "Updating the system..."
    
    apt update && apt upgrade -y
    
    record_status "Update the system" $?
}

# Configure tailscale
function configure_tailscale() {
    ((TASK_COUNTER++))
    log_message "INFO" "Configuring tailscale..."
    
    if command -v tailscale >/dev/null 2>&1; then
        systemctl enable tailscaled
        systemctl start tailscaled
        
        record_status "Start tailscale service" $?
        
        ((TASK_COUNTER++))
        if [ -z "$TAILSCALE_AUTH_KEY" ]; then
            log_message "ERROR" "Error: TAILSCALE_AUTH_KEY is not set."
            TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: Check tailscale_auth_key: FAILED"
            exit 1
        else
            echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
            echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
            sysctl -p /etc/sysctl.d/99-tailscale.conf
            tailscale up --login-server https://headscale.mf-support.de/ --authkey f40e4813813bd39fb66667c32082515e2df1c0e6ebe9404e --advertise-exit-node --reset
            
            record_status "Configure tailscale" $?
        fi
    else
        log_message "ERROR" "Tailscale is not installed."
        TASK_STATUS["$TASK_COUNTER"]="Task #$TASK_COUNTER: tailscale not installed: FAILED"
        exit 1
    fi
    
    sleep 30
}

# Set root user password
function set_root_password() {
    ((TASK_COUNTER++))
    log_message "INFO" "Setting root password..."
    
    ROOT_USER_PW=$(generate_random_string)
    echo "root:$ROOT_USER_PW" | chpasswd
    
    record_status "Set root password" $?
}

# Create admin user
function create_admin_user() {
    ((TASK_COUNTER++))
    log_message "INFO" "Creating random admin user..."
    
    ADMIN_USER_NAME=$(generate_random_string)
    ADMIN_USER_PW=$(generate_random_string)
    
    # Create user with home directory
    useradd -m -s /bin/bash "$ADMIN_USER_NAME"
    echo "$ADMIN_USER_NAME:$ADMIN_USER_PW" | chpasswd
    
    record_status "Create admin user ($ADMIN_USER_NAME)" $?
}

# Configure sudo access
function configure_sudo() {
    # Create sudo group if not exists
    ((TASK_COUNTER++))
    log_message "INFO" "Checking sudo group..."
    
    if grep -q "^sudo" /etc/group; then
        log_message "INFO" "The group sudo already exists."
        record_status "Create sudo group (already exists)" 0
    else
        addgroup sudo
        record_status "Create sudo group" $?
    fi
    
    # Add sudo group to sudoers
    ((TASK_COUNTER++))
    log_message "INFO" "Configuring sudoers..."
    
    cp /etc/sudoers /etc/sudoers.bak
    if grep -Fxq "%sudo ALL=(ALL:ALL) ALL" /etc/sudoers; then
        log_message "INFO" "Entry already in /etc/sudoers."
        record_status "Add sudo group to sudoers (already present)" 0
    else
        echo "%sudo ALL=(ALL:ALL) ALL" | tee -a /etc/sudoers
        record_status "Add sudo group to sudoers" $?
    fi
    
    # Add admin user to sudo group
    ((TASK_COUNTER++))
    log_message "INFO" "Adding user to sudo group..."
    
    usermod -aG sudo "$ADMIN_USER_NAME"
    record_status "Add $ADMIN_USER_NAME to sudo" $?
}

# Secure SSH configuration
function secure_ssh() {
    ((TASK_COUNTER++))
    log_message "INFO" "Securing SSH configuration..."
    
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
    
    # Add allowed users
    echo "AllowUsers $ADMIN_USER_NAME" | tee -a /etc/ssh/sshd_config
    
    # Restart SSH service
    systemctl restart ssh
    
    record_status "Secure SSH configuration" $?
}

# Configure fail2ban
function configure_fail2ban() {
    ((TASK_COUNTER++))
    log_message "INFO" "Configuring Fail2Ban..."
    
    # Create fail2ban configuration
    mkdir -p /etc/fail2ban
    cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = 600
findtime  = 600
maxretry = 5

[sshd]
enabled = true
EOF
    
    # Enable and start fail2ban
    systemctl enable fail2ban
    systemctl start fail2ban
    
    # Restart SSH service
    systemctl restart ssh
    
    record_status "Configure Fail2Ban" $?
}

# Install node exporter
function install_node_exporter() {
    ((TASK_COUNTER++))
    log_message "INFO" "Installing Prometheus Node Exporter..."
    
    # Download and extract node exporter for 64-bit
    wget https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.${NODE_EXPORTER_RELEASE}.tar.gz
    tar -xvf node_exporter-${NODE_EXPORTER_VERSION}.${NODE_EXPORTER_RELEASE}.tar.gz
    mv node_exporter-${NODE_EXPORTER_VERSION}.${NODE_EXPORTER_RELEASE}/node_exporter /usr/local/bin/
    rm -rf node_exporter-${NODE_EXPORTER_VERSION}.${NODE_EXPORTER_RELEASE} node_exporter-${NODE_EXPORTER_VERSION}.${NODE_EXPORTER_RELEASE}.tar.gz
    
    # Create node exporter user
    useradd -r -M -s /bin/false node_exporter
    
    # Create configuration directory
    mkdir -p /etc/prometheus_node_exporter/
    chmod 700 /etc/prometheus_node_exporter
    chown -R node_exporter:node_exporter /etc/prometheus_node_exporter
    
    # Create systemd service file for Debian
    cat <<EOF > /etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
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
    
    record_status "Install and start node_exporter" $?
}

# Send data to API
function send_data_to_api() {
    ((TASK_COUNTER++))
    log_message "INFO" "Sending data to API..."
    
    local response=$(curl -s -X POST $API_URL_UPDATE_DATA \
      -H "Content-Type: application/json" \
      -d "{
        \"hostname\": \"$HOSTNAME\",
        \"adminUserName\": \"$ADMIN_USER_NAME\",
        \"adminUserPw\": \"$ADMIN_USER_PW\",
        \"rootUserPw\": \"$ROOT_USER_PW\"
      }")
    
    record_status "Send data to the API" $?
}

# Print summary of tasks
function print_summary() {
    log_message "INFO" "Printing task summary..."
    
    echo
    echo "========================================"
    echo "Task summary:"
    for i in "${!TASK_STATUS[@]}"; do
        echo " - ${TASK_STATUS[$i]}"
    done
    echo "========================================"
    
    if [ $FAILED_TASK_COUNTER -ne 0 ]; then
        log_message "WARNING" "$FAILED_TASK_COUNTER/$TASK_COUNTER tasks failed"
    else
        log_message "INFO" "$TASK_COUNTER/$TASK_COUNTER tasks completed successfully"
    fi
}

# Final tailscale configuration
function final_tailscale_config() {
    log_message "INFO" "Performing final tailscale configuration..."
    
    tailscale up --login-server https://headscale.mf-support.de/ --authkey f40e4813813bd39fb66667c32082515e2df1c0e6ebe9404e --advertise-exit-node --reset
}

# Main execution flow
function main() {
    log_message "INFO" "Starting system setup for Debian 12..."
    
    check_if_user_is_root
    install_required_packages
    get_hostname_from_api
    check_if_hostname_is_set
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
    set_keyboard_layout
    set_hostname
    setup_network_interface
    setup_timezone
    setup_proxy
    setup_sshd
    setup_ntp
    update_system
    configure_tailscale
    set_root_password
    create_admin_user
    configure_sudo
    secure_ssh
    configure_fail2ban
    install_node_exporter
    send_data_to_api
    print_summary
    final_tailscale_config
    
    log_message "INFO" "Setup completed. System is ready."
    # Uncomment to enable automatic reboot
    # echo "Setup finished. Rebooting in 1 minute..."
    # sleep 60
    # reboot
}

# Execute main function
main
