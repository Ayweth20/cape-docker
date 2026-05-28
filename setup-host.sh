#!/bin/bash
# ============================================================
# setup-host.sh — Préparer le host Ubuntu pour CAPEv2 Docker
# À exécuter UNE SEULE FOIS sur le serveur host AVANT docker-compose up
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
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# ── Vérifications préliminaires ───────────────────────────────
if [ "$(id -u)" != "0" ]; then
    err "Ce script doit être exécuté en tant que root (sudo)"
    exit 1
fi

UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
info "Ubuntu version : $UBUNTU_VERSION"

# ── 1. Installation de KVM/QEMU/libvirt ──────────────────────
log "Installation de KVM, QEMU et libvirt..."
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

# Vérifier la virtualisation matérielle
if ! kvm-ok 2>/dev/null; then
    warn "La virtualisation KVM n'est pas disponible (nested virt ou hardware)."
    warn "CAPEv2 nécessite KVM pour les VMs d'analyse."
fi

# Démarrer et activer libvirtd
systemctl enable --now libvirtd
log "libvirtd activé et démarré"

# ── 2. Configuration du réseau KVM (virbr1) ───────────────────
log "Configuration du réseau KVM 'cape-analysis'..."

# Réseau ISOLÉ pour l'analyse malware (pas de NAT = pas d'accès Internet)
# Les VMs peuvent joindre le Result Server (192.168.122.1) mais pas Internet.
NETWORK_XML=$(cat << 'EOF'
<network>
  <name>cape-analysis</name>
  <!-- Réseau isolé : aucun forward vers l'extérieur -->
  <bridge name='virbr1' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.100' end='192.168.122.200'/>
    </dhcp>
  </ip>
</network>
EOF
)

# Définir et démarrer le réseau si inexistant
if ! virsh net-info cape-analysis > /dev/null 2>&1; then
    echo "$NETWORK_XML" | virsh net-define /dev/stdin
    virsh net-start cape-analysis
    virsh net-autostart cape-analysis
    log "Réseau 'cape-analysis' (virbr1, 192.168.122.0/24) créé"
else
    warn "Réseau 'cape-analysis' existe déjà"
    virsh net-start cape-analysis 2>/dev/null || true
fi

# ── 3. Règles iptables pour le réseau isolé ───────────────────
log "Configuration des règles iptables (réseau isolé)..."

# Autoriser la capture de trafic sur virbr1 (cape-sandbox en --net=host)
iptables -I FORWARD -i virbr1 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD -o virbr1 -j ACCEPT 2>/dev/null || true

# BLOQUER tout accès Internet depuis les VMs d'analyse
# Les VMs voient uniquement le Result Server (192.168.122.1)
INTERNET_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -1)
if [ -n "$INTERNET_IFACE" ]; then
    iptables -I FORWARD -i virbr1 -o "$INTERNET_IFACE" -j DROP 2>/dev/null || true
    log "Bloc Internet depuis virbr1 vers $INTERNET_IFACE : ACTIF"
fi

# Rendre les règles persistantes
if command -v iptables-save > /dev/null 2>&1; then
    apt-get install -y -qq iptables-persistent 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

# ── 4. Permissions du socket libvirt ──────────────────────────
log "Configuration des permissions libvirt..."
LIBVIRT_CONF="/etc/libvirt/libvirtd.conf"
if [ -f "$LIBVIRT_CONF" ]; then
    # Permettre l'accès au socket sans authentification (localhost seulement)
    sed -i 's/#unix_sock_group = "libvirt"/unix_sock_group = "libvirt"/' "$LIBVIRT_CONF"
    sed -i 's/#unix_sock_rw_perms = "0770"/unix_sock_rw_perms = "0770"/' "$LIBVIRT_CONF"
    systemctl restart libvirtd
    log "Permissions libvirt configurées"
fi

# ── 5. Ajouter l'utilisateur courant aux groupes libvirt ──────
CURRENT_USER="${SUDO_USER:-$USER}"
if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
    usermod -aG libvirt "$CURRENT_USER"
    usermod -aG libvirt-qemu "$CURRENT_USER" 2>/dev/null || true
    usermod -aG kvm "$CURRENT_USER"
    log "Utilisateur '$CURRENT_USER' ajouté aux groupes libvirt, kvm"
fi

# ── 6. Créer les répertoires de données ──────────────────────
log "Création des répertoires de données..."
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
    log "  Créé : $dir"
done


# ── 7. Résumé et prochaines étapes ────────────────────
echo ""
echo "================================================================"
echo -e "${GREEN}✓ Configuration du host terminée !${NC}"
echo "================================================================"
echo ""
echo -e "${YELLOW}PROCHAINES ÉTAPES :${NC}"
echo ""
echo "1. Vérifier que la VM Win10 est bien reconnue par libvirt :"
echo "   virsh list --all"
echo "   virsh snapshot-list win10"
echo ""
echo "2. Vérifier la connectivité réseau avec la VM :"
echo "   ping 192.168.122.105          # IP de la VM Win10"
echo "   python3 scripts/prepare-vm.py --test-agent win10 192.168.122.105"
echo ""
echo "3. Vérifier que le volume dédié est monté :"
echo "   mountpoint /mnt/cape          # Doit retourner 'is a mountpoint'"
echo "   df -h /mnt/cape               # Vérifier l'espace disponible"
echo ""
echo "4. Éditer le fichier .env avec vos paramètres (VM, IPs, passwords) :"
echo "   nano .env"
echo ""
echo "5. Lancer CAPEv2 :"
echo "   docker-compose up -d --build"
echo "   docker-compose logs -f cape-sandbox"
echo ""
echo "6. Accéder à l'interface :"
echo "   http://IP_DU_SERVEUR          (via Nginx)"
echo "   http://IP_DU_SERVEUR:8000     (direct)"
echo ""
info "Redémarrez votre session pour que les changements de groupes prennent effet."
echo ""
