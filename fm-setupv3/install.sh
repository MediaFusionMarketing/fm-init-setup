**Überarbeiten des Bash-Skripts**

Der Benutzer möchte, dass ich ein Bash-Skript mit vielen Aufgaben überarbeite. Das Skript enthält unter anderem die Installation von Tailscale, die Konfiguration von Netzwerk, Zeitzone, SSH und Fail2ban. Es gibt auch Probleme mit tzdata und der Verwendung von systemctl. Vermutlich läuft die Umgebung in einem Container, weshalb systemd erforderlich sein könnte. Ich muss sicherstellen, dass die tzdata-Konfiguration korrekt vor der Installation von Paketen wie Tailscale gesetzt wird und systemd korrekt genutzt wird.


Nachgedacht für 4 Sekunden


Hier eine aufgeräumte und korrigierte Version, die

1. **tzdata** non-interaktiv vor­konfiguriert
2. `apt-get` konsequent mit `-y` und `DEBIAN_FRONTEND=noninteractive` nutzt
3. den **tailscaled**-Service wirklich per `systemctl` startet
4. Variablen richtig setzt und `recordStatus` immer direkt nach dem Befehl aufruft

```bash
#!/bin/bash
set -xe
export DEBIAN_FRONTEND=noninteractive

# Farben für Ausgaben
YELLOW="\e[33m"
RED="\e[31m"
GREEN="\e[32m"
RESET="\e[0m"

# Status-Tracking
taskCounter=0
failedTaskCounter=0
declare -a taskStatus

recordStatus() {
  local desc="$1"; shift
  local code=$?
  ((taskCounter++))
  if [ $code -eq 0 ]; then
    taskStatus[$taskCounter]="$desc: SUCCESS"
  else
    taskStatus[$taskCounter]="$desc: FAILED"
    ((failedTaskCounter++))
  fi
}

# Paketliste
packageNames=(tzdata tailscale fail2ban sudo curl jq tar openssh-server systemd-timesyncd)

# Tailscale-Authkey
auth_key="f40e4813813bd39fb66667c32082515e2df1c0e6ebe9404e"

# Zufallsstring-Generator
generateRandomString() {
  local len=$(( RANDOM % 4 + 12 ))
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c"$len"
}

########################################
# 1) Root-Check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Bitte als root ausführen!${RESET}"
  exit 1
fi
echo -e "${GREEN}Running as root, good.${RESET}"

# 2) System-Update & tzdata non-interactive
echo "Preseed tzdata..."
echo "tzdata tzdata/Areas select Europe" | debconf-set-selections
echo "tzdata tzdata/Zones/Europe select Berlin" | debconf-set-selections

apt-get update -y
recordStatus "apt-get update"

apt-get install -y "${packageNames[@]}"
recordStatus "Install base packages (inkl. tzdata)"

# 3) Tailscale Repository hinzufügen (falls noch nicht da)
if ! grep -q '^deb .*pkgs.tailscale.com' /etc/apt/sources.list.d/tailscale.list 2>/dev/null; then
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list
  apt-get update -y
  recordStatus "Add Tailscale APT repo"
fi

# 4) tailscale (erneut) installieren
apt-get install -y tailscale
recordStatus "Install tailscale"

# 5) tailscaled Service aktivieren & starten
systemctl enable --now tailscaled
recordStatus "Enable & start tailscaled"

# 6) Sysctl fürs Forwarding
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding=1' >>/etc/sysctl.d/99-tailscale.conf
sysctl --system
recordStatus "Apply sysctl forwarding"

# 7) Tailscale up
tailscale up \
  --login-server https://headscale.mf-support.de/ \
  --auth-key="$auth_key" \
  --advertise-exit-node \
  --reset
recordStatus "tailscale up"

# 8) Hostname setzen
new_hostname=$(curl -s http://192.168.20.9:5000/api/v1/fm/generate-hostname \
  -H 'Content-Type: application/json' \
  -d '{"fm-model":"o1"}' \
  | jq -r .hostname)
if [ -z "$new_hostname" ] || [ "$new_hostname" = "null" ]; then
  echo -e "${RED}Hostname-API lieferte keinen Wert!${RESET}"
  exit 1
fi
hostnamectl set-hostname "$new_hostname.mf-support.de"
recordStatus "Set hostname to $new_hostname"

# 9) Netzwerk-Interface (Debian-stil)
cat >/etc/network/interfaces.d/eth0 <<EOF
auto eth0
iface eth0 inet dhcp
EOF
recordStatus "Configure eth0 DHCP"

# 10) Zeitzone ❤️
timedatectl set-timezone Europe/Berlin
recordStatus "Set timezone Europe/Berlin"

# 11) SSH hart machen
sed -i 's/^#PermitRootLogin .*$/PermitRootLogin no/' /etc/ssh/sshd_config
echo "AllowUsers" $(generateRandomString) >>/etc/ssh/sshd_config
systemctl restart ssh
recordStatus "Harden SSH"

# 12) Fail2Ban konfigurieren
cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime  = 600
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban
recordStatus "Configure Fail2Ban"

# 13) Node Exporter installieren & Service
node_ver="1.8.2"
arch="linux-amd64"
cd /tmp
curl -sL "https://github.com/prometheus/node_exporter/releases/download/v${node_ver}/node_exporter-${node_ver}.${arch}.tar.gz" \
  | tar xz
mv "node_exporter-${node_ver}.${arch}/node_exporter" /usr/local/bin/
useradd -r -s /bin/false node_exporter || true
cat >/etc/systemd/system/node_exporter.service <<EOF
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
systemctl daemon-reload
systemctl enable --now node_exporter
recordStatus "Install & start node_exporter"

# 14) Daten an API senden
root_pw=$(generateRandomString)
admin_user=$(generateRandomString)
admin_pw=$(generateRandomString)

echo "root:$root_pw" | chpasswd
useradd -m "$admin_user"
echo "$admin_user:$admin_pw" | chpasswd
usermod -aG sudo "$admin_user"

curl -s -X POST http://192.168.20.9:5000/api/v1/fm/update \
  -H "Content-Type: application/json" \
  -d "{\"hostname\":\"$new_hostname\",\"adminUserName\":\"$admin_user\",\"adminUserPw\":\"$admin_pw\",\"rootUserPw\":\"$root_pw\"}"
recordStatus "Send credentials to API"

# Zusammenfassung
echo
echo "========== Task Summary =========="
for i in "${!taskStatus[@]}"; do
  echo " - ${taskStatus[$i]}"
done
echo "Failures: $failedTaskCounter/$taskCounter"
echo "=================================="
```

### Was wurde geändert?

* **tzdata** über `debconf-set-selections` vorab konfiguriert, dann gleich mitinstalliert.
* `apt-get install -y` kombiniert mit `DEBIAN_FRONTEND=noninteractive`.
* `systemctl enable --now tailscaled` sorgt dafür, dass der Daemon wirklich läuft, bevor `tailscale up` aufgerufen wird.
* Falsche Variable-Zuweisungen (`$rootUserPw=…`) wurden korrigiert.
* `recordStatus` immer unmittelbar nach dem relevanten Befehl aufgerufen.
* Unnötige Dopplungen (zweimal Paket-Install) entfernt und die Reihenfolge optimiert.

Damit sollte das Skript durchlaufen, ohne in Interaktiv-Dialoge zu rennen, und Tailscale wie gewünscht hochfahren.
