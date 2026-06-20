# ============================================================
# Dockerfile -- CAPE Sandbox (analysis engine)
# Base: Ubuntu 22.04
# Inspired by celyrin/cape-docker + official cape2.sh installer
# ============================================================

FROM ubuntu:22.04

ARG CAPE_ROOT=/opt/CAPEv2
ARG DEBIAN_FRONTEND=noninteractive
ARG CAPE_USER=cape

# -- Labels --
LABEL maintainer="CAPE Docker"
LABEL description="CAPEv2 Malware Sandbox - analysis engine with KVM/libvirt support"
LABEL version="2.0"

# -- Timezone --
RUN apt-get update && apt-get install -y tzdata && \
    ln -fs /usr/share/zoneinfo/UTC /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata

# -- System dependencies --
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
    # Network tools (traffic capture)
    tcpdump \
    libpcap-dev \
    iptables \
    # libvirt (KVM VM control from inside the container)
    libvirt-clients \
    libvirt-dev \
    acl \
    python3-libvirt \
    # Utilities
    git \
    curl \
    wget \
    unzip \
    p7zip-full \
    # CAPE dependencies
    libmagic-dev \
    libssl-dev \
    libffi-dev \
    libxml2-dev \
    libxslt1-dev \
    libjpeg-dev \
    zlib1g-dev \
    # PostgreSQL client
    postgresql-client \
    # Sudo for cape user
    sudo \
    # systemd (for CAPE services)
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

# -- Python alternatives --
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1 && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1

# -- Create cape user (non-root) --
RUN groupadd -r cape && \
    groupadd -f libvirt && \
    groupadd -f libvirt-qemu && \
    groupadd -f pcap && \
    useradd -r -g cape -G sudo,libvirt,libvirt-qemu,pcap -m -s /bin/bash cape && \
    echo "cape ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    # Allow tcpdump without root
    chgrp pcap /usr/bin/tcpdump && \
    chmod 750 /usr/bin/tcpdump && \
    setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump || true

# -- Clone CAPEv2 --
RUN git clone --depth=1 https://github.com/kevoreilly/CAPEv2.git ${CAPE_ROOT} && \
    chown -R cape:cape ${CAPE_ROOT} && \
    sed -i 's/cryptography>=.*/cryptography<46/g' ${CAPE_ROOT}/requirements.txt || true && \
    sed -i 's/cryptography==.*/cryptography<46/g' ${CAPE_ROOT}/requirements.txt || true && \
    sed -i 's/pyasn1==.*/pyasn1<0.6.0/g' ${CAPE_ROOT}/requirements.txt || true && \
    sed -i 's/pyopenssl>=.*/pyopenssl<26/g' ${CAPE_ROOT}/requirements.txt || true && \
    sed -i 's/pyopenssl==.*/pyopenssl<26/g' ${CAPE_ROOT}/requirements.txt || true

# -- Install CAPE Python dependencies --
WORKDIR ${CAPE_ROOT}

# Remove system-installed pycparser to avoid distutils uninstall errors
RUN apt-get remove -y python3-pycparser || true && \
    rm -rf /usr/lib/python3/dist-packages/pycparser* /usr/lib/python3/dist-packages/_pycparser* || true

# Install poetry (dependency manager recommended by CAPE)
RUN pip3 install --upgrade pip && \
    pip3 install poetry "cryptography<46" "cffi<2.0.0" "pyasn1<0.6.0" "pyopenssl<26"

# Install dependencies via poetry (recommended, locked, avoids conflicts)
# Falls back to pip if poetry fails
RUN poetry config virtualenvs.create false && \
    poetry install --no-root || \
    (pip3 install "cryptography<46" "cffi<2.0.0" "pyasn1<0.6.0" "pyopenssl<26" && pip3 install -r ${CAPE_ROOT}/requirements.txt)

# Install essential specific dependencies
RUN pip3 install \
    psycopg2-binary \
    pymongo \
    redis \
    celery \
    libvirt-python \
    requests \
    pefile \
    yara-python \
    oletools \
    volatility3 \
    orjson \
    gunicorn

# -- Configure directories --
RUN mkdir -p \
    ${CAPE_ROOT}/storage/analyses \
    ${CAPE_ROOT}/storage/binaries \
    ${CAPE_ROOT}/storage/baseline \
    ${CAPE_ROOT}/log \
    /work \
    /opt/vbox && \
    chown -R cape:cape ${CAPE_ROOT} /work /opt/vbox

# -- Copy default configurations --
RUN if [ -d "${CAPE_ROOT}/conf/default" ]; then \
        cp ${CAPE_ROOT}/conf/default/*.default ${CAPE_ROOT}/conf/ && \
        for f in ${CAPE_ROOT}/conf/*.default; do \
            mv "$f" "${f%.default}"; \
        done; \
    fi || true

# -- Copy entrypoint scripts --
COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/configure-cape.py /configure-cape.py
RUN chmod +x /entrypoint.sh /configure-cape.py

# -- Persistent data volume --
VOLUME ["/work"]

WORKDIR ${CAPE_ROOT}

ENTRYPOINT ["/entrypoint.sh"]