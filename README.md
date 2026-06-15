# CAPEv2 Docker

Deploy [CAPEv2](https://github.com/kevoreilly/CAPEv2) (Malware Configuration And Payload Extraction) using Docker with **KVM/QEMU** as the hypervisor.

Inspired by [celyrin/cape-docker](https://github.com/celyrin/cape-docker), reworked for native Linux KVM, multi-service orchestration, and environment-driven configuration.

## Overview

This project containerizes the CAPEv2 malware analysis sandbox while keeping KVM/libvirt on the host for VM management. The Docker stack handles all supporting services (database, web UI, task queue) and communicates with the host hypervisor through a mounted libvirt socket.

```
Host (Ubuntu 22.04/24.04)
|
|-- docker-compose
|   |-- cape-sandbox    (analysis engine, --net=host)
|   |-- cape-web        (Django UI, port 8000)
|   |-- postgresql      (task database)
|   |-- mongodb         (results storage)
|   +-- redis           (task queue)
|
+-- KVM/libvirt
    +-- Windows VM (virbr1, isolated network)
        +-- CAPE agent --> ResultServer (port 2042)
```

### Key differences from celyrin/cape-docker

| | celyrin/cape-docker | This project |
|---|---|---|
| Hypervisor | VirtualBox | KVM/QEMU |
| VM bridge | Custom Go binaries (`vbox-server`/`vbox-client`) | Native libvirt socket |
| Architecture | Monolithic container | Multi-service (5 containers) |
| Configuration | Manual | Automatic via `.env` |
| Go compiler | Required | Not required |

## Prerequisites

- Ubuntu 22.04 or 24.04 LTS (bare-metal or nested-virt capable VM)
- Docker Engine + docker-compose v2
- A Windows ISO (Win7 SP1 / Win10 / Win11)

KVM, QEMU, and libvirt are installed automatically by `setup-host.sh`.

## Quick Start

### 1. Prepare the host

```bash
sudo bash setup-host.sh
```

Installs KVM/libvirt, creates an isolated network on `virbr1`, and configures iptables rules.

### 2. Create your environment file

```bash
cp .env.example .env
```

Edit `.env` and set at minimum:

| Variable | Description |
|---|---|
| `POSTGRES_PASSWORD` | Database password |
| `CAPE_SECRET_KEY` | Django secret key |
| `CAPE_RESULTSERVER_IP` | Host bridge IP reachable by VMs |
| `VM1_LABEL` | libvirt VM name |
| `VM1_IP` | Static IP of the analysis VM |
| `VM1_SNAPSHOT` | Snapshot to restore before each analysis |

### 3. Prepare the Windows VM

```bash
# Interactive guide
python3 scripts/prepare-vm.py --instructions

# Verify KVM sees the VM
python3 scripts/prepare-vm.py --list

# Test agent connectivity
python3 scripts/prepare-vm.py --test-agent <vm-name> <vm-ip>
```

The VM must have:
- A static IP within your analysis subnet
- Windows Defender / Firewall disabled
- The [CAPE agent](https://github.com/kevoreilly/CAPEv2/blob/master/agent/agent.py) running at startup
- A clean snapshot created after setup

### 4. Build and start

```bash
docker-compose up -d --build
```

### 5. Access the web interface

```
http://<host-ip>:8000
```

## Project Structure

```
.
|-- docker-compose.yml        # Service orchestration
|-- .env.example              # Configuration template
|-- Dockerfile                # Sandbox image (analysis + KVM)
|-- Dockerfile.web            # Web UI image (Django + Gunicorn)
|-- setup-host.sh             # One-time host preparation
|-- scripts/
|   |-- entrypoint.sh         # Sandbox container init
|   |-- entrypoint-web.sh     # Web container init
|   |-- configure-cape.py     # Generates CAPE configs from env vars
|   +-- prepare-vm.py         # VM setup helper
|-- nginx/
|   +-- cape.conf             # Nginx reverse proxy config
+-- data/                     # Persistent volumes (gitignored)
```

## Usage

```bash
# Submit a sample
docker-compose exec cape-sandbox python3 utils/submit.py /path/to/sample.exe

# View logs
docker-compose logs -f cape-sandbox
docker-compose logs -f cape-web

# Access sandbox shell
docker-compose exec cape-sandbox bash

# List VMs from inside the container
docker-compose exec cape-sandbox virsh -c qemu:///system list --all

# Rebuild after changes
docker-compose down && docker-compose up -d --build
```

## Multi-VM Support

Additional VMs can be defined in `.env` using the `VM2_*` through `VM9_*` prefixes:

```bash
VM2_LABEL=win7sp1
VM2_IP=192.168.100.11
VM2_SNAPSHOT=clean
VM2_PLATFORM=windows
VM2_ARCH=x64
VM2_TAGS=win7
```

The configuration script picks them up automatically at container startup.

## Troubleshooting

| Problem | Solution |
|---|---|
| Libvirt socket not found | `sudo systemctl start libvirtd` on the host |
| VM not responding to ping | Check `virsh list --all` and `virsh start <vm>` |
| CAPE agent unreachable | Verify agent.py is running + firewall is off in the VM |
| Permission denied on libvirt | `sudo usermod -aG libvirt $USER && newgrp libvirt` |
| Database connection refused | Wait for healthchecks or check `docker-compose ps` |

## Security Considerations

- Change `POSTGRES_PASSWORD` and `CAPE_SECRET_KEY` before deploying.
- The analysis network is isolated by default (no NAT). VMs can only reach the ResultServer.
- Do not expose port 8000 to the Internet without authentication and TLS.
- Use the provided `nginx/cape.conf` or a reverse proxy like Traefik for production access.

## References

- [CAPEv2 Documentation](https://capev2.readthedocs.io/)
- [kevoreilly/CAPEv2](https://github.com/kevoreilly/CAPEv2)
- [celyrin/cape-docker](https://github.com/celyrin/cape-docker)
- [cape2.sh installer](https://github.com/kevoreilly/CAPEv2/blob/master/installer/cape2.sh)

## License

This project is provided as-is for research and educational purposes.
