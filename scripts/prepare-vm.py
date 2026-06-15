#!/usr/bin/env python3
"""
prepare-vm.py -- Helper script for preparing a Windows VM for CAPE.
Generates setup instructions and checks the status of available KVM VMs.

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
    """List available KVM VMs."""
    print("\n=== Available KVM VMs ===")
    out, rc = run("virsh list --all")
    if rc != 0:
        print("[!] Unable to list VMs (is libvirt accessible?)")
        return
    print(out)


def list_networks():
    """List libvirt networks."""
    print("\n=== Libvirt Networks ===")
    out, rc = run("virsh net-list --all")
    if rc != 0:
        print("[!] Unable to list networks")
        return
    print(out)


def check_vm(vm_label):
    """Check a specific VM."""
    print(f"\n=== Checking VM '{vm_label}' ===")

    out, rc = run(f"virsh dominfo {vm_label}")
    if rc != 0:
        print(f"[x] VM '{vm_label}' not found in libvirt")
        return False

    print(out)

    # Check snapshots
    snap_out, snap_rc = run(f"virsh snapshot-list {vm_label}")
    print(f"\n--- Snapshots ---")
    print(snap_out if snap_rc == 0 else "No snapshots found")

    return True


def check_agent_connectivity(vm_ip, vm_label):
    """Test connectivity with the CAPE agent running in the VM."""
    print(f"\n=== Testing CAPE agent on {vm_ip} ===")

    # Ping
    _, rc = run(f"ping -c 1 -W 2 {vm_ip}")
    if rc == 0:
        print(f"[+] VM '{vm_label}' ({vm_ip}) responds to ping")
    else:
        print(f"[x] VM '{vm_label}' ({vm_ip}) does not respond to ping")
        print("    -> Is the VM running? Is virbr1 configured?")
        return

    # Test CAPE agent port (8000 by default)
    import socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        result = sock.connect_ex((vm_ip, 8000))
        sock.close()
        if result == 0:
            print(f"[+] CAPE agent accessible on {vm_ip}:8000")
        else:
            print(f"[x] CAPE agent not accessible on {vm_ip}:8000")
            print("    -> Is agent.py running inside the Windows VM?")
    except Exception as e:
        print(f"[!] Connection error: {e}")


def print_vm_setup_instructions():
    """Print Windows VM setup instructions."""
    print("""
================================================================
    Windows VM Preparation Guide for CAPE
================================================================

1. CREATE THE KVM VM
   ------------------
   virt-install \\
     --name win10 \\
     --ram 4096 \\
     --vcpus 2 \\
     --disk path=/var/lib/libvirt/images/win10.qcow2,size=60 \\
     --cdrom /path/to/Win10.iso \\
     --os-variant win10 \\
     --network network=cape-analysis \\
     --graphics vnc,listen=0.0.0.0 \\
     --noautoconsole

   Connect via VNC:
   virt-viewer --connect qemu:///system win10

2. CONFIGURE WINDOWS
   ------------------
   Inside the Windows VM:
   - Disable Windows Defender and Windows Update
   - Disable Windows Firewall
   - Set a static IP: 192.168.122.105 / 255.255.255.0
     Gateway: 192.168.122.1 / DNS: 8.8.8.8

3. INSTALL THE CAPE AGENT
   -----------------------
   - Copy agent/agent.py from the CAPEv2 repository
   - Install Python in the Windows VM
   - Set up autostart: copy agent.py to the Startup folder
     or create a Windows service

   To copy the agent via SCP (if SSH is available):
   scp /opt/CAPEv2/agent/agent.py user@192.168.122.105:C:\\\\Users\\\\Public\\\\agent.py

4. CREATE THE SNAPSHOT
   --------------------
   Shut down the Windows VM cleanly, then:

   virsh snapshot-create-as win10 cape-snapshot \\
     --description "CAPE analysis snapshot" \\
     --atomic

   Verify:
   virsh snapshot-list win10

5. CONFIGURE .env
   ----------------
   Edit the .env file:
   VM1_LABEL=win10
   VM1_IP=192.168.122.105
   VM1_SNAPSHOT=cape-snapshot
   VM1_PLATFORM=windows
   VM1_ARCH=x64
   VM1_TAGS=win10

6. START CAPE
   -----------
   docker-compose up -d
   docker-compose logs -f cape-sandbox

================================================================
""")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Helper for preparing VMs for CAPE")
    parser.add_argument("--list", action="store_true", help="List KVM VMs and networks")
    parser.add_argument("--check", metavar="VM_LABEL", help="Check a specific VM")
    parser.add_argument("--test-agent", nargs=2, metavar=("VM_LABEL", "VM_IP"),
                        help="Test CAPE agent connectivity")
    parser.add_argument("--instructions", action="store_true", help="Show the setup guide")
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
        # No arguments: show everything
        list_vms()
        list_networks()
        print_vm_setup_instructions()
