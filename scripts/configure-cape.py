#!/usr/bin/env python3
"""
configure-cape.py -- Automatic CAPEv2 configuration from environment variables.
Generates CAPE configuration files based on env vars.
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
    """Load an INI config file with case preservation."""
    config = configparser.RawConfigParser()
    config.optionxform = str  # Preserve case
    conf_path = CONF_DIR / filename
    if conf_path.exists():
        config.read(conf_path)
    return config, conf_path


def save_conf(config, path):
    """Save an INI config file."""
    with open(path, "w") as f:
        config.write(f)
    log(f"  Written: {path}")


# -- cuckoo.conf --
def configure_cuckoo():
    log("Configuring cuckoo.conf...")
    config, path = load_conf("cuckoo.conf")

    if not config.has_section("cuckoo"):
        config.add_section("cuckoo")

    # Virtualization engine and shared temp directory
    config.set("cuckoo", "machinery", "kvm")
    config.set("cuckoo", "tmppath", "/work/tmp")

    # ResultServer address (KVM bridge IP as seen by VMs)
    resultserver_ip = os.environ.get("CAPE_RESULTSERVER_IP", "192.168.122.1")
    if not config.has_section("resultserver"):
        config.add_section("resultserver")
    config.set("resultserver", "ip", resultserver_ip)
    config.set("resultserver", "port", "2042")

    # PostgreSQL database
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


# -- kvm.conf --
def configure_kvm():
    log("Configuring kvm.conf...")
    config, path = load_conf("kvm.conf")

    if not config.has_section("kvm"):
        config.add_section("kvm")

    # Libvirt DSN
    dsn = os.environ.get("KVM_DSN", "qemu:///system")
    config.set("kvm", "dsn", dsn)
    config.set("kvm", "interface", os.environ.get("CAPE_NETWORK_IFACE", "virbr1"))

    # Dynamically define active machines
    vm1_label = os.environ.get("VM1_LABEL", "win10")
    machines = [vm1_label]
    for i in range(2, 10):
        vm_label = os.environ.get(f"VM{i}_LABEL", "")
        if not vm_label:
            break
        machines.append(vm_label)
    config.set("kvm", "machines", ",".join(machines))

    # Remove stale machine sections (e.g. cuckoo1 from the default template)
    for section in list(config.sections()):
        if section != "kvm" and section not in machines:
            config.remove_section(section)
            log(f"  Removed stale section: {section}")

    # VM 1 (can be extended for multiple VMs)
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

    # Multi-VM support (VM2 through VM9)
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
        log(f"  VM{i} ({vm_label}) added to KVM configuration")

    save_conf(config, path)


# -- reporting.conf --
def configure_reporting():
    log("Configuring reporting.conf...")
    config, path = load_conf("reporting.conf")

    # MongoDB for results
    if not config.has_section("mongodb"):
        config.add_section("mongodb")
    config.set("mongodb", "enabled", "yes")
    config.set("mongodb", "host", os.environ.get("MONGO_HOST", "mongodb"))
    config.set("mongodb", "port", os.environ.get("MONGO_PORT", "27017"))
    config.set("mongodb", "db", os.environ.get("MONGO_DB", "cape"))

    # JSON dump enabled by default
    if not config.has_section("jsondump"):
        config.add_section("jsondump")
    config.set("jsondump", "enabled", "yes")
    config.set("jsondump", "indent", "4")

    save_conf(config, path)


# -- web.conf --
def configure_web():
    log("Configuring web.conf...")
    config, path = load_conf("web.conf")

    if not config.has_section("web"):
        config.add_section("web")

    # MongoDB (for search in the UI)
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


# -- auxiliary.conf --
def configure_auxiliary():
    log("Configuring auxiliary.conf...")
    config, path = load_conf("auxiliary.conf")

    # Network interface for tcpdump
    if not config.has_section("sniffer"):
        config.add_section("sniffer")
    config.set("sniffer", "enabled", "yes")
    config.set("sniffer", "interface", os.environ.get("CAPE_NETWORK_IFACE", "virbr1"))

    save_conf(config, path)


if __name__ == "__main__":
    log("=== Starting automatic CAPE configuration ===")

    # Ensure the conf directory exists
    CONF_DIR.mkdir(parents=True, exist_ok=True)

    # Copy default configs if missing
    default_dir = CONF_DIR / "default"
    if default_dir.exists():
        for default_file in default_dir.glob("*.default"):
            target = CONF_DIR / default_file.stem
            if not target.exists():
                shutil.copy(default_file, target)
                log(f"Copied template: {default_file.name} -> {target.name}")

    configure_cuckoo()
    # configure_kvm()  # Disabled to allow fully manual VM management in kvm.conf
    configure_reporting()
    configure_web()
    configure_auxiliary()

    log("=== CAPE configuration complete ===")
