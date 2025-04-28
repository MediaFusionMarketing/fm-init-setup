#!/bin/bash

#Install script fehlt noch

###
### --- DHCP ---
#Set next-server IP
#192.168.x.x
# Set default bios filename
# pxelinux.0
#Set x64 UEFI/EBC (64-bit) filename
# pxelinux.0
#Set iPXE boot filename
# pxelinux.0



# Define color variables
YELLOW="\e[33m"
RED="\e[31m"
GREEN="\e[32m"
BLUE="\e[34m"
PURPLE="\e[35m"
RESET="\e[0m"

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${RESET}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${RESET}"
    exit 1
}

log_info() {
    echo -e "${BLUE}[INFO] $1${RESET}"
}

# Ask for TFTP server IP address
echo -e "${YELLOW}Enter the IP address of the TFTP server:${RESET}"
read -p "IP Address: " TFTP_SERVER_IP

# Validate IP address format
if [[ ! $TFTP_SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    log_error "Invalid IP address format. Please use format: xxx.xxx.xxx.xxx"
fi

log_info "Using TFTP server IP: $TFTP_SERVER_IP"

echo -e "${YELLOW}Starting TFTP server installation...${RESET}"

# Rest of your script continues as before...

echo -e "${YELLOW}Starting TFTP server installation...${RESET}"

# Update package list
log_info "Updating package list..."
if sudo apt update; then
    log_success "Package list updated successfully."
else
    log_error "Failed to update package list."
fi

# Install TFTP server
log_info "Installing TFTP server..."
if sudo apt install -y tftpd-hpa; then
    log_success "TFTP server installed successfully."
else
    log_error "Failed to install TFTP server."
fi

# Configure TFTP server
log_info "Configuring TFTP server..."
sudo mkdir -p /srv/tftp
sudo chmod 777 /srv/tftp

if sudo tee /etc/default/tftpd-hpa > /dev/null << EOF; then
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure"
EOF
    log_success "TFTP server configured successfully."
else
    log_error "Failed to configure TFTP server."
fi

log_info "Restarting TFTP server..."
if sudo systemctl restart tftpd-hpa && sudo systemctl status tftpd-hpa; then
    log_success "TFTP server restarted successfully."
else
    log_error "Failed to restart TFTP server."
fi

# Download netboot files
log_info "Downloading netboot files..."
if wget http://ftp.debian.org/debian/dists/stable/main/installer-amd64/current/images/netboot/netboot.tar.gz; then
    log_success "Netboot files downloaded successfully."
else
    log_error "Failed to download netboot files."
fi

log_info "Extracting netboot files..."
if sudo tar -xzf netboot.tar.gz -C /srv/tftp; then
    log_success "Netboot files extracted successfully."
else
    log_error "Failed to extract netboot files."
fi

# Create preseed configuration
log_info "Creating preseed configuration file..."
if sudo tee preseed.cfg > /dev/null << EOF; then
# Preseed configuration file for automated installation
### Lokalisierung
d-i debian-installer/locale string de_DE.UTF-8
d-i keyboard-configuration/xkb-keymap select de

### Netzwerk
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string dein-hostname
d-i netcfg/get_domain string dein.domain.local

### Zeitzone
d-i time/zone string Europe/Berlin
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true

### Mirror
d-i mirror/country string manual
d-i mirror/http/hostname string ftp.de.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

### Partitionierung (komplett automatisch, gesamte Platte nutzen!)
d-i partman-auto/method string regular
d-i partman-auto/disk string /dev/sda
d-i partman-auto/choose_recipe select atomic
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman/confirm_write_new_label seen true

### Benutzer-Setup (nur root, kein normaler User)
d-i passwd/root-password password rootpasswort
d-i passwd/root-password-again password rootpasswort
d-i passwd/make-user boolean false

### Paketauswahl
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string sudo vim curl wget
d-i pkgsel/upgrade select none

### Kein CD-Scan
d-i cdrom-detect/try-usb boolean true

### Keine Fragen nach Popularity Contest
popularity-contest popularity-contest/participate boolean false

# Bootloader GRUB automatisch installieren
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string /dev/sda

### Abschluss-Skript ausführen
d-i preseed/late_command string \
    anna-install wget; \
    wget -O /target/root/install.sh http://${TFTP_SERVER_IP}/pxe/install.sh; \
    chmod +x /target/root/install.sh; \
    chroot /target /root/install.sh
EOF
    log_success "Preseed configuration file created successfully."
else
    log_error "Failed to create preseed configuration file."
fi

# Install Apache2
log_info "Installing Apache2 for serving files..."
if sudo apt install -y apache2; then
    log_success "Apache2 installed successfully."
else
    log_error "Failed to install Apache2."
fi

touch install.sh
log_info "Creating install.sh script..."
# Create install.sh script

sudo tee /root/install.sh > /dev/null << EOF
#!/bin/bash
# Install additional packages
touch /root/test.txt
EOF

log_info "Configuring Apache2..."
sudo mkdir -p /var/www/html/pxe
sudo cp preseed.cfg /var/www/html/pxe/
sudo cp install.sh /var/www/html/pxe/

if sudo tee /srv/tftp/pxelinux.cfg/default > /dev/null << EOF; then
DEFAULT install
LABEL install
    KERNEL debian-installer/amd64/linux
    APPEND initrd=debian-installer/amd64/initrd.gz auto=true priority=critical preseed/url=http://${TFTP_SERVER_IP}/pxe/preseed.cfg
EOF
    log_success "Apache2 configured successfully."
else
    log_error "Failed to configure Apache2."
fi

echo -e "${YELLOW}TFTP server installation and configuration completed.${RESET}"
echo -e "${GREEN}You can now boot your machine via PXE and it will use the preseed file for installation.${RESET}"