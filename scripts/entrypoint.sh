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
chmod 2775 "${WORK}/storage" 2>/dev/null || true
chmod 2775 "${WORK}/storage/analyses" 2>/dev/null || true
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

# User accounts persistence (siteauth.sqlite stored in /work)
log "Setting up user account persistence..."
if [ ! -f "${WORK}/siteauth.sqlite" ]; then
    cp "${CAPE_ROOT}/web/siteauth.sqlite" "${WORK}/siteauth.sqlite" 2>/dev/null || true
    cd "${CAPE_ROOT}/web"
    python3 manage.py migrate --run-syncdb 2>/dev/null || true
    # Create break-glass admin account (change password after first login)
    DJANGO_SUPERUSER_PASSWORD="${CAPE_ADMIN_PASSWORD:-CapeAdmin2026!}" \
      python3 manage.py createsuperuser --noinput \
        --username "${CAPE_ADMIN_USER:-admin}" \
        --email "${CAPE_ADMIN_EMAIL:-admin@cape.local}" 2>/dev/null || true
    log "Admin account created: ${CAPE_ADMIN_USER:-admin}"
    cd "${CAPE_ROOT}"
fi
ln -sf "${WORK}/siteauth.sqlite" "${CAPE_ROOT}/web/siteauth.sqlite"
chown ${CAPE_USER}:${CAPE_USER} "${WORK}/siteauth.sqlite" 2>/dev/null || true
chmod 666 "${WORK}/siteauth.sqlite" 2>/dev/null || true
log "User account persistence: OK"

# Install additional Python dependencies
log "Installing additional Python dependencies..."
pip3 install "ImageHash>=4.3.1" --quiet --break-system-packages 2>/dev/null || true

# Volatility3 symbols and patches
log "Setting up Volatility3..."
VOL_SYMBOLS=$(python3 -c "import volatility3; print(volatility3.__file__.replace('__init__.py', 'symbols/'))" 2>/dev/null)
if [ -n "$VOL_SYMBOLS" ]; then
    # Download Windows symbols if not present
    if [ ! -d "${VOL_SYMBOLS}/windows/ntkrnlmp.pdb" ]; then
        log "Downloading Volatility3 Windows symbols..."
        cd ${VOL_SYMBOLS}
        wget -q https://downloads.volatilityfoundation.org/volatility3/symbols/windows.zip -O /tmp/vol3_windows.zip 2>/dev/null
        if [ -f /tmp/vol3_windows.zip ]; then
            mkdir -p windows
            cd windows && unzip -o -q /tmp/vol3_windows.zip 2>/dev/null
            # Fix nested directory structure (windows/windows/ -> windows/)
            if [ -d "windows" ]; then
                cp -r windows/* . 2>/dev/null
                rm -rf windows
            fi
            rm -f /tmp/vol3_windows.zip
            log "Volatility3 Windows symbols installed: OK"
        else
            log "WARNING: Failed to download Volatility3 symbols"
        fi
        cd ${CAPE_ROOT}
    else
        log "Volatility3 Windows symbols already present: OK"
    fi
fi

# Patch Volatility3 BitField compatibility with MongoDB
if ! grep -q "Vol3Encoder" "${CAPE_ROOT}/modules/reporting/report_doc.py" 2>/dev/null; then
    log "Applying Volatility3 BitField patch..."
    python3 << 'PATCH_EOF'
filepath = "/opt/CAPEv2/modules/reporting/report_doc.py"
with open(filepath, "r") as f:
    content = f.read()
old = '                    del report["memory"]\n\n    # Deeper copy for behavior processes'
new = """                    del report["memory"]

    # Sanitize Volatility3 objects (BitField, etc.) that MongoDB cannot serialize
    if "memory" in report:
        import json
        class Vol3Encoder(json.JSONEncoder):
            def default(self, obj):
                try:
                    return int(obj)
                except (TypeError, ValueError):
                    try:
                        return str(obj)
                    except Exception:
                        return repr(obj)
        try:
            report["memory"] = json.loads(json.dumps(report["memory"], cls=Vol3Encoder))
        except Exception as e:
            log.warning("Failed to sanitize memory section: %s", e)

    # Deeper copy for behavior processes"""
if old in content:
    content = content.replace(old, new)
    with open(filepath, "w") as f:
        f.write(content)
    print("BitField patch applied")
else:
    print("BitField patch target not found or already applied")
PATCH_EOF
    log "Volatility3 BitField patch: OK"
else
    log "Volatility3 BitField patch already applied: OK"
fi

# Start Daphne WebSocket server for Guacamole
log "Starting Daphne WebSocket server for Guacamole..."
cd "${CAPE_ROOT}/web"
python3 -m daphne -b 0.0.0.0 -p 8008 web.asgi:application &
log "Daphne started on port 8008 (PID: $!)"
cd "${CAPE_ROOT}"

# Fix permissions for analysis deletion from web UI using POSIX ACLs
log "Setting up POSIX ACLs for storage permissions..."
setfacl -R -m u:cape:rwX "${WORK}/storage" 2>/dev/null || true
setfacl -R -d -m u:cape:rwX "${WORK}/storage" 2>/dev/null || true

# Background ACL fix for analysis deletion from web UI
log "Starting background ACL fix for storage permissions..."
(while true; do
    setfacl -R -m u:cape:rwX,m::rwX "${WORK}/storage/analyses/" 2>/dev/null
    sleep 30
done) &

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