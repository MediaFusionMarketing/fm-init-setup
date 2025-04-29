#/var/www/html/pxe/install.sh
#!/bin/bash

# Track tasks
taskCounter=0
failedTaskCounter=0
declare -a taskStatus


node_exporter_version="1.8.2"
node_exporter_release="linux-386"
packageNames=("tailscale" "fail2ban" "sudo" "curl" "jq" "tar")
tailscale_auth_key="a40b64256e364c27d806b2222c104a030a7a1ab53cc6099e"
adminUserName=""
adminUserPw=""
hostname=""
fm_model=""
api_url_generate_hostname="http://192.168.20.9:5000/api/v1/fm/generate-hostname"
api_url_update_data="http://192.168.20.9:5000/api/v1/fm/update"
rootUserPw= ""

# Helper function to record each task's status
function recordStatus() {
    local description="$1"
    local exitCode="$2"
    if [ "$exitCode" -eq 0 ]; then
        taskStatus["$taskCounter"]="$description: SUCCESS"
    else
        taskStatus["$taskCounter"]="$description: FAILED"
        ((failedTaskCounter++))
    fi
}


# Generate random string
function generateRandomString() {
    local lenght=$((RANDOM % 4 + 12))
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    local randomString=""
    for ((i = 0; i < lenght; i++)); do
        randomIndex=$((RANDOM % ${#chars}))
        randomString+=${chars:randomIndex:1}
    done
}


function check_if_user_is_root() {
    ((taskCounter++))
    if [ "$EUID" -ne 0 ]; then
        echo "FAILED: Please execute the Script as root user"
        taskStatus["$taskCounter"]="Task #$taskCounter: Check for root user: FAILED"
        exit 1
    else
        echo "NOTE: the script will be executed as root"
        taskStatus["$taskCounter"]="Task #$taskCounter: Check for root user: SUCCESS"
    fi
}


function get_hostname_from_api() {
    ((taskCounter++))
    response=$(curl -s -X GET "$api_url_generate_hostname")
    hostname=$(echo "$response" | jq -r '.hostname')
    if [ -z "$hostname" ]; then
        echo "No hostname received from API"
        taskStatus["$taskCounter"]="Task #$taskCounter: Get hostname from API: FAILED"
        exit 1
    else
        echo "The hostname is: $hostname"
        taskStatus["$taskCounter"]="Task #$taskCounter: Get hostname from API: SUCCESS"
    fi
}

function check_if_hostname_is_set() {
    ((taskCounter++))
    if [ -z "$hostname" ]; then
        echo "The hostname is not set, generating now..."
        response=$(curl -s -X GET "$api_url_generate_hostname")
        hostname=$(echo "$response" | jq -r '.hostname')
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
}

function set_keyboard_layout() {
    ((taskCounter++))
    echo "Setting keyboard layout to German (de) for Debian..."
    
    # Update keyboard configuration file
    sed -i 's/XKBLAYOUT="[^"]*"/XKBLAYOUT="de"/g' /etc/default/keyboard
    
    # Apply changes
    dpkg-reconfigure -f noninteractive keyboard-configuration
    service keyboard-setup restart
    
    # Set for current session too
    loadkeys de
    
    exitCode=$?
    recordStatus "Set keyboard layout to German" $exitCode
}