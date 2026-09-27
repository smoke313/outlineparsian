#!/bin/bash
# OutlineParsian v8.6 Stable Installer
# SSH-safe execution, logging and recovery improvements
set -Eeuo pipefail
exec > >(tee -a /root/outlineparsian-install.log) 2>&1
export DEBIAN_FRONTEND=noninteractive
trap 'echo "❌ Installer failed at line $LINENO" >&2' ERR
if [ "$(id -u)" -ne 0 ]; then echo "❌ Run this installer as root"; exit 1; fi
if ! command -v apt-get >/dev/null 2>&1; then echo "❌ Debian/Ubuntu (apt) is required"; exit 1; fi
# ============================================
# OutlineParsian Ultimate Panel - Production Final v8.5 Port Login Fixed
# All Features | All Bugs Fixed | Production Ready
# SSH Traffic Counting + Xray Traffic
# Iran Block: Only outbound traffic to Iran blocked (inbound allowed)
# Backup Restore: Stable (mask/unmask method)
# ============================================

clear
cat << "BANNER"
   ____  _    _ _   _     _     ___  ____   ____   _    ____ ____  _    ____ _   _ 
  / __ \|  | | \ | |   | |   / _ \|  _ \ / ___| | |  / ___| _ \/ \  / ___| \ | |
 | |  | | |  | |  \| |   | | | | | | |_) | |     | | | |   | |_) / _ \ \___ \  \| |
 | |  | | |  | | . ` |   | |  | | | |  __/| |___  | | | |___|  _ < ___ \ ___) | |\  |
 | |__| | |__| | |\  |   | |__| |_| | |    \____| | |  \____|_| \_\   \_\____/|_| \_|
  \____/ \____/|_| \_| |_____\___/|_|          |_|
  
  OutlineParsian Ultimate Panel
BANNER

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     OutlineParsian Ultimate Panel                    ║"
echo "║     Complete Installation | Production Ready         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ============================================
# STEP 1: System Update & Prerequisites
# ============================================
echo "[1/16] Preparing system and installing prerequisites..."

echo ""
echo "⚡ System package update is optional."
echo "Recommended before installation:"
echo "apt update && apt upgrade -y"
echo ""

read -r -p "Do you want to update Ubuntu packages now? [y/N]: " UPDATE_SYSTEM

if [[ "${UPDATE_SYSTEM,,}" == "y" ]]; then
    echo "Updating system packages..."
    apt update -y
    apt upgrade -y
else
    echo "Skipping system upgrade. Continuing installation..."
fi

apt update -y
apt install -y python3 python3-pip python3-venv nginx ipset iptables curl netfilter-persistent iptables-persistent unzip wget sqlite3 net-tools jq certbot python3-certbot-nginx qrencode openssh-server chrony cron
true # Python dependencies are installed in the panel virtualenv below
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
systemctl enable --now cron 2>/dev/null || true
echo "✓ Prerequisites installed"

# ============================================
# STEP 2: SSH Configuration
# ============================================
echo "[2/16] Configuring SSH safely..."
echo "Firewall configuration started"
mkdir -p /etc/ssh/sshd_config.d
if [ -f /etc/ssh/sshd_config ] && [ ! -f /etc/ssh/sshd_config.outlineparsian.bak ]; then
    cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.outlineparsian.bak
fi
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
    sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
cat << 'EOF' > /etc/ssh/sshd_config.d/99-outlineparsian.conf
Port 22
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
AllowTcpForwarding yes
GatewayPorts yes
MaxStartups 50:30:200
MaxSessions 50
EOF
if ! /usr/sbin/sshd -t; then
    echo "❌ SSH config validation failed; restoring previous config"
    rm -f /etc/ssh/sshd_config.d/99-outlineparsian.conf
    [ -f /etc/ssh/sshd_config.outlineparsian.bak ] && cp -a /etc/ssh/sshd_config.outlineparsian.bak /etc/ssh/sshd_config
    exit 1
fi
timeout 15 systemctl enable ssh || true
timeout 15 systemctl reload ssh || true
for p in 22 80 443 ${PANEL_PORT:-5000}; do
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
