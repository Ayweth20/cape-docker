#!/bin/bash
# ============================================================
# entrypoint-web.sh -- CAPE Web Interface entrypoint
# ============================================================
set -e

CAPE_ROOT="${CAPE_ROOT:-/opt/CAPEv2}"
POSTGRES_HOST="${POSTGRES_HOST:-postgresql}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-cape}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-SuperPuperSecret}"
POSTGRES_DB="${POSTGRES_DB:-cape}"
MONGO_HOST="${MONGO_HOST:-mongodb}"
MONGO_PORT="${MONGO_PORT:-27017}"
CAPE_WEB_PORT="${CAPE_WEB_PORT:-8000}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WEB] $*"; }

# -- 1. Wait for PostgreSQL --
log "Waiting for PostgreSQL on ${POSTGRES_HOST}:${POSTGRES_PORT}..."
MAX_RETRIES=30
RETRIES=0
until PGPASSWORD="${POSTGRES_PASSWORD}" pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" > /dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [ $RETRIES -ge $MAX_RETRIES ]; then
        log "ERROR: PostgreSQL unavailable."
        exit 1
    fi
    sleep 5
done
log "PostgreSQL ready: OK"

# -- 2. Wait for MongoDB --
log "Waiting for MongoDB on ${MONGO_HOST}:${MONGO_PORT}..."
RETRIES=0
until python3 -c "import pymongo; pymongo.MongoClient('${MONGO_HOST}', ${MONGO_PORT}).server_info()" > /dev/null 2>&1; do
    RETRIES=$((RETRIES + 1))
    if [ $RETRIES -ge 20 ]; then
        log "WARNING: MongoDB unavailable. The web interface may operate with limited functionality."
        break
    fi
    sleep 5
done

# -- 3. Symlink conf/storage from /work --
WORK="/work"
mkdir -p "$WORK/tmp"
chmod 777 "$WORK/tmp" || true
for dir in conf storage; do
    SRC="${CAPE_ROOT}/${dir}"
    DST="${WORK}/${dir}"
    if [ -d "${DST}" ] && [ ! -L "${SRC}" ]; then
        rm -rf "${SRC}"
        ln -s "${DST}" "${SRC}"
    fi
done

# -- 4. Django configuration --
log "Configuring web interface..."
cd "${CAPE_ROOT}/web"

# Create local settings file if it does not exist
if [ ! -f "${CAPE_ROOT}/web/web/local_settings.py" ]; then
    cat > "${CAPE_ROOT}/web/web/local_settings.py" << EOF
# Auto-generated local configuration
import os

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql_psycopg2",
        "NAME": "${POSTGRES_DB}",
        "USER": "${POSTGRES_USER}",
        "PASSWORD": "${POSTGRES_PASSWORD}",
        "HOST": "${POSTGRES_HOST}",
        "PORT": "${POSTGRES_PORT}",
    }
}

MONGO_URI = "mongodb://${MONGO_HOST}:${MONGO_PORT}"
SECRET_KEY = "${CAPE_SECRET_KEY:-$(python3 -c 'import secrets; print(secrets.token_hex(32))')}"
DEBUG = False
ALLOWED_HOSTS = ["*"]
EOF
fi

# -- 4.5 Inject WhiteNoise (static file serving) --
log "Injecting WhiteNoise for static file support..."
python3 -c "
settings_path = '${CAPE_ROOT}/web/web/settings.py'
with open(settings_path, 'r') as f:
    content = f.read()

if 'whitenoise.middleware.WhiteNoiseMiddleware' not in content:
    content = content.replace(
        '\"django.middleware.security.SecurityMiddleware\",',
        '\"django.middleware.security.SecurityMiddleware\",\n    \"whitenoise.middleware.WhiteNoiseMiddleware\",'
    ).replace(
        '\'django.middleware.security.SecurityMiddleware\',',
        '\'django.middleware.security.SecurityMiddleware\',\n    \'whitenoise.middleware.WhiteNoiseMiddleware\','
    )

if 'STATICFILES_STORAGE' not in content:
    content += '\nSTATICFILES_STORAGE = \"whitenoise.storage.CompressedStaticFilesStorage\"\n'

with open(settings_path, 'w') as f:
    f.write(content)
"

# Django migrations
log "Running Django migrations..."
python3 manage.py migrate --noinput 2>/dev/null || log "Migrations skipped"

# Collect static files
python3 manage.py collectstatic --noinput || log "collectstatic skipped"

# -- 5. Start Gunicorn --
log "Starting Gunicorn on port ${CAPE_WEB_PORT}..."
log "Web interface available at: http://0.0.0.0:${CAPE_WEB_PORT}"

exec gunicorn \
    --bind "0.0.0.0:${CAPE_WEB_PORT}" \
    --workers 3 \
    --timeout 300 \
    --access-logfile - \
    --error-logfile - \
    --log-level info \
    web.wsgi:application
