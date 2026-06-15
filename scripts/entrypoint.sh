#!/bin/bash
# ============================================================
# entrypoint.sh -- CAPE Sandbox container entrypoint
# Based on celyrin/cape-docker, adapted for KVM/libvirt
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

# -- 1. Verify libvirt socket --
log "Checking libvirt socket..."
LIBVIRT_SOCK="/var/run/libvirt/libvirt-sock"
if [ ! -S "$LIBVIRT_SOCK" ]; then
    log "ERROR: Libvirt socket not found: $LIBVIRT_SOCK"
    log "Make sure libvirtd is running on the host and the socket volume is mounted."
    exit 1
fi
log "Libvirt socket found: OK"

# Test libvirt connectivity
if ! virsh -c qemu:///system list --all > /dev/null 2>&1; then
    log "WARNING: Unable to connect to libvirt. Check socket permissions."
fi

# -- 2. Wait for PostgreSQL --
log "Waiting for PostgreSQL on ${POSTGRES_HOST}:${POSTGRES_PORT}..."
MAX_RETRIES=30
RETRIES=0
until PGPASSWORD="${POSTGRES_PASSWORD}" pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" > /dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [ $RETRIES -ge $MAX_RETRIES ]; then
        log "ERROR: PostgreSQL unavailable after ${MAX_RETRIES} attempts."
        exit 1
    fi
    log "PostgreSQL not ready, retrying in 5s... ($RETRIES/$MAX_RETRIES)"
    sleep 5
done
log "PostgreSQL ready: OK"

# Ensure the role and database exist
PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -U "${POSTGRES_USER}" -d postgres -c "SELECT 1" > /dev/null 2>&1 || true

# -- 3. Verify working directory --
log "Checking working directory: $WORK"
if [ ! -d "$WORK" ]; then
    log "ERROR: /work directory not found. Check the Docker volume."
    exit 1
fi
chown -R "${CAPE_USER}:${CAPE_USER}" "$WORK"
mkdir -p "$WORK/tmp"
chown -R cape:cape "$WORK/tmp"
chmod 775 "$WORK/tmp"

# -- 4. Manage CAPE configuration (symlinks to /work) --
# Based on the celyrin/cape-docker approach:
# conf, storage, log are stored in /work and symlinked back

for dir in conf storage log; do
    SRC="${CAPE_ROOT}/${dir}"
    DST="${WORK}/${dir}"

    if [ -L "${SRC}" ]; then
        log "CAPEv2 ${dir} is already a symlink: OK"
    elif [ -d "${DST}" ]; then
        log "Existing ${dir} found in /work, linking..."
        rm -rf "${SRC}"
        chown -R "${CAPE_USER}:${CAPE_USER}" "${DST}"
        ln -s "${DST}" "${SRC}"
    elif [ -d "${SRC}" ]; then
        log "Moving ${dir} to /work and creating symlink..."
        mv "${SRC}" "${DST}"
        ln -s "${DST}" "${SRC}"
        chown -R "${CAPE_USER}:${CAPE_USER}" "${DST}"
    else
        log "Creating ${dir} in /work..."
        sudo -u "${CAPE_USER}" mkdir -p "${DST}"
        ln -s "${DST}" "${SRC}"
    fi
done

# -- 5. Automatic configuration via Python script --
log "Configuring CAPE..."
python3 /configure-cape.py
chmod 666 "${WORK}/conf/kvm.conf" || true

# -- 6. Initialize CAPE database --
log "Initializing CAPE database..."
cd "${CAPE_ROOT}"
# Run schema creation synchronously to avoid race conditions between cuckoo and process
sudo -u "${CAPE_USER}" python3 -c "import sys; sys.path.append('${CAPE_ROOT}'); from lib.cuckoo.core.database import init_database; init_database()" || log "Note: Synchronous DB init/migration skipped"
sudo -u "${CAPE_USER}" python3 utils/db_migration.py 2>/dev/null || \
    log "Note: DB migration skipped (may be normal on first startup)"

# -- 7. Start CAPE services via systemd --
log "Starting CAPE services..."

# Enable and start cape-rooter (required for network rules)
if systemctl is-enabled cape-rooter.service > /dev/null 2>&1; then
    systemctl restart cape-rooter.service
    log "cape-rooter.service started"
else
    log "Starting cape-rooter manually..."
    python3 "${CAPE_ROOT}/utils/rooter.py" &
    log "cape-rooter started in background (PID: $!)"
fi

# Start the processor in the background (required to handle analysis results)
log "Starting CAPE processor..."
python3 "${CAPE_ROOT}/utils/process.py" auto -p 2 &
log "CAPE processor started in background (PID: $!)"

log "============================================================"
log "CAPE Sandbox is ready and starting in the foreground..."
log "Results stored in: /work/storage"
log "Logs available in: /work/log"
log "============================================================"

# Start the main CAPE service in the foreground (captures all logs via Docker)
# Do not use sudo to preserve the global Python environment and libvirt-python access
exec python3 "${CAPE_ROOT}/cuckoo.py"
