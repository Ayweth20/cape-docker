#!/usr/bin/env python3
"""
configure-cape.py — Configuration automatique de CAPEv2 depuis les variables d'env
Génère les fichiers de configuration CAPE à partir des templates.
"""

import os
import configparser
import shutil
from pathlib import Path

CAPE_ROOT = os.environ.get("CAPE_ROOT", "/opt/CAPEv2")
WORK = "/work"
CONF_DIR = Path(CAPE_ROOT) / "conf"

def log(msg):
    print(f"[configure-cape] {msg}")


def load_conf(filename):
    """Charge un fichier de config INI avec préservation des commentaires."""
    config = configparser.RawConfigParser()
    config.optionxform = str  # Préserver la casse
    conf_path = CONF_DIR / filename
    if conf_path.exists():
        config.read(conf_path)
    return config, conf_path


def save_conf(config, path):
    """Sauvegarde un fichier de config INI."""
    with open(path, "w") as f:
        config.write(f)
    log(f"  → Écrit : {path}")


# ── Configuration cuckoo.conf ─────────────────────────────────
def configure_cuckoo():
    log("Configuration de cuckoo.conf...")
    config, path = load_conf("cuckoo.conf")

    if not config.has_section("cuckoo"):
        config.add_section("cuckoo")

    # Moteur de virtualisation
    config.set("cuckoo", "machinery", "kvm")

    # Adresse du Result Server (IP du bridge KVM vu par les VMs)
    resultserver_ip = os.environ.get("CAPE_RESULTSERVER_IP", "192.168.122.1")
    if not config.has_section("resultserver"):
        config.add_section("resultserver")
    config.set("resultserver", "ip", resultserver_ip)
    config.set("resultserver", "port", "2042")

    # Base de données PostgreSQL
    pg_user = os.environ.get("POSTGRES_USER", "cape")
    pg_pass = os.environ.get("POSTGRES_PASSWORD", "SuperPuperSecret")
    pg_host = os.environ.get("POSTGRES_HOST", "postgresql")
    pg_port = os.environ.get("POSTGRES_PORT", "5432")
    pg_db = os.environ.get("POSTGRES_DB", "cape")
    db_url = f"postgresql+psycopg2://{pg_user}:{pg_pass}@{pg_host}:{pg_port}/{pg_db}"

    if not config.has_section("database"):
        config.add_section("database")
    config.set("database", "connection", db_url)

    save_conf(config, path)


# ── Configuration kvm.conf ────────────────────────────────────
def configure_kvm():
    log("Configuration de kvm.conf...")
    config, path = load_conf("kvm.conf")

    if not config.has_section("kvm"):
        config.add_section("kvm")

    # DSN libvirt
    dsn = os.environ.get("KVM_DSN", "qemu:///system")
    config.set("kvm", "dsn", dsn)
    config.set("kvm", "interface", os.environ.get("CAPE_NETWORK_IFACE", "virbr1"))

    # Définir dynamiquement les machines actives
    vm1_label = os.environ.get("VM1_LABEL", "win10")
    machines = [vm1_label]
    for i in range(2, 10):
        vm_label = os.environ.get(f"VM{i}_LABEL", "")
        if not vm_label:
            break
        machines.append(vm_label)
    config.set("kvm", "machines", ",".join(machines))

    # Nettoyer les anciennes sections de machines obsolètes (comme cuckoo1 du template)
    for section in list(config.sections()):
        if section != "kvm" and section not in machines:
            config.remove_section(section)
            log(f"  → Supprime la section obsolète : {section}")

    # VM 1 (peut être étendu pour plusieurs VMs)
    if not config.has_section(vm1_label):
        config.add_section(vm1_label)

    config.set(vm1_label, "label", vm1_label)
    config.set(vm1_label, "platform", os.environ.get("VM1_PLATFORM", "windows"))
    config.set(vm1_label, "ip", os.environ.get("VM1_IP", "192.168.122.105"))
    config.set(vm1_label, "arch", os.environ.get("VM1_ARCH", "x64"))
    config.set(vm1_label, "tags", os.environ.get("VM1_TAGS", "win10"))

    snapshot = os.environ.get("VM1_SNAPSHOT", "")
    if snapshot:
        config.set(vm1_label, "snapshot", snapshot)

    interface = os.environ.get("CAPE_NETWORK_IFACE", "virbr1")
    config.set(vm1_label, "interface", interface)

    # Support multi-VMs (VM2 à VM9)
    for i in range(2, 10):
        vm_label = os.environ.get(f"VM{i}_LABEL", "")
        if not vm_label:
            break
        if not config.has_section(vm_label):
            config.add_section(vm_label)
        config.set(vm_label, "label", vm_label)
        config.set(vm_label, "platform", os.environ.get(f"VM{i}_PLATFORM", "windows"))
        config.set(vm_label, "ip", os.environ.get(f"VM{i}_IP", ""))
        config.set(vm_label, "arch", os.environ.get(f"VM{i}_ARCH", "x64"))
        config.set(vm_label, "tags", os.environ.get(f"VM{i}_TAGS", "win10"))
        vm_snapshot = os.environ.get(f"VM{i}_SNAPSHOT", "")
        if vm_snapshot:
            config.set(vm_label, "snapshot", vm_snapshot)
        log(f"  VM{i} ({vm_label}) ajoutée à la configuration KVM")

    save_conf(config, path)


# ── Configuration reporting.conf ──────────────────────────────
def configure_reporting():
    log("Configuration de reporting.conf...")
    config, path = load_conf("reporting.conf")

    # MongoDB pour les résultats
    if not config.has_section("mongodb"):
        config.add_section("mongodb")
    config.set("mongodb", "enabled", "yes")
    config.set("mongodb", "host", os.environ.get("MONGO_HOST", "mongodb"))
    config.set("mongodb", "port", os.environ.get("MONGO_PORT", "27017"))
    config.set("mongodb", "db", os.environ.get("MONGO_DB", "cape"))

    # JSON dump activé par défaut
    if not config.has_section("jsondump"):
        config.add_section("jsondump")
    config.set("jsondump", "enabled", "yes")
    config.set("jsondump", "indent", "4")

    save_conf(config, path)


# ── Configuration web.conf ────────────────────────────────────
def configure_web():
    log("Configuration de web.conf...")
    config, path = load_conf("web.conf")

    if not config.has_section("web"):
        config.add_section("web")

    # MongoDB (pour la recherche dans l'UI)
    mongo_host = os.environ.get("MONGO_HOST", "mongodb")
    mongo_port = os.environ.get("MONGO_PORT", "27017")
    mongo_db = os.environ.get("MONGO_DB", "cape")

    if not config.has_section("mongodb"):
        config.add_section("mongodb")
    config.set("mongodb", "enabled", "yes")
    config.set("mongodb", "host", mongo_host)
    config.set("mongodb", "port", mongo_port)
    config.set("mongodb", "db", mongo_db)

    save_conf(config, path)


# ── Configuration auxiliary.conf ─────────────────────────────
def configure_auxiliary():
    log("Configuration de auxiliary.conf...")
    config, path = load_conf("auxiliary.conf")

    # Interface réseau pour tcpdump
    if not config.has_section("sniffer"):
        config.add_section("sniffer")
    config.set("sniffer", "enabled", "yes")
    config.set("sniffer", "interface", os.environ.get("CAPE_NETWORK_IFACE", "virbr1"))

    save_conf(config, path)


if __name__ == "__main__":
    log("=== Démarrage de la configuration automatique CAPE ===")

    # S'assurer que le répertoire conf existe
    CONF_DIR.mkdir(parents=True, exist_ok=True)

    # Copier les configs par défaut si absentes
    default_dir = CONF_DIR / "default"
    if default_dir.exists():
        for default_file in default_dir.glob("*.default"):
            target = CONF_DIR / default_file.stem
            if not target.exists():
                shutil.copy(default_file, target)
                log(f"Copie du template : {default_file.name} → {target.name}")

    configure_cuckoo()
    # configure_kvm()  # Désactivé pour permettre la gestion 100% manuelle des VMs dans kvm.conf
    configure_reporting()
    configure_web()
    configure_auxiliary()

    log("=== Configuration CAPE terminée ===")
