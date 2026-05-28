#!/usr/bin/env python3
"""
prepare-vm.py — Script d'aide pour préparer une VM Windows pour CAPE
Génère les instructions et vérifie l'état des VMs KVM disponibles.

Usage: python3 prepare-vm.py [--check] [--list]
"""

import subprocess
import sys
import os
import argparse

def run(cmd, capture=True):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=capture, text=True)
        return result.stdout.strip(), result.returncode
    except Exception as e:
        return str(e), 1


def list_vms():
    """Lister les VMs KVM disponibles."""
    print("\n=== VMs KVM disponibles ===")
    out, rc = run("virsh list --all")
    if rc != 0:
        print("⚠  Impossible de lister les VMs (libvirt accessible ?)")
        return
    print(out)


def list_networks():
    """Lister les réseaux libvirt."""
    print("\n=== Réseaux libvirt ===")
    out, rc = run("virsh net-list --all")
    if rc != 0:
        print("⚠  Impossible de lister les réseaux")
        return
    print(out)


def check_vm(vm_label):
    """Vérifier une VM spécifique."""
    print(f"\n=== Vérification de la VM '{vm_label}' ===")

    out, rc = run(f"virsh dominfo {vm_label}")
    if rc != 0:
        print(f"✗ VM '{vm_label}' non trouvée dans libvirt")
        return False

    print(out)

    # Vérifier les snapshots
    snap_out, snap_rc = run(f"virsh snapshot-list {vm_label}")
    print(f"\n--- Snapshots ---")
    print(snap_out if snap_rc == 0 else "Aucun snapshot trouvé")

    return True


def check_agent_connectivity(vm_ip, vm_label):
    """Tester la connectivité avec l'agent CAPE dans la VM."""
    print(f"\n=== Test agent CAPE sur {vm_ip} ===")

    # Ping
    _, rc = run(f"ping -c 1 -W 2 {vm_ip}")
    if rc == 0:
        print(f"✓ VM '{vm_label}' ({vm_ip}) répond au ping")
    else:
        print(f"✗ VM '{vm_label}' ({vm_ip}) ne répond pas au ping")
        print("  → VM démarrée ? Réseau virbr1 configuré ?")
        return

    # Test port agent CAPE (8000 par défaut)
    import socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        result = sock.connect_ex((vm_ip, 8000))
        sock.close()
        if result == 0:
            print(f"✓ Agent CAPE accessible sur {vm_ip}:8000")
        else:
            print(f"✗ Agent CAPE non accessible sur {vm_ip}:8000")
            print("  → agent.py démarré dans la VM Windows ?")
    except Exception as e:
        print(f"⚠  Erreur de connexion : {e}")


def print_vm_setup_instructions():
    """Afficher les instructions de setup de la VM Windows."""
    print("""
╔══════════════════════════════════════════════════════════════╗
║         Guide de préparation de la VM Windows pour CAPE      ║
╠══════════════════════════════════════════════════════════════╣

1. CRÉER LA VM KVM
   ─────────────────
   virt-install \\
     --name win10 \\
     --ram 4096 \\
     --vcpus 2 \\
     --disk path=/var/lib/libvirt/images/win10.qcow2,size=60 \\
     --cdrom /chemin/vers/Win10.iso \\
     --os-variant win10 \\
     --network network=cape-analysis \\
     --graphics vnc,listen=0.0.0.0 \\
     --noautoconsole

   Connectez-vous via VNC :
   virt-viewer --connect qemu:///system win10

2. CONFIGURATION WINDOWS
   ──────────────────────
   Dans la VM Windows :
   • Désactiver Windows Defender et Windows Update
   • Désactiver le pare-feu Windows
   • Configurer l'IP statique : 192.168.122.105 / 255.255.255.0
     Passerelle : 192.168.122.1 / DNS : 8.8.8.8

3. INSTALLER L'AGENT CAPE
   ─────────────────────────
   • Copier le fichier agent/agent.py depuis le dépôt CAPEv2
   • Installer Python dans la VM Windows
   • Créer un autostart : copier agent.py dans le dossier Startup
     ou créer un service Windows

   Pour copier l'agent via SCP (si SSH dispo) :
   scp /opt/CAPEv2/agent/agent.py user@192.168.122.105:C:\\\\Users\\\\Public\\\\agent.py

4. CRÉER LE SNAPSHOT
   ───────────────────
   Éteindre proprement la VM Windows, puis :
   
   virsh snapshot-create-as win10 cape-snapshot \\
     --description "CAPE analysis snapshot" \\
     --atomic

   Vérifier :
   virsh snapshot-list win10

5. CONFIGURER .env
   ─────────────────
   Éditez le fichier .env :
   VM1_LABEL=win10
   VM1_IP=192.168.122.105
   VM1_SNAPSHOT=cape-snapshot
   VM1_PLATFORM=windows
   VM1_ARCH=x64
   VM1_TAGS=win10

6. LANCER CAPE
   ────────────
   docker-compose up -d
   docker-compose logs -f cape-sandbox

╚══════════════════════════════════════════════════════════════╝
""")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Aide à la préparation des VMs pour CAPE")
    parser.add_argument("--list", action="store_true", help="Lister les VMs et réseaux KVM")
    parser.add_argument("--check", metavar="VM_LABEL", help="Vérifier une VM spécifique")
    parser.add_argument("--test-agent", nargs=2, metavar=("VM_LABEL", "VM_IP"),
                        help="Tester la connectivité de l'agent CAPE")
    parser.add_argument("--instructions", action="store_true", help="Afficher le guide de setup")
    args = parser.parse_args()

    if args.list:
        list_vms()
        list_networks()
    elif args.check:
        check_vm(args.check)
    elif args.test_agent:
        check_vm(args.test_agent[0])
        check_agent_connectivity(args.test_agent[1], args.test_agent[0])
    elif args.instructions:
        print_vm_setup_instructions()
    else:
        # Sans argument : tout afficher
        list_vms()
        list_networks()
        print_vm_setup_instructions()
