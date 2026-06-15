#!/bin/bash
# ============================================================
# setup-host.sh -- Prepare the Ubuntu host for CAPEv2 Docker
# Run ONCE on the host server BEFORE docker-compose up
# ============================================================
# Usage: sudo bash setup-host.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# -- Preliminary checks --
if [ "$(id -u)" != "0" ]; then
    err "This script must be run as root (sudo)"
    exit 1
fi

UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
info "Ubuntu version: $UBUNTU_VERSION"

# -- 1. Install KVM/QEMU/libvirt --
log "Installing KVM, QEMU and libvirt..."
apt-get update -qq
apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    libvirt-dev \
    bridge-utils \
    virt-manager \
    virtinst \
    cpu-checker

# Check hardware virtualization support
if ! kvm-ok 2>/dev/null; then
    warn "KVM virtualization is not available (nested virt or hardware)."
    warn "CAPEv2 requires KVM for analysis VMs."
fi

# Enable and start libvirtd
systemctl enable --now libvirtd
log "libvirtd enabled and started"

# -- 2. Configure the KVM network (virbr1) --
log "Configuring the KVM network 'cape-analysis'..."

# Isolated network for malware analysis (no NAT = no Internet access)
# VMs can reach the ResultServer (192.168.122.1) but not the Internet.
NETWORK_XML=$(cat << 'EOF'
<network>
  <name>cape-analysis</name>
  <!-- Isolated network: no forwarding to the outside -->
  <bridge name='virbr1' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.100' end='192.168.122.200'/>
    </dhcp>
  </ip>
</network>
EOF
)

# Define and start the network if it does not exist
if ! virsh net-info cape-analysis > /dev/null 2>&1; then
    echo "$NETWORK_XML" | virsh net-define /dev/stdin
    virsh net-start cape-analysis
    virsh net-autostart cape-analysis
    log "Network 'cape-analysis' (virbr1, 192.168.122.0/24) created"
else
    warn "Network 'cape-analysis' already exists"
    virsh net-start cape-analysis 2>/dev/null || true
fi

# -- 3. iptables rules for the isolated network --
log "Configuring iptables rules (isolated network)..."

# Allow traffic capture on virbr1 (cape-sandbox runs with --net=host)
iptables -I FORWARD -i virbr1 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -o virbr1 -j ACCEPT 2>/dev/null || true

# Block all Internet access from analysis VMs
# VMs can only reach the ResultServer (192.168.122.1)
INTERNET_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -1)
if [ -n "$INTERNET_IFACE" ]; then
    iptables -I FORWARD -i virbr1 -o "$INTERNET_IFACE" -j DROP 2>/dev/null || true
    log "Internet block from virbr1 to $INTERNET_IFACE: ACTIVE"
fi

# Persist the rules
if command -v iptables-save > /dev/null 2>&1; then
    apt-get install -y -qq iptables-persistent 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

# -- 4. Libvirt socket permissions --
log "Configuring libvirt permissions..."
LIBVIRT_CONF="/etc/libvirt/libvirtd.conf"
if [ -f "$LIBVIRT_CONF" ]; then
    # Allow socket access without authentication (localhost only)
    sed -i 's/#unix_sock_group = "libvirt"/unix_sock_group = "libvirt"/' "$LIBVIRT_CONF"
    sed -i 's/#unix_sock_rw_perms = "0770"/unix_sock_rw_perms = "0770"/' "$LIBVIRT_CONF"
    systemctl restart libvirtd
    log "Libvirt permissions configured"
fi

# -- 5. Add the current user to libvirt groups --
CURRENT_USER="${SUDO_USER:-$USER}"
if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
    usermod -aG libvirt "$CURRENT_USER"
    usermod -aG libvirt-qemu "$CURRENT_USER" 2>/dev/null || true
    usermod -aG kvm "$CURRENT_USER"
    log "User '$CURRENT_USER' added to libvirt and kvm groups"
fi

# -- 6. Create data directories --
log "Creating data directories..."
DATA_DIRS=(
    "./data/cape/conf"
    "./data/cape/storage"
    "./data/cape/log"
    "./data/postgresql"
    "./data/mongodb"
    "./nginx/ssl"
)
for dir in "${DATA_DIRS[@]}"; do
    mkdir -p "$dir"
    log "  Created: $dir"
done


# -- 7. Summary and next steps --
echo ""
echo "================================================================"
echo -e "${GREEN}[+] Host configuration complete.${NC}"
echo "================================================================"
echo ""
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo ""
echo "1. Verify that the Windows VM is recognized by libvirt:"
echo "   virsh list --all"
echo "   virsh snapshot-list win10"
echo ""
echo "2. Check network connectivity with the VM:"
echo "   ping 192.168.122.105          # VM IP"
echo "   python3 scripts/prepare-vm.py --test-agent win10 192.168.122.105"
echo ""
echo "3. Check that the dedicated volume is mounted:"
echo "   mountpoint /mnt/cape          # Should return 'is a mountpoint'"
echo "   df -h /mnt/cape               # Check available space"
echo ""
echo "4. Edit the .env file with your settings (VM, IPs, passwords):"
echo "   nano .env"
echo ""
echo "5. Start CAPEv2:"
echo "   docker-compose up -d --build"
echo "   docker-compose logs -f cape-sandbox"
echo ""
echo "6. Access the interface:"
echo "   http://SERVER_IP          (via Nginx)"
echo "   http://SERVER_IP:8000     (direct)"
echo ""
info "Restart your session for group changes to take effect."
echo ""
