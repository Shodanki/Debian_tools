# Debian_tools

Setup scripts for Debian 12 (bookworm) / 13 (trixie) servers.

## debian-gpu-setup.sh — unified server + NVIDIA GPU setup (main tool)

One interactive tool that merges base server provisioning, Docker, web UIs,
hardening and NVIDIA GPU support (driver + container toolkit) into a single
module-based installer.

### Requirements

- Debian 12/13, minimal install
- root (`su -` or `sudo bash debian-gpu-setup.sh`)
- internet connectivity
- for the NVIDIA modules: an NVIDIA GPU detectable via `lspci`

### Usage

```bash
bash debian-gpu-setup.sh                 # interactive menu (whiptail, text fallback)
bash debian-gpu-setup.sh --status        # system + GPU status and installability check
bash debian-gpu-setup.sh --list-modules  # list all modules
bash debian-gpu-setup.sh --install core,net,docker,nv-toolkit   # non-interactive
bash debian-gpu-setup.sh --gpu           # NVIDIA quick setup (driver, toolkit, test)
bash debian-gpu-setup.sh --install ... --yes   # skip confirmation prompt
bash debian-gpu-setup.sh --help
```

Log file: `/var/log/debian-gpu-setup.log`. The script can install itself as
`/usr/local/sbin/debian-gpu-setup` (module `self`).

### NVIDIA GPU detection & installability

On start the tool scans `lspci` for NVIDIA / 3D controller devices, checks
`nvidia-smi`, the loaded kernel modules and nouveau, and recommends a driver
(PCI-ID mapping, default `tesla-470` for Tesla/legacy GPUs, `nvidia-detect`
when available). `--status` prints whether a GPU installation is possible and,
if not, the exact reasons (not root, not Debian, no internet, no GPU found).

All `nv-*` modules are **gated on a detected GPU**: they are shown disabled in
the menu checklist and rejected on the CLI when no NVIDIA GPU is present.

### Modules

| Module | What it does |
|---|---|
| `upgrade` | `apt full-upgrade` |
| `core` | sudo, curl, git, vim, htop/btop, tmux, jq, openssh-server, ... |
| `net` | dig, ping, mtr, traceroute, nmap, tcpdump, whois, ... |
| `lvm` | lvm2, growpart, parted, gdisk, filesystem tools |
| `dev` | python3, pip, venv, pipx, build-essential + common `-dev` libs |
| `osint` | exiftool, poppler-utils, parallel, dos2unix |
| `anon` | tor, torsocks, proxychains4 |
| `sudo` | admin user in sudo group + SSH key import |
| `docker` | Docker CE + Compose + Buildx (official repo), log rotation, verify |
| `nv-driver` | NVIDIA driver (auto-detected), nouveau blacklist, optional NVENC/CUDA utils — needs GPU |
| `nv-persist` | NVIDIA persistence daemon (systemd unit) — needs GPU |
| `nv-toolkit` | NVIDIA Container Toolkit + `nvidia` runtime merged into `/etc/docker/daemon.json` — needs GPU + docker |
| `nv-cuda` | CUDA toolkit on the host (optional) — needs GPU |
| `nv-test` | validation: `nvidia-smi`, kernel module, `/dev/nvidia0`, `docker run --gpus all ... nvidia-smi` — needs GPU |
| `cockpit` | Cockpit web admin, `https://<host>:9090` |
| `portainer` / `dockge` / `dozzle` | Docker web UI on `:9443` / `:5001` / `:8888` — **exactly one**, needs docker |
| `ufw` | firewall: deny incoming, allow SSH + Cockpit |
| `ufwdocker` | UFW filtering for Docker-published ports |
| `fail2ban` | SSH brute-force protection |
| `ssh` | hardening drop-in: no root login, key-only auth |
| `sysctl` | kernel/network sysctl hardening |
| `autoupd` | unattended security updates |
| `apparmor` | AppArmor |
| `self` | install the script as the `debian-gpu-setup` command |

Dependencies are added automatically (e.g. `nv-toolkit` pulls in `docker` and
`nv-driver`; web UIs pull in `docker`). Re-running an installed module updates
or reconfigures it. A PASS/FAIL summary is printed at the end.

### Presets

- **full** — base + docker + portainer + hardening
- **docker** — Docker host
- **gpu** — base + docker + all NVIDIA modules + portainer (needs a detected GPU)
- **harden** — hardening only

### Reboot

After installing `nv-driver` a reboot is recommended (menu entry available).

## Legacy scripts (superseded by debian-gpu-setup.sh)

- `install_nvidia_tesla.sh` — old standalone Tesla 470 driver installer
  (now the `nv-driver` module)
- `install_nvidia_test_option.sh` — glxgears / vulkaninfo benchmark snippet
  (now covered by `nv-test`)

---

*Provided "as is" without warranty of any kind. Review the script before
running it on production systems and keep a backup / recovery option.*
