# CAPEv2 Docker 🦆

Déploiement de [CAPEv2](https://github.com/kevoreilly/CAPEv2) (Malware Configuration And Payload Extraction) avec Docker et **KVM/QEMU** comme hyperviseur.

> Inspiré de [celyrin/cape-docker](https://github.com/celyrin/cape-docker), modernisé avec KVM natif Linux, docker-compose multi-services et configuration automatique.

## Architecture

```
┌─────────────────────────────── Host Ubuntu 22.04/24.04 ──────────────────────────────────┐
│                                                                                            │
│  ┌──────────────────────────── docker-compose ────────────────────────────────┐           │
│  │                                                                             │           │
│  │  cape-sandbox  ←→  postgresql  ←→  mongodb  ←→  redis  ←→  cape-web  ←→ nginx        │
│  │      │                                                           │          │           │
│  │      │ (--net=host)                                      (port 8000)  (port 80)        │
│  └──────┼──────────────────────────────────────────────────────────────────────┘           │
│         │                                                                                  │
│         │ /var/run/libvirt/libvirt-sock (volume monté)                                    │
│         ↓                                                                                  │
│  ┌──────────────────────────── KVM/libvirt ───────────────────────────────────┐           │
│  │   VM Windows (win10) — réseau virbr1 (192.168.122.0/24)                   │           │
│  │   Agent CAPE dans la VM → envoie les résultats au Result Server            │           │
│  └────────────────────────────────────────────────────────────────────────────┘           │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Prérequis

- **OS Host** : Ubuntu 22.04 ou 24.04 LTS (bare-metal ou VM avec nested-virt activé)
- **Docker** + **docker-compose v2**
- **KVM/QEMU** + **libvirt** (installés par `setup-host.sh`)
- **Image Windows** (Win7 SP1, Win10, Win11) pour créer la VM d'analyse

## Démarrage rapide

### 1. Configurer le host (KVM + réseau)

```bash
cd cape-docker/
sudo bash setup-host.sh
```

Ce script installe KVM, libvirt, configure le réseau `virbr1` (192.168.122.0/24) et les permissions.

### 2. Configurer l'environnement

```bash
cp .env .env.local
nano .env  # Adaptez les paramètres à votre infrastructure
```

Variables importantes :
| Variable | Défaut | Description |
|---|---|---|
| `VM1_LABEL` | `win10` | Nom de la VM KVM |
| `VM1_IP` | `192.168.122.105` | IP de la VM d'analyse |
| `VM1_SNAPSHOT` | `cape-snapshot` | Nom du snapshot à restaurer |
| `POSTGRES_PASSWORD` | `SuperPuperSecret` | **À changer !** |
| `CAPE_RESULTSERVER_IP` | `192.168.122.1` | IP du résultserver vu par la VM |

### 3. Préparer la VM Windows

```bash
# Voir les instructions complètes
python3 scripts/prepare-vm.py --instructions

# Vérifier l'état des VMs KVM
python3 scripts/prepare-vm.py --list

# Après installation de la VM et de l'agent CAPE :
virsh snapshot-create-as win10 cape-snapshot --atomic
```

> **Important** : La VM Windows doit avoir l'[agent CAPE](https://github.com/kevoreilly/CAPEv2/blob/master/agent/agent.py) en autostart et une IP statique dans 192.168.122.0/24.

### 4. Démarrer CAPEv2

```bash
# Premier démarrage (build + lancement)
docker-compose up -d --build

# Voir les logs
docker-compose logs -f cape-sandbox
docker-compose logs -f cape-web

# Vérifier l'état
docker-compose ps
```

### 5. Accéder à l'interface

Ouvrez **http://localhost** (via Nginx) ou **http://localhost:8000** (direct).

---

## Structure du projet

```
cape-docker/
├── docker-compose.yml          # Orchestration des 5 services
├── .env                        # Variables de configuration (éditez ce fichier)
├── Dockerfile                  # Image sandbox principale (analyse + KVM)
├── Dockerfile.web              # Image interface web (Django + Gunicorn)
├── setup-host.sh               # Script de préparation du host (KVM, réseau)
├── .dockerignore
├── scripts/
│   ├── entrypoint.sh           # Démarrage du conteneur sandbox
│   ├── entrypoint-web.sh       # Démarrage de l'interface web
│   ├── configure-cape.py       # Configuration auto depuis les env vars
│   └── prepare-vm.py           # Aide à la préparation des VMs
├── nginx/
│   ├── cape.conf               # Configuration Nginx (reverse proxy)
│   └── ssl/                    # Certificats SSL (optionnel)
└── data/                       # Données persistantes (auto-créées)
    ├── cape/                   # Conf, storage, logs CAPE
    ├── postgresql/             # Données PostgreSQL
    └── mongodb/                # Données MongoDB
```

---

## Services Docker

| Service | Image | Port | Rôle |
|---|---|---|---|
| `cape-sandbox` | `cape-sandbox:latest` | — | Moteur d'analyse, communique avec KVM |
| `postgresql` | `postgres:16-alpine` | interne | Base de données des tâches |
| `mongodb` | `mongo:7.0` | interne | Stockage des résultats |
| `redis` | `redis:7-alpine` | interne | File de tâches |
| `cape-web` | `cape-web:latest` | `8000` | Interface Django |
| `nginx` | `nginx:1.27-alpine` | `80`, `443` | Reverse proxy |

---

## Différences avec celyrin/cape-docker (VirtualBox)

| | celyrin/cape-docker | Ce projet |
|---|---|---|
| **Hyperviseur** | VirtualBox | **KVM/QEMU** |
| **Bridge VM-Conteneur** | `vbox-server.go` + `vbox-client.go` | Socket libvirt natif |
| **Réseau** | `--net=host` + vbox.sock | `--net=host` + `/var/run/libvirt/libvirt-sock` |
| **Services** | Container monolithique | **Multi-services** (6 conteneurs) |
| **Config** | Manuelle | **Automatique** via variables d'env |
| **Architecture Go** | Requis (compiler) | **Non requis** |

---

## Commandes utiles

```bash
# Soumettre un sample pour analyse
docker-compose exec cape-sandbox python3 utils/submit.py /chemin/vers/malware.exe

# Voir les analyses en cours
docker-compose exec cape-sandbox python3 utils/process.py -r 1

# Accéder au shell du sandbox
docker-compose exec cape-sandbox bash

# Lister les VMs disponibles depuis le conteneur
docker-compose exec cape-sandbox virsh -c qemu:///system list --all

# Redémarrer un service spécifique
docker-compose restart cape-sandbox

# Mettre à jour CAPE
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

---

## Dépannage

### Le socket libvirt n'est pas trouvé
```bash
# Sur le host :
sudo systemctl start libvirtd
ls -la /var/run/libvirt/libvirt-sock
```

### La VM ne répond pas
```bash
# Vérifier que la VM est démarrée
virsh list --all
virsh start win10

# Vérifier la connectivité réseau
ping 192.168.122.105
```

### L'agent CAPE n'est pas joignable
```bash
# Depuis le host, tester le port 8000 de la VM
telnet 192.168.122.105 8000
python3 scripts/prepare-vm.py --test-agent win10 192.168.122.105
```

### Problèmes de permissions libvirt
```bash
# Ajouter l'utilisateur au groupe libvirt
sudo usermod -aG libvirt $USER
newgrp libvirt
```

---

## Sécurité

> ⚠️ **Ce déploiement est prévu pour un usage en sandbox isolé.**

- Changez `POSTGRES_PASSWORD` et `CAPE_SECRET_KEY` dans `.env`
- En production : mettez en place HTTPS (voir `nginx/cape.conf`)
- Considérez d'isoler le réseau d'analyse (désactiver NAT dans `setup-host.sh`)
- Ne jamais exposer l'interface CAPE directement sur Internet sans authentification

---

## Références

- [CAPEv2 Documentation](https://capev2.readthedocs.io/)
- [kevoreilly/CAPEv2](https://github.com/kevoreilly/CAPEv2)
- [celyrin/cape-docker](https://github.com/celyrin/cape-docker) (inspiration)
- [cape2.sh installer](https://github.com/kevoreilly/CAPEv2/blob/master/installer/cape2.sh)
