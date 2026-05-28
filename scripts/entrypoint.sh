#!/bin/bash
# ============================================================
# entrypoint.sh — Point d'entrée du conteneur CAPE Sandbox
# Adapté de celyrin/cape-docker pour KVM/libvirt
# ============================================================
set -e

CAPE_ROOT="${CAPE_ROOT:-/opt/CAPEv2}"
CAPE_USER="${CAPE_USER:-cape}"
WORK="/work"
POSTGRES_HOST="${POSTGRES_HOST:-postgresql}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-cape}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-SuperPuperSecret}"
POSTGRES_DB="${POSTGRES_DB:-cape}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── 1. Vérification du socket libvirt ─────────────────────────
log "Vérification du socket libvirt..."
LIBVIRT_SOCK="/var/run/libvirt/libvirt-sock"
if [ ! -S "$LIBVIRT_SOCK" ]; then
    log "ERREUR : Socket libvirt non trouvé : $LIBVIRT_SOCK"
    log "Assurez-vous que libvirtd est actif sur le host et que le socket est monté."
    exit 1
fi
log "Socket libvirt trouvé : OK"

# Tester la connexion libvirt
if ! virsh -c qemu:///system list --all > /dev/null 2>&1; then
    log "AVERTISSEMENT : Impossible de se connecter à libvirt. Vérifiez les permissions du socket."
fi

# ── 2. Attendre PostgreSQL ────────────────────────────────────
log "Attente de PostgreSQL sur ${POSTGRES_HOST}:${POSTGRES_PORT}..."
MAX_RETRIES=30
RETRIES=0
until PGPASSWORD="${POSTGRES_PASSWORD}" pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" > /dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [ $RETRIES -ge $MAX_RETRIES ]; then
        log "ERREUR : PostgreSQL indisponible après ${MAX_RETRIES} tentatives."
        exit 1
    fi
    log "PostgreSQL non prêt, nouvelle tentative dans 5s... ($RETRIES/$MAX_RETRIES)"
    sleep 5
done
log "PostgreSQL prêt : OK"

# Créer le rôle et la base de données si nécessaire
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d postgres -c "SELECT 1" > /dev/null 2>&1 || true

# ── 3. Vérification du répertoire de travail ──────────────────
log "Vérification du répertoire de travail : $WORK"
if [ ! -d "$WORK" ]; then
    log "ERREUR : Répertoire /work non trouvé. Vérifiez le volume Docker."
    exit 1
fi
chown -R "${CAPE_USER}:${CAPE_USER}" "$WORK"

# ── 4. Gérer la configuration CAPE (symlinks vers /work) ──────
# Inspiré de l'approche celyrin/cape-docker :
# conf, storage, log sont stockés dans /work et liés symboliquement

for dir in conf storage log; do
    SRC="${CAPE_ROOT}/${dir}"
    DST="${WORK}/${dir}"

    if [ -L "${SRC}" ]; then
        log "CAPEv2 ${dir} est déjà un lien symbolique : OK"
    elif [ -d "${DST}" ]; then
        log "Sauvegarde de ${dir} trouvée dans /work, liaison..."
        rm -rf "${SRC}"
        chown -R "${CAPE_USER}:${CAPE_USER}" "${DST}"
        ln -s "${DST}" "${SRC}"
    elif [ -d "${SRC}" ]; then
        log "Déplacement de ${dir} vers /work et création du lien..."
        mv "${SRC}" "${DST}"
        ln -s "${DST}" "${SRC}"
        chown -R "${CAPE_USER}:${CAPE_USER}" "${DST}"
    else
        log "Création de ${dir} dans /work..."
        sudo -u "${CAPE_USER}" mkdir -p "${DST}"
        ln -s "${DST}" "${SRC}"
    fi
done

# ── 5. Configuration automatique via script Python ─────────────
log "Configuration de CAPE..."
python3 /configure-cape.py
chmod 666 "${WORK}/conf/kvm.conf" || true

# ── 6. Initialisation de la BDD CAPE ─────────────────────────
log "Initialisation de la base de données CAPE..."
cd "${CAPE_ROOT}"
# Créer le schéma de manière synchrone pour éviter les conflits de concurrence entre cuckoo et process
sudo -u "${CAPE_USER}" python3 -c "import sys; sys.path.append('${CAPE_ROOT}'); from lib.cuckoo.core.database import init_database; init_database()" || log "Note: Initialisation/migration synchrone de la BDD ignorée"
sudo -u "${CAPE_USER}" python3 utils/db_migration.py 2>/dev/null || \
    log "Note: Migration BDD ignorée (peut être normale au premier démarrage)"

# ── 7. Démarrage des services CAPE via systemd ────────────────
log "Démarrage des services CAPE..."

# Activer et démarrer cape-rooter (requis pour les règles réseau)
if systemctl is-enabled cape-rooter.service > /dev/null 2>&1; then
    systemctl restart cape-rooter.service
    log "cape-rooter.service démarré"
else
    log "Démarrage manuel de cape-rooter..."
    python3 "${CAPE_ROOT}/utils/rooter.py" &
    log "cape-rooter démarré en tâche de fond (PID: $!)"
fi

# Démarrer le processeur en tâche de fond (requis pour traiter les analyses)
log "Démarrage du processeur CAPE..."
python3 "${CAPE_ROOT}/utils/process.py" auto -p 2 &
log "Processeur CAPE démarré en tâche de fond (PID: $!)"

log "============================================================"
log "CAPE Sandbox est prêt et s'initialise au premier plan..."
log "Résultats stockés dans : /work/storage"
log "Logs disponibles dans  : /work/log"
log "============================================================"

# Démarrer le service principal CAPE au premier plan (permet de capturer tous les logs directement via Docker)
# Ne pas utiliser sudo pour préserver l'environnement Python global et l'accès à libvirt-python
exec python3 "${CAPE_ROOT}/cuckoo.py"
