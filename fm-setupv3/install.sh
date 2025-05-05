#!/bin/bash
set -x

export DEBIAN_FRONTEND=noninteractive

# --- tzdata non-interactive vorab befüllen ---
echo "tzdata tzdata/Areas select Europe"   | debconf-set-selections
echo "tzdata tzdata/Zones/Europe select Berlin" | debconf-set-selections
# ------------------------------------------------

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
node_exporter_version="1.8.2"
node_exporter_release="linux-amd64"
# tzdata ergänzt
packageNames=("tzdata" "tailscale" "fail2ban" "sudo" "curl" "jq" "tar")
auth_key="f40e4813813bd39fb66667c32082515e2df1c0e6ebe9404e"
adminUserName=""
adminUserPw=""
hostname=""
fm_model="o1"
api_url_generate_hostname="http://192.168.20.9:5000/api/v1/fm/generate-hostname"
api_url_update_data="http://192.168.20.9:5000/api/v1/fm/update"
rootUserPw=""

# Helper to generate random strings
generateRandomString() {
    local length=$((RANDOM % 4 + 12))
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c"$length"
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

# Install Tailscale if it is not already installed
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

((taskCounter++))
install_tailscale
recordStatus "Installing Tailscale..." $?

# 2) Install required packages (inkl. tzdata nun non-interactive)
((taskCounter++))
for packageName in "${packageNames[@]}"; do
    if ! command -v "${packageName}" >/dev/null 2>&1; then
        echo "${packageName} is not installed. Starting installation..."
        apt update -y && apt install -y "${packageName}"
        recordStatus "Install package ${packageName}" $?
    else
        echo "${packageName} is already installed"
        recordStatus "Install package ${packageName} (already installed)" 0
    fi
done

# ... (der Rest bis zur Tailscale-Funktion bleibt unverändert) ...

start_tailscale() {
    echo -e "${GREEN}Starting Tailscale with --advertise-tags 'tag:tailmox'...${RESET}"

    # Versuch systemd-first
    if systemctl enable tailscaled && systemctl start tailscaled; then
        recordStatus "Start tailscale service (systemd)" 0
    else
        echo -e "${YELLOW}systemd nicht verfügbar, starte tailscaled manuell...${RESET}"
        nohup tailscaled --tun=userspace-networking \
            --state=/var/lib/tailscale/tailscaled.state \
            >/var/log/tailscaled.log 2>&1 &
        sleep 2
        recordStatus "Start tailscale service (manual)" $?
    fi

    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
    sysctl -p /etc/sysctl.d/99-tailscale.conf || true

    if [ -n "$auth_key" ]; then
        tailscale up --login-server https://headscale.mf-support.de/ \
                     --auth-key="$auth_key" \
                     --advertise-exit-node --reset
    else
        tailscale up --advertise-tags "tag:test" --advertise-exit-node --reset
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to start Tailscale.${RESET}"
        exit 1
    fi

    # Warte auf IP
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

((taskCounter++))
start_tailscale
recordStatus "Starting Tailscale..." $?

# ... Rest des Skripts wie gehabt ...
