# ============================================================
# Dockerfile — CAPE Sandbox (moteur d'analyse)
# Base: Ubuntu 22.04
# Inspiré de celyrin/cape-docker + installateur officiel cape2.sh
# ============================================================

FROM ubuntu:22.04

ARG CAPE_ROOT=/opt/CAPEv2
ARG DEBIAN_FRONTEND=noninteractive
ARG CAPE_USER=cape

# ── Labels ────────────────────────────────────────────────────
LABEL maintainer="CAPE Docker"
LABEL description="CAPEv2 Malware Sandbox - moteur d'analyse avec support KVM/libvirt"
LABEL version="2.0"

# ── Timezone ──────────────────────────────────────────────────
RUN apt-get update && apt-get install -y tzdata && \
    ln -fs /usr/share/zoneinfo/UTC /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata

# ── Dépendances système ───────────────────────────────────────
RUN apt-get update && apt-get install -y \
    # Python
    python3.10 \
    python3.10-dev \
    python3-pip \
    python3-setuptools \
    python3-wheel \
    # Build tools
    gcc \
    g++ \
    make \
    cmake \
    # Outils réseau (capture trafic)
    tcpdump \
    libpcap-dev \
    # libvirt (contrôle VMs KVM depuis le conteneur)
    libvirt-clients \
    libvirt-dev \
    python3-libvirt \
    # Utilitaires
    git \
    curl \
    wget \
    unzip \
    p7zip-full \
    # Dépendances CAPE
    libmagic-dev \
    libssl-dev \
    libffi-dev \
    libxml2-dev \
    libxslt1-dev \
    libjpeg-dev \
    zlib1g-dev \
    # PostgreSQL client
    postgresql-client \
    # Sudo pour cape user
    sudo \
    # systemd (pour les services CAPE)
    systemd \
    systemd-sysv \
    # Monitoring
    procps \
    net-tools \
    iproute2 \
    # Yara
    yara \
    python3-yara \
    # ssdeep
    libfuzzy-dev \
    python3-ssdeep \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── Alternatives Python ────────────────────────────────────────
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1 && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1

# ── Utilisateur cape (non-root) ────────────────────────────────
RUN groupadd -r cape && \
    groupadd -f libvirt && \
    groupadd -f libvirt-qemu && \
    groupadd -f pcap && \
    useradd -r -g cape -G sudo,libvirt,libvirt-qemu,pcap -m -s /bin/bash cape && \
    echo "cape ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    # Autoriser tcpdump sans root
    chgrp pcap /usr/bin/tcpdump && \
    chmod 750 /usr/bin/tcpdump && \
    setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump || true

# ── Clonage CAPEv2 ────────────────────────────────────────────
RUN git clone --depth=1 https://github.com/kevoreilly/CAPEv2.git ${CAPE_ROOT} && \
    chown -R cape:cape ${CAPE_ROOT}

# ── Installation des dépendances Python CAPE ──────────────────
WORKDIR ${CAPE_ROOT}

# Installer poetry (gestionnaire de dépendances recommandé par CAPE)
RUN pip3 install --upgrade pip && \
    pip3 install poetry

# Installer les dépendances via poetry
RUN su -c "cd ${CAPE_ROOT} && poetry install --no-dev" cape 2>/dev/null || \
    pip3 install -r ${CAPE_ROOT}/requirements.txt

# Installer des dépendances spécifiques essentielles
RUN pip3 install \
    psycopg2-binary \
    pymongo \
    redis \
    celery \
    python-libvirt \
    requests \
    pefile \
    yara-python \
    oletools \
    volatility3 \
    orjson \
    gunicorn

# ── Configuration des répertoires ─────────────────────────────
RUN mkdir -p \
    ${CAPE_ROOT}/storage/analyses \
    ${CAPE_ROOT}/storage/binaries \
    ${CAPE_ROOT}/storage/baseline \
    ${CAPE_ROOT}/log \
    /work \
    /opt/vbox && \
    chown -R cape:cape ${CAPE_ROOT} /work /opt/vbox

# ── Copie des configurations par défaut ───────────────────────
RUN if [ -d "${CAPE_ROOT}/conf/default" ]; then \
        cp ${CAPE_ROOT}/conf/default/*.default ${CAPE_ROOT}/conf/ && \
        for f in ${CAPE_ROOT}/conf/*.default; do \
            mv "$f" "${f%.default}"; \
        done; \
    fi || true

# ── Copie des scripts d'entrée ────────────────────────────────
COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/configure-cape.py /configure-cape.py
RUN chmod +x /entrypoint.sh /configure-cape.py

# ── Volume pour les données persistantes ──────────────────────
VOLUME ["/work"]

WORKDIR ${CAPE_ROOT}

ENTRYPOINT ["/entrypoint.sh"]
