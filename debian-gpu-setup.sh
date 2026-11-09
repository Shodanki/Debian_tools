#!/usr/bin/env bash
# =============================================================================
#  debian-gpu-setup.sh - unified Debian server + NVIDIA GPU setup tool
# -----------------------------------------------------------------------------
#  Merges the functions of:
#    - debian-setup.sh        (base provisioning, hardening, Docker, web UIs)
#    - nvidia-docker-setup.sh (GPU detection, driver, container toolkit, tests)
#
#  Target : Debian 12 (bookworm) / 13 (trixie), minimal install, run as root
#  Usage  : bash debian-gpu-setup.sh            interactive menu
#           bash debian-gpu-setup.sh --status   system + GPU status only
#           bash debian-gpu-setup.sh --list-modules
#           bash debian-gpu-setup.sh --install core,net,docker,nv-toolkit
#  Log    : /var/log/debian-gpu-setup.log
#
#  NVIDIA modules (nv-*) are only selectable when an NVIDIA GPU is detected;
#  the status check reports whether a GPU installation is possible and why not.
# =============================================================================

set -o pipefail

SCRIPT_VERSION="1.0.0"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
INSTALL_PATH="/usr/local/sbin/debian-gpu-setup"
LOG_FILE="/var/log/debian-gpu-setup.log"
STACK_DIR="/opt/admin-stacks"
USER_STACKS_DIR="/opt/stacks"
SSH_DROPIN="/etc/ssh/sshd_config.d/10-debian-gpu-setup.conf"
NVIDIA_PERSISTENCE_SERVICE="/etc/systemd/system/nvidia-persistenced.service"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a

APT_OPTS=(-y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
APT_UPDATED=0
UI="text"
SUMMARY=()

# GPU detection results (filled by nv_detect_gpus / nv_identify_driver)
NV_GPU_COUNT=0
NV_GPU_NAMES=()
NV_PCI_IDS=""
NV_DRIVER="unknown"
NV_SMI_OK=0

# ---- colors -----------------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_BOLD=$'\e[1m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_BOLD=""; C_0=""
fi

# ---- output helpers ---------------------------------------------------------
log()     { if [[ -w $LOG_FILE || -w /var/log ]]; then printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null; fi; }
info()    { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; log "INFO  $*"; }
ok()      { printf '%s[OK]%s %s\n' "$C_G" "$C_0" "$*"; log "OK    $*"; }
warn()    { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; log "WARN  $*"; }
err()     { printf '%s[X]%s %s\n' "$C_R" "$C_0" "$*" >&2; log "ERROR $*"; }
die()     { err "$*"; exit 1; }
section() { printf '\n%s%s==> %s%s\n' "$C_BOLD" "$C_B" "$1" "$C_0"; log "===== $1"; }

run() {
  log "RUN   $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  (( rc == 0 )) || log "FAIL  (rc=$rc) $*"
  return "$rc"
}

check() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  %s[PASS]%s %s\n' "$C_G" "$C_0" "$desc"; log "PASS  $desc"; return 0
  fi
  printf '  %s[FAIL]%s %s\n' "$C_R" "$C_0" "$desc"; log "FAIL  $desc"; return 1
}

step() {   # step "<name>" function args... -> records result for the summary
  local name=$1; shift
  section "$name"
  if "$@"; then SUMMARY+=("PASS  $name"); else SUMMARY+=("FAIL  $name"); return 1; fi
}

print_summary() {
  section "Summary"
  local s
  for s in "${SUMMARY[@]}"; do
    case $s in PASS*) printf '  %s%s%s\n' "$C_G" "$s" "$C_0" ;; *) printf '  %s%s%s\n' "$C_R" "$s" "$C_0" ;; esac
  done
  log "SUMMARY: ${SUMMARY[*]}"
}

# ---- UI helpers (whiptail with text fallback) -------------------------------
ui_init() {
  if ! have whiptail; then
    apt-get install "${APT_OPTS[@]}" whiptail >>"$LOG_FILE" 2>&1 ||
      { apt-get update -q >>"$LOG_FILE" 2>&1 && apt-get install "${APT_OPTS[@]}" whiptail >>"$LOG_FILE" 2>&1; }
  fi
  if have whiptail; then UI="whiptail"; else UI="text"; fi
}

ui_size() {
  local rows cols
  read -r rows cols < <(stty size 2>/dev/null) || true
  rows=${rows:-24}; cols=${cols:-80}
  UI_H=$(( rows - 4 )); (( UI_H > 30 )) && UI_H=30; (( UI_H < 15 )) && UI_H=15
  UI_W=$(( cols - 6 )); (( UI_W > 96 )) && UI_W=96; (( UI_W < 60 )) && UI_W=60
  UI_L=$(( UI_H - 8 ))
}

ui_msg() {
  ui_size
  if [[ $UI == whiptail ]]; then
    whiptail --title "$1" --scrolltext --msgbox "$2" "$UI_H" "$UI_W"
  else
    printf '\n== %s ==\n%b\n' "$1" "$2"; read -rp "[Enter] " _ </dev/tty || true
  fi
}

ui_yesno() {   # title text [yes|no default]
  local title=$1 text=$2 def=${3:-yes} a
  ui_size
  if [[ $UI == whiptail ]]; then
    if [[ $def == no ]]; then
      whiptail --title "$title" --defaultno --yesno "$text" "$UI_H" "$UI_W"
    else
      whiptail --title "$title" --yesno "$text" "$UI_H" "$UI_W"
    fi
    return
  fi
  printf '\n== %s ==\n%b\n' "$title" "$text"
  if [[ $def == no ]]; then read -rp "[y/N] " a </dev/tty; a=${a:-n}
  else read -rp "[Y/n] " a </dev/tty; a=${a:-y}; fi
  [[ $a =~ ^[YyJj] ]]
}

ui_input() {   # title text [default] -> stdout
  local title=$1 text=$2 def=${3:-} out
  ui_size
  if [[ $UI == whiptail ]]; then
    out=$(whiptail --title "$title" --inputbox "$text" 14 "$UI_W" "$def" 3>&1 1>&2 2>&3) || return 1
  else
    printf '\n== %s ==\n%b\n' "$title" "$text" >&2
    read -rp "[${def}] > " out </dev/tty || return 1
    out=${out:-$def}
  fi
  printf '%s' "$out"
}

ui_menu() {   # title text tag item [tag item...] -> selected tag
  local title=$1 text=$2; shift 2
  ui_size
  if [[ $UI == whiptail ]]; then
    whiptail --title "$title" --menu "$text" "$UI_H" "$UI_W" "$UI_L" "$@" 3>&1 1>&2 2>&3
    return
  fi
  printf '\n== %s ==\n%b\n' "$title" "$text" >&2
  local -a tags=()
  while (( $# >= 2 )); do printf '  %-8s %s\n' "$1" "$2" >&2; tags+=("$1"); shift 2; done
  local c t
  read -rp "Choice (Enter = back): " c </dev/tty || return 1
  [[ -n $c ]] || return 1
  for t in "${tags[@]}"; do [[ ${t,,} == "${c,,}" ]] && { printf '%s' "$t"; return 0; }; done
  return 1
}

ui_checklist() {   # title text tag item ON|OFF [...] -> space separated tags
  local title=$1 text=$2; shift 2
  ui_size
  if [[ $UI == whiptail ]]; then
    local out
    out=$(whiptail --title "$title" --separate-output --checklist "$text" "$UI_H" "$UI_W" "$UI_L" "$@" 3>&1 1>&2 2>&3) || return 1
    printf '%s' "$out" | tr '\n' ' '
    return 0
  fi
  printf '\n== %s ==\n%b\n' "$title" "$text" >&2
  local -a defs=(); local mark a
  while (( $# >= 3 )); do
    mark=" "; [[ $3 == ON ]] && { mark="x"; defs+=("$1"); }
    printf '  [%s] %-10s %s\n' "$mark" "$1" "$2" >&2; shift 3
  done
  read -rp "Tags separated by space (Enter = the [x] ones): " a </dev/tty || return 1
  printf '%s' "${a:-${defs[*]}}"
}

# ---- system helpers ---------------------------------------------------------
require_root() {
  [[ $EUID -eq 0 ]] || { echo "This script must run as root:  su -   (or: sudo bash $0)" >&2; exit 1; }
}

detect_os() {
  [[ -r /etc/os-release ]] && . /etc/os-release
  OS_ID=${ID:-unknown}; OS_VER=${VERSION_ID:-?}
  OS_CODENAME=${VERSION_CODENAME:-}; OS_PRETTY=${PRETTY_NAME:-unknown}
  if [[ $OS_ID != "debian" ]]; then
    err "This script is designed for Debian only. Detected: $OS_PRETTY"
    return 1
  fi
  if [[ $OS_VER != "12" && $OS_VER != "13" ]]; then
    warn "This script is tested on Debian 12/13. Detected: $OS_PRETTY"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }
has()  { [[ " $1 " == *" $2 "* ]]; }   # has "<list>" "<tag>"

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

apt_update()  { run apt-get update -q -o DPkg::Lock::Timeout=300 && APT_UPDATED=1; }
apt_install() { (( APT_UPDATED )) || apt_update || return 1; run apt-get install "${APT_OPTS[@]}" "$@"; }

have_internet() {
  curl -fsSI --max-time 8 https://deb.debian.org >/dev/null 2>&1 ||
  ping -c1 -W3 1.1.1.1 >/dev/null 2>&1
}

preflight_internet() {
  have_internet || { err "No internet connectivity - cannot install packages."; return 1; }
}

sudo_members() { getent group sudo 2>/dev/null | cut -d: -f4 | tr ',' ' '; }

maybe_add_docker_group() {
  local u=$1
  if have docker && ! id -nG "$u" 2>/dev/null | grep -qw docker; then
    usermod -aG docker "$u" && info "Added $u to docker group"
  fi
}

ufw_active() { have ufw && ufw status 2>/dev/null | grep -q "Status: active"; }

require_docker() {
  have docker && docker info >/dev/null 2>&1 && return 0
  err "Docker is not installed or not running - install module 'docker' first."
  return 1
}

# =============================================================================
#  NVIDIA GPU detection / installability
# =============================================================================
nv_detect_gpus() {
  NV_GPU_COUNT=0; NV_GPU_NAMES=(); NV_PCI_IDS=""
  have lspci || apt_install pciutils >/dev/null 2>&1 || true
  if have lspci; then
    local line name id
    while IFS= read -r line; do
      NV_GPU_COUNT=$((NV_GPU_COUNT + 1))
      name=$(printf '%s' "$line" | sed 's/.*: //')
      id=$(printf '%s' "$line" | awk '{print $3}')   # e.g. [10de:0ff9]
      NV_GPU_NAMES+=("$name")
      NV_PCI_IDS+="$id "
    done < <(lspci -nn 2>/dev/null | grep -i 'nvidia\|3d controller' || true)
  fi
  NV_PCI_IDS=${NV_PCI_IDS% }
  (( NV_GPU_COUNT > 0 ))
}

nv_identify_driver() {
  # returns recommended driver name on stdout; sets NV_DRIVER
  local driver="unknown" id legacy
  local -a legacy_ids=("10DE0600" "10DE0601" "10DE0602" "10DE0603" "10DE0604" "10DE0605"
    "10DE0610" "10DE0611" "10DE0612" "10DE0613" "10DE0614" "10DE0615"
    "10DE05E" "10DE05EA" "10DE0622" "10DE0623" "10DE06C0" "10DE06D0")
  if have nvidia-detect; then
    driver=$(nvidia-detect --output-driver 2>/dev/null)
    [[ -n $driver ]] && { NV_DRIVER=$driver; printf '%s' "$driver"; return 0; }
  fi
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    NV_DRIVER="existing"; printf 'existing'; return 0
  fi
  for id in $NV_PCI_IDS; do
    id=${id#*\[}; id=${id%%\]*}   # strip brackets -> 10de:0ff9
    id=${id//:/}; id=${id^^}      # -> 10DE0FF9
    for legacy in "${legacy_ids[@]}"; do
      [[ $id == "$legacy" ]] && { NV_DRIVER="tesla-470"; printf 'tesla-470'; return 0; }
    done
  done
  NV_DRIVER="tesla-470"   # default for older/tesla GPUs
  printf 'tesla-470'
}

nv_check_smi() {
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then NV_SMI_OK=1; return 0; fi
  NV_SMI_OK=0; return 1
}

# nv_install_possible -> prints a report and returns 0 if a GPU install is possible
nv_install_possible() {
  local reasons=()
  [[ $EUID -eq 0 ]] || reasons+=("not running as root")
  [[ ${OS_ID:-} == "debian" ]] || reasons+=("not a Debian system (${OS_PRETTY:-unknown})")
  have_internet || reasons+=("no internet connectivity")
  (( NV_GPU_COUNT > 0 )) || reasons+=("no NVIDIA GPU detected via lspci")
  if (( ${#reasons[@]} == 0 )); then
    printf 'YES - %d NVIDIA GPU(s) detected, recommended driver: %s\n' "$NV_GPU_COUNT" "$NV_DRIVER"
    return 0
  fi
  local r out=""
  for r in "${reasons[@]}"; do out+="${out:+, }$r"; done
  printf 'NO - %s\n' "$out"
  return 1
}

nv_status_report() {
  section "NVIDIA GPU status"
  if (( NV_GPU_COUNT > 0 )); then
    local i
    for i in "${!NV_GPU_NAMES[@]}"; do
      printf '  GPU %d: %s\n' "$((i+1))" "${NV_GPU_NAMES[$i]}"
    done
    printf '  PCI IDs: %s\n' "${NV_PCI_IDS:-none}"
    printf '  Recommended driver: %s\n' "$NV_DRIVER"
  else
    printf '  No NVIDIA GPU detected via lspci.\n'
  fi
  if nv_check_smi; then ok "nvidia-smi works - driver already active"; nvidia-smi | head -12
  else warn "nvidia-smi not available/working - driver not active yet"; fi
  if lsmod 2>/dev/null | grep -q '^nvidia'; then ok "nvidia kernel module loaded"; else info "nvidia kernel module not loaded"; fi
  if lsmod 2>/dev/null | grep -q nouveau; then warn "nouveau loaded - will be blacklisted during driver install"; fi
  printf '  Installation possible: '
  nv_install_possible || true
}

# =============================================================================
#  NVIDIA driver / toolkit functions (from nvidia-docker-setup.sh)
# =============================================================================
nv_disable_nouveau() {
  if ! lsmod 2>/dev/null | grep -q nouveau; then
    ok "Nouveau is not loaded"; return 0
  fi
  cat <<'EOF' > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
  have update-initramfs && run update-initramfs -u
  ok "Nouveau disabled and initramfs updated"
}

nv_install_driver() {   # nv_install_driver <driver> <with_nvenc:true|false>
  local driver_type=${1:-$NV_DRIVER} with_nvenc=${2:-false}
  section "Installing NVIDIA driver ($driver_type)"
  nv_disable_nouveau
  case $driver_type in
    tesla-470)
      apt_install nvidia-tesla-470-driver || return 1
      if [[ $with_nvenc == true ]]; then
        apt_install nvidia-cuda-toolkit nvidia-utils-470 || return 1
      fi
      ;;
    existing)
      ok "NVIDIA driver already installed"; return 0 ;;
    *)
      apt_install nvidia-driver || apt_install firmware-misc-nonfree || return 1 ;;
  esac
  have modprobe && { run modprobe nvidia || warn "Could not load nvidia module"
                     run modprobe nvidia-uvm || true
                     run modprobe nvidia-drm || true; }
  ok "NVIDIA driver installation complete (reboot recommended)"
}

nv_install_persist() {
  section "NVIDIA Persistence Daemon"
  if [[ -f $NVIDIA_PERSISTENCE_SERVICE ]] && systemctl is-active --quiet nvidia-persistenced 2>/dev/null; then
    ok "Persistence daemon already configured and running"; return 0
  fi
  apt_install nvidia-persistenced || return 1
  cat <<EOF > $NVIDIA_PERSISTENCE_SERVICE
[Unit]
Description=NVIDIA Persistence Daemon
After=syslog.target network.target

[Service]
Type=forking
ExecStart=/usr/bin/nvidia-persistenced --user nvidia-persistenced
ExecStop=/usr/bin/nvidia-persistenced --kill

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable nvidia-persistenced
  run systemctl start nvidia-persistenced
  ok "Persistence daemon installed and started"
}

nv_install_toolkit() {
  section "NVIDIA Container Toolkit"
  local arch distribution
  arch=$(dpkg --print-architecture)
  distribution=$(. /etc/os-release; echo "${ID}${VERSION_ID}")
  if pkg_installed libnvidia-container1 && pkg_installed nvidia-container-toolkit; then
    ok "NVIDIA Container Toolkit already installed"; return 0
  fi
  apt_install ca-certificates curl gnupg || return 1
  install -m 0755 -d /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg || return 1
  echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/$distribution libnvidia-container" \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt_update || return 1
  apt_install libnvidia-container1 libnvidia-container-tools nvidia-container-toolkit || return 1
  nv_configure_docker
  run systemctl restart docker || return 1
  ok "NVIDIA Container Toolkit installed and Docker restarted"
}

nv_configure_docker() {   # merge nvidia runtime into /etc/docker/daemon.json
  local f=/etc/docker/daemon.json
  install -d -m 0755 /etc/docker
  if [[ -s $f ]]; then
    if jq -e '.runtimes | has("nvidia")' "$f" >/dev/null 2>&1; then
      ok "NVIDIA runtime already present in $f"; return 0
    fi
    cp "$f" "${f}.bak-$(date +%Y%m%d%H%M%S)"
    jq '. + {"default-runtime":"nvidia","runtimes":{"nvidia":{"path":"nvidia-container-runtime","runtimeArgs":[]}}}' \
      "$f" > "$f.new" && mv "$f.new" "$f" || { rm -f "$f.new"; return 1; }
  else
    cat > "$f" <<'EOF'
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": { "path": "nvidia-container-runtime", "runtimeArgs": [] }
  },
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  fi
  ok "Docker configured with nvidia runtime"
}

nv_install_cuda() {
  section "CUDA Toolkit (optional, host)"
  apt_install nvidia-cuda-toolkit || return 1
  ok "CUDA toolkit installed"
}

nv_validate() {
  section "Validating NVIDIA installation"
  local rc=0
  check "nvidia-smi available" have nvidia-smi || rc=1
  check "nvidia-smi runs" nvidia-smi || rc=1
  check "nvidia kernel module loaded" bash -c "lsmod | grep -q '^nvidia'" || rc=1
  check "NVIDIA device /dev/nvidia0" test -e /dev/nvidia0 || rc=1
  check "nvidia-container-cli" have nvidia-container-cli || rc=1
  have nvidia-smi && nvidia-smi | head -12
  return $rc
}

nv_validate_docker() {
  section "Validating Docker + NVIDIA (container GPU test)"
  require_docker || return 1
  local rc=0
  check "docker service active" systemctl is-active --quiet docker || rc=1
  check "nvidia runtime in daemon.json" grep -q nvidia /etc/docker/daemon.json || rc=1
  if docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi >>"$LOG_FILE" 2>&1; then
    ok "Docker container can access the NVIDIA GPU"
  else
    warn "Docker GPU test failed"; rc=1
  fi
  return $rc
}

# =============================================================================
#  Base modules (from debian-setup.sh, condensed)
# =============================================================================
PKG_CORE=(sudo curl wget git ca-certificates gnupg openssh-server whiptail apt-utils
          vim nano less htop btop tmux rsync unzip zip xz-utils bzip2 tree ncdu jq
          bash-completion man-db lsof psmisc procps file cron logrotate iotop sysstat
          pciutils usbutils dmidecode)
PKG_NET=(iproute2 iputils-ping bind9-dnsutils net-tools traceroute mtr-tiny tcpdump
         netcat-openbsd nmap whois ethtool openssl socat)
PKG_DEV=(python3 python3-pip python3-venv python3-dev pipx build-essential pkg-config
         libssl-dev libffi-dev libxml2-dev libxslt1-dev zlib1g-dev sqlite3)
PKG_OSINT=(libimage-exiftool-perl poppler-utils parallel dos2unix)
PKG_ANON=(tor torsocks proxychains4)

maint_update() {
  section "System upgrade"
  apt_update || return 1
  run apt-get full-upgrade "${APT_OPTS[@]}"
}

install_base_tools() {   # install_base_tools "<groups...>"
  section "Base packages ($*)"
  local g
  for g in "$@"; do
    case $g in
      core)  apt_install "${PKG_CORE[@]}" || return 1 ;;
      net)   apt_install "${PKG_NET[@]}" || return 1 ;;
      dev)   apt_install "${PKG_DEV[@]}" || return 1 ;;
      osint) apt_install "${PKG_OSINT[@]}" || return 1 ;;
      anon)  apt_install "${PKG_ANON[@]}" || return 1 ;;
    esac
  done
  run systemctl enable --now cron || true
  ok "Base packages installed"
}

install_lvm_tools() {
  section "Disk & LVM tools"
  apt_install lvm2 cloud-guest-utils parted gdisk e2fsprogs xfsprogs btrfs-progs || return 1
}

setup_admin_user() {
  section "Sudo + admin user"
  apt_install sudo || return 1
  local user key
  user=$(ui_input "Admin user" "Username for the sudo admin user:" "admin") || return 1
  if id "$user" >/dev/null 2>&1; then
    usermod -aG sudo "$user" && ok "$user added to sudo group"
  else
    local pw
    pw=$(ui_input "Admin user" "Initial password for '$user':") || return 1
    useradd -m -s /bin/bash "$user"
    printf '%s:%s\n' "$user" "$pw" | chpasswd
    usermod -aG sudo "$user"
    ok "Created admin user '$user'"
  fi
  key=$(ui_input "SSH key" "Paste an SSH public key for '$user' (empty = skip):") || true
  if [[ -n $key ]]; then
    local home; home=$(getent passwd "$user" | cut -d: -f6)
    install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
    printf '%s\n' "$key" > "$home/.ssh/authorized_keys"
    chmod 0600 "$home/.ssh/authorized_keys"
    chown "$user:$user" "$home/.ssh/authorized_keys"
    ok "SSH key installed for '$user'"
  fi
}

configure_docker_daemon() {
  local f=/etc/docker/daemon.json
  local want='{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}'
  install -d -m 0755 /etc/docker
  if [[ -s $f ]]; then
    if jq -e '.runtimes | has("nvidia")' "$f" >/dev/null 2>&1; then
      ok "$f already contains the nvidia runtime - left unchanged"; return 0
    fi
    if jq -s '.[0] * .[1]' <(printf '%s' "$want") "$f" >"$f.new" 2>/dev/null; then
      mv "$f.new" "$f"; ok "Merged log rotation defaults into $f"
    else
      rm -f "$f.new"; warn "$f is not valid JSON - left unchanged"
    fi
  else
    printf '%s' "$want" | jq . >"$f"; ok "Wrote $f (log rotation 3x10MB)"
  fi
}

install_docker() {
  section "Docker Engine + Compose + Buildx"
  local arch p
  local -a conflicts=()
  arch=$(dpkg --print-architecture)
  [[ -n $OS_CODENAME ]] || { err "Could not detect Debian codename"; return 1; }
  for p in docker.io docker-doc docker-compose podman-docker containerd runc; do
    pkg_installed "$p" && conflicts+=("$p")
  done
  if (( ${#conflicts[@]} )); then
    info "Removing conflicting distro packages: ${conflicts[*]}"
    run apt-get remove "${APT_OPTS[@]}" "${conflicts[@]}" || return 1
  fi
  apt_install ca-certificates curl gnupg jq || return 1
  install -m 0755 -d /etc/apt/keyrings
  run curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc ||
    { err "Could not download the Docker GPG key"; return 1; }
  chmod a+r /etc/apt/keyrings/docker.asc
  rm -f /etc/apt/sources.list.d/docker.sources
  echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $OS_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt_update || { err "apt update failed - is '$OS_CODENAME' supported by download.docker.com?"; return 1; }
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  configure_docker_daemon
  run systemctl enable containerd docker || return 1
  run systemctl restart docker || return 1
  if ! have docker-compose; then
    printf '#!/bin/sh\nexec docker compose "$@"\n' >/usr/local/bin/docker-compose
    chmod 0755 /usr/local/bin/docker-compose
  fi
  install -d -m 0755 "$STACK_DIR" "$USER_STACKS_DIR"
  local u
  for u in $(sudo_members); do maybe_add_docker_group "$u"; done
  section "Verify Docker"
  local rc=0
  check "docker service active" systemctl is-active --quiet docker || rc=1
  check "docker CLI talks to daemon" docker info || rc=1
  check "docker compose plugin" docker compose version || rc=1
  check "test container (hello-world)" docker run --rm hello-world || rc=1
  docker image rm hello-world >/dev/null 2>&1
  if ufw_active; then
    warn "Docker-published ports bypass UFW - consider module 'ufwdocker'."
  fi
  return $rc
}

install_cockpit() {
  section "Cockpit web admin (:9090)"
  apt_install cockpit cockpit-machines cockpit-podman || return 1
  run systemctl enable --now cockpit.socket
  ok "Cockpit available at https://<host>:9090"
}

# ---- web UIs (compose stacks, only ONE of them) ------------------------------
stack_up() {
  local name=$1
  require_docker || return 1
  ( cd "$STACK_DIR/$name" && docker compose up -d ) || return 1
  ok "$name is up"
}

deploy_portainer() {
  section "Portainer CE (:9443)"
  require_docker || return 1
  install -d -m 0755 "$STACK_DIR/portainer"
  cat > "$STACK_DIR/portainer/docker-compose.yml" <<'EOF'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports: ["9443:9443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
volumes:
  portainer_data:
EOF
  stack_up portainer
}

deploy_dockge() {
  section "Dockge (:5001)"
  require_docker || return 1
  install -d -m 0755 "$STACK_DIR/dockge" "$USER_STACKS_DIR"
  cat > "$STACK_DIR/dockge/docker-compose.yml" <<'EOF'
services:
  dockge:
    image: louislam/dockge:latest
    container_name: dockge
    restart: unless-stopped
    ports: ["5001:5001"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - dockge_data:/app/data
      - /opt/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
volumes:
  dockge_data:
EOF
  stack_up dockge
}

deploy_dozzle() {
  section "Dozzle log viewer (:8888)"
  require_docker || return 1
  install -d -m 0755 "$STACK_DIR/dozzle"
  cat > "$STACK_DIR/dozzle/docker-compose.yml" <<'EOF'
services:
  dozzle:
    image: amir20/dozzle:latest
    container_name: dozzle
    restart: unless-stopped
    ports: ["8888:8080"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
EOF
  stack_up dozzle
}

remove_webui() {
  local name=$1
  require_docker || return 1
  if docker container inspect "$name" >/dev/null 2>&1; then
    ( cd "$STACK_DIR/$name" 2>/dev/null && docker compose down ) || docker rm -f "$name"
    ok "$name removed (data in $STACK_DIR/$name kept)"
  else
    info "$name is not running"
  fi
}

# ---- hardening ---------------------------------------------------------------
harden_ufw() {
  section "UFW firewall"
  apt_install ufw || return 1
  local port; port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
  port=${port:-22}
  ufw allow "$port"/tcp
  ufw allow 9090/tcp   # cockpit
  ufw --force enable
  ufw status verbose
  ok "UFW active (SSH:$port, Cockpit:9090 allowed)"
}

harden_ufw_docker() {
  section "UFW + Docker port filtering"
  harden_ufw >/dev/null || return 1
  # insert docker chain markers into /etc/ufw/after.rules (idempotent)
  if ! grep -qs "BEGIN UFW AND DOCKER" /etc/ufw/after.rules; then
    cp /etc/ufw/after.rules "/etc/ufw/after.rules.bak-$(date +%Y%m%d%H%M%S)"
    cat >> /etc/ufw/after.rules <<'EOF'

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j RETURN
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
COMMIT
# END UFW AND DOCKER
EOF
    run ufw reload
    ok "Docker ports are now filtered by UFW (LAN-only default)"
  else
    ok "UFW Docker filter already present"
  fi
}

harden_fail2ban() {
  section "Fail2ban"
  apt_install fail2ban python3-systemd || return 1
  cat > /etc/fail2ban/jail.d/90-debian-gpu-setup.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
bantime = 1h
EOF
  run systemctl enable --now fail2ban
  ok "Fail2ban active (sshd jail)"
}

harden_ssh() {
  section "SSH hardening"
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > "$SSH_DROPIN" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
EOF
  run systemctl reload ssh || run systemctl reload sshd || true
  ok "SSH drop-in written ($SSH_DROPIN)"
}

harden_sysctl() {
  section "Kernel sysctl hardening"
  cat > /etc/sysctl.d/90-debian-gpu-setup-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
  run sysctl --system
  ok "Sysctl hardening applied"
}

harden_autoupdates() {
  section "Unattended security updates"
  apt_install unattended-upgrades apt-listchanges || return 1
  cat > /etc/apt/apt.conf.d/52debian-gpu-setup-unattended <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Origins-Pattern { "origin=Debian,codename=${distro_codename},label=Debian-Security"; };
EOF
  run systemctl enable --now unattended-upgrades || true
  ok "Automatic security updates enabled"
}

harden_apparmor() {
  section "AppArmor"
  apt_install apparmor apparmor-utils || return 1
  aa-enabled 2>/dev/null && ok "AppArmor is enabled" || { run systemctl enable --now apparmor; ok "AppArmor enabled"; }
}

self_install() {
  section "Install as system command"
  install -m 0755 "$SCRIPT_PATH" "$INSTALL_PATH"
  ok "Installed as $INSTALL_PATH - run 'debian-gpu-setup' anytime"
}

# =============================================================================
#  Module system
# =============================================================================
MODULES=(
  "upgrade|System upgrade (apt full-upgrade)"
  "core|Admin tools: sudo curl git vim htop tmux jq ssh"
  "net|Network diagnostics: dig mtr nmap tcpdump whois"
  "lvm|Disk & LVM tools: lvm2 growpart parted gdisk"
  "dev|Python/pipx/build tools"
  "osint|OSINT helpers: exiftool pdf-tools parallel"
  "anon|Tor + torsocks + proxychains4"
  "sudo|Sudo + admin user (+ SSH key)"
  "docker|Docker Engine + Compose + Buildx"
  "nv-driver|NVIDIA driver (auto-detected, nouveau blacklist)  [needs GPU]"
  "nv-persist|NVIDIA persistence daemon                       [needs GPU]"
  "nv-toolkit|NVIDIA Container Toolkit + Docker nvidia runtime [needs GPU, needs docker]"
  "nv-cuda|CUDA toolkit on host (optional)                  [needs GPU]"
  "nv-test|Validate: nvidia-smi + docker --gpus all test     [needs GPU]"
  "cockpit|Cockpit web admin            https :9090"
  "ufw|UFW firewall (deny in, allow SSH/Cockpit)"
  "ufwdocker|UFW filters Docker ports"
  "fail2ban|Fail2ban SSH brute-force protection"
  "ssh|SSH hardening (root login / passwords off)"
  "sysctl|Kernel & network sysctl hardening"
  "autoupd|Automatic security updates"
  "apparmor|AppArmor"
  "self|Install script as 'debian-gpu-setup' command"
  "portainer|Docker UI: Portainer CE    https :9443"
  "dockge|Docker UI: Dockge          http  :5001"
  "dozzle|Docker UI: Dozzle (logs)   http  :8888"
)

WEBUIS="portainer dockge dozzle"
NV_MODULES="nv-driver nv-persist nv-toolkit nv-cuda nv-test"

PRESET_FULL="upgrade core net lvm dev osint sudo docker cockpit portainer ufw fail2ban ssh sysctl autoupd apparmor self"
PRESET_DOCKER="upgrade core net lvm sudo docker cockpit portainer ufw fail2ban ssh sysctl autoupd apparmor self"
PRESET_GPU="upgrade core net sudo docker nv-driver nv-persist nv-toolkit nv-test ufw fail2ban ssh autoupd portainer self"
PRESET_HARDEN="ufw fail2ban ssh sysctl autoupd apparmor"

module_desc() {
  local e
  for e in "${MODULES[@]}"; do [[ ${e%%|*} == "$1" ]] && { printf '%s' "${e#*|}"; return 0; }; done
  return 1
}

module_installed() {
  case $1 in
    upgrade)   return 1 ;;  # always re-runnable
    core)      have sudo && have git && have jq && have tmux ;;
    net)       have dig && have nmap && have mtr ;;
    lvm)       have lvs && have growpart && have parted ;;
    dev)       have pipx && have gcc ;;
    osint)     have exiftool ;;
    anon)      have torsocks ;;
    sudo)      [[ -n $(sudo_members | tr -d ' ') ]] ;;
    docker)    have docker && docker compose version >/dev/null 2>&1 ;;
    nv-driver) nv_check_smi ;;
    nv-persist) systemctl is-active --quiet nvidia-persistenced 2>/dev/null ;;
    nv-toolkit) pkg_installed nvidia-container-toolkit && grep -q nvidia /etc/docker/daemon.json 2>/dev/null ;;
    nv-cuda)   pkg_installed nvidia-cuda-toolkit ;;
    nv-test)   return 1 ;;  # validation is always re-runnable
    cockpit)   systemctl is-enabled --quiet cockpit.socket 2>/dev/null ;;
    portainer|dockge|dozzle) have docker && docker container inspect "$1" >/dev/null 2>&1 ;;
    ufw)       ufw_active ;;
    ufwdocker) grep -qs "BEGIN UFW AND DOCKER" /etc/ufw/after.rules ;;
    fail2ban)  systemctl is-active --quiet fail2ban 2>/dev/null ;;
    ssh)       [[ -f $SSH_DROPIN ]] ;;
    sysctl)    [[ -f /etc/sysctl.d/90-debian-gpu-setup-hardening.conf ]] ;;
    autoupd)   [[ -f /etc/apt/apt.conf.d/52debian-gpu-setup-unattended ]] ;;
    apparmor)  aa-enabled 2>/dev/null | grep -qi yes ;;
    self)      [[ -x $INSTALL_PATH ]] ;;
    *)         return 1 ;;
  esac
}

module_run() {
  case $1 in
    upgrade)   maint_update ;;
    core|net|dev|osint|anon) install_base_tools "$1" ;;
    lvm)       install_lvm_tools ;;
    sudo)      setup_admin_user ;;
    docker)    install_docker ;;
    nv-driver)
      local nvenc=false
      if ui_yesno "NVENC support" "Install NVENC/NVDEC support (nvidia-cuda-toolkit, nvidia-utils)?\nNote: entry-level GPUs (e.g. GT710) may not support NVENC." no; then nvenc=true; fi
      nv_install_driver "$NV_DRIVER" "$nvenc" ;;
    nv-persist) nv_install_persist ;;
    nv-toolkit) nv_install_toolkit ;;
    nv-cuda)    nv_install_cuda ;;
    nv-test)    nv_validate && nv_validate_docker ;;
    cockpit)   install_cockpit ;;
    portainer) require_docker && deploy_portainer ;;
    dockge)    require_docker && deploy_dockge ;;
    dozzle)    require_docker && deploy_dozzle ;;
    ufw)       harden_ufw ;;
    ufwdocker) harden_ufw_docker ;;
    fail2ban)  harden_fail2ban ;;
    ssh)       harden_ssh ;;
    sysctl)    harden_sysctl ;;
    autoupd)   harden_autoupdates ;;
    apparmor)  harden_apparmor ;;
    self)      self_install ;;
    *)         err "Unknown module '$1'"; return 1 ;;
  esac
}

webuis_in() {
  local t out=""
  for t in $WEBUIS; do has " $1 " "$t" && out+="$t "; done
  printf '%s' "${out% }"
}

webuis_installed() {
  local t out=""
  for t in $WEBUIS; do module_installed "$t" && out+="$t "; done
  printf '%s' "${out% }"
}

nv_in() {
  local t out=""
  for t in $NV_MODULES; do has " $1 " "$t" && out+="$t "; done
  printf '%s' "${out% }"
}

# run_modules "<tags>" [noconfirm]
run_modules() {
  local sel=" $1 " confirm=${2:-confirm} e tag plan="" list="" added="" needs_net=0 ui replace="" nv=""
  # reject NVIDIA modules when no GPU was detected
  nv=$(nv_in "$sel")
  if [[ -n $nv ]]; then
    if (( NV_GPU_COUNT == 0 )); then
      err "No NVIDIA GPU detected - NVIDIA modules not installable: $nv"
      info "Run menu entry 'status' to see the detection report."
      return 1
    fi
  fi
  # only one docker web UI
  ui=$(webuis_in "$sel")
  if [[ $ui == *" "* ]]; then
    err "Only ONE Docker web UI is allowed (selected: $ui)."; return 1
  fi
  if [[ -n $ui ]]; then
    local o
    for o in $(webuis_installed); do [[ $o != "$ui" ]] && replace+="$o "; done
    replace=${replace% }
    if [[ -n $replace ]]; then
      if [[ $confirm == noconfirm ]]; then
        err "$replace is already installed - only one web UI allowed. Remove it first."
        return 1
      fi
      ui_yesno "Only one Docker web UI" "$replace is already installed. Remove it (data kept) and install $ui instead?" no || return 0
      remove_webui "$replace"
    fi
    if ! has "$sel" docker && ! module_installed docker; then
      sel+="docker "; added+="docker "
    fi
  fi
  # NVIDIA dependencies
  if has "$sel" nv-toolkit; then
    has "$sel" docker || module_installed docker || { sel+="docker "; added+="docker "; }
    has "$sel" nv-driver || module_installed nv-driver || { sel+="nv-driver "; added+="nv-driver "; }
  fi
  if has "$sel" nv-test && ! has "$sel" nv-toolkit && ! module_installed nv-toolkit; then
    sel+="nv-toolkit "; added+="nv-toolkit "
  fi
  if has "$sel" nv-persist && ! has "$sel" nv-driver && ! module_installed nv-driver; then
    sel+="nv-driver "; added+="nv-driver "
  fi
  if has "$sel" ufwdocker && ! has "$sel" ufw && ! ufw_active; then
    sel+="ufw "; added+="ufw "
  fi
  # build plan in MODULES order
  for e in "${MODULES[@]}"; do
    tag=${e%%|*}
    has "$sel" "$tag" || continue
    plan+="$tag "
    list+="  - ${e#*|}$(module_installed "$tag" && echo '  (re-run)')\n"
    case $tag in ssh|sysctl|self|nv-test) ;; *) needs_net=1 ;; esac
  done
  [[ -n $plan ]] || { info "No modules selected."; return 0; }
  if [[ $confirm != noconfirm ]]; then
    ui_yesno "Confirm installation" "These modules run in this order:\n\n$list${added:+\nAdded as dependency: $added\n}\nContinue?" || return 0
  fi
  (( needs_net )) && { preflight_internet || return 1; }
  local rc=0 t
  for t in $plan; do
    step "$t: $(module_desc "$t")" module_run "$t" || rc=1
  done
  print_summary
  return $rc
}

# =============================================================================
#  Menus
# =============================================================================
menu_install() {
  local -a items=()
  local e tag state
  for e in "${MODULES[@]}"; do
    tag=${e%%|*}
    state="OFF"
    module_installed "$tag" && state="ON"
    # NVIDIA modules: only selectable when a GPU was detected
    if has " $NV_MODULES " "$tag" && (( NV_GPU_COUNT == 0 )); then
      items+=("$tag" "${e#*|}  [no NVIDIA GPU detected - disabled]" "OFF")
    else
      items+=("$tag" "$(module_installed "$tag" && echo '[ok] ' || echo '     ')${e#*|}" "$state")
    fi
  done
  local sel
  sel=$(ui_checklist "Install modules" "SPACE toggles, ENTER installs. NVIDIA modules need a detected GPU." "${items[@]}") || return 0
  [[ -n $sel ]] && run_modules "$sel" confirm
}

menu_presets() {
  local p
  p=$(ui_menu "Presets" "Choose a preset (NVIDIA preset requires a detected GPU):" \
      full   "Full server (base + docker + portainer + hardening)" \
      docker "Docker host (base + docker + portainer + hardening)" \
      gpu    "GPU server (base + docker + NVIDIA + portainer)  [needs GPU]" \
      harden "Hardening only (ufw fail2ban ssh sysctl autoupd apparmor)") || return 0
  case $p in
    full)   run_modules "$PRESET_FULL" confirm ;;
    docker) run_modules "$PRESET_DOCKER" confirm ;;
    gpu)
      if (( NV_GPU_COUNT == 0 )); then
        err "No NVIDIA GPU detected - GPU preset not available."
        nv_status_report
      else
        run_modules "$PRESET_GPU" confirm
      fi ;;
    harden) run_modules "$PRESET_HARDEN" confirm ;;
  esac
}

menu_webui() {
  local w
  w=$(ui_menu "Docker web UIs" "Exactly ONE of them next to Cockpit:" \
      portainer "Portainer CE  https :9443" \
      dockge    "Dockge        http  :5001" \
      dozzle    "Dozzle        http  :8888" \
      remove    "Remove installed web UI (data kept)") || return 0
  case $w in
    portainer|dockge|dozzle) run_modules "$w" confirm ;;
    remove)
      local installed; installed=$(webuis_installed)
      [[ -n $installed ]] || { info "No web UI installed."; return 0; }
      remove_webui "$installed" ;;
  esac
}

menu_status() {
  local interactive=${1:-yes}
  section "System status"
  printf '  OS: %s\n  Kernel: %s\n  User: %s (uid=%s)\n' "${OS_PRETTY:-unknown}" "$(uname -r)" "$(id -un)" "$EUID"
  nv_status_report
  section "Installed modules"
  local e tag found=0
  for e in "${MODULES[@]}"; do
    tag=${e%%|*}
    if module_installed "$tag"; then printf '  [ok] %-10s %s\n' "$tag" "${e#*|}"; found=1; fi
  done
  (( found )) || printf '  (no modules detected as installed)\n'
  if [[ $interactive == yes ]]; then
    ui_msg "Status" "GPU: $NV_GPU_COUNT detected, driver: $NV_DRIVER, nvidia-smi: $([[ $NV_SMI_OK == 1 ]] && echo working || echo not-working)\nInstallation possible: $(nv_install_possible 2>/dev/null || echo NO)"
  fi
}

show_main_menu() {
  local c
  while true; do
    c=$(ui_menu "debian-gpu-setup v$SCRIPT_VERSION" \
      "NVIDIA GPU: $NV_GPU_COUNT detected (driver: $NV_DRIVER) - $(nv_install_possible >/dev/null 2>&1 && echo 'install possible' || echo 'install NOT possible')" \
      status   "Show system + GPU status and installability" \
      install  "Install modules (checklist)" \
      presets  "Installation presets (full / docker / gpu / harden)" \
      webui    "Docker web UI (Portainer / Dockge / Dozzle)" \
      gpu      "NVIDIA quick setup (driver + toolkit + test)  [needs GPU]" \
      reboot   "Reboot (recommended after NVIDIA driver install)" \
      exit     "Exit") || break
    case $c in
      status)  menu_status ;;
      install) menu_install ;;
      presets) menu_presets ;;
      webui)   menu_webui ;;
      gpu)
        if (( NV_GPU_COUNT == 0 )); then
          err "No NVIDIA GPU detected - NVIDIA quick setup not available."
          nv_status_report
        else
          run_modules "nv-driver nv-persist nv-toolkit nv-test" confirm
        fi ;;
      reboot)  ui_yesno "Reboot" "Reboot now?" no && reboot ;;
      exit)    break ;;
    esac
  done
}

# =============================================================================
#  CLI
# =============================================================================
show_usage() {
  cat <<EOF
debian-gpu-setup.sh v$SCRIPT_VERSION - unified Debian + NVIDIA GPU setup

Usage:
  bash $SCRIPT_NAME                 interactive menu
  bash $SCRIPT_NAME --status        system + GPU status, installability check
  bash $SCRIPT_NAME --list-modules  list all modules
  bash $SCRIPT_NAME --install a,b,c install modules non-interactively (asks for confirm unless --yes)
  bash $SCRIPT_NAME --gpu           NVIDIA quick setup (driver, toolkit, test) - needs detected GPU
  bash $SCRIPT_NAME --yes           skip confirmation prompts (with --install/--gpu)
  bash $SCRIPT_NAME --help          this help

NVIDIA modules: $(echo $NV_MODULES | tr ' ' ',')
They are only selectable when an NVIDIA GPU is detected via lspci.
EOF
}

main() {
  case "${1:-}" in
    --help|-h) show_usage; exit 0 ;;
    --status)
      detect_os 2>/dev/null || true
      nv_detect_gpus; nv_identify_driver >/dev/null; nv_check_smi
      menu_status no; exit 0 ;;
    --list-modules)
      local e
      for e in "${MODULES[@]}"; do printf '%-10s %s\n' "${e%%|*}" "${e#*|}"; done
      exit 0 ;;
    --install|--gpu)
      require_root; detect_os || die "Debian 12/13 required (detected: ${OS_PRETTY:-unknown})"; ui_init
      nv_detect_gpus; nv_identify_driver >/dev/null; nv_check_smi
      local mods confirm="confirm"
      if [[ $1 == --gpu ]]; then mods="nv-driver nv-persist nv-toolkit nv-test"
      else mods=${2:-}; [[ -n $mods ]] || die "--install needs a module list, e.g. --install core,docker"; fi
      [[ ${3:-} == --yes || ${2:-} == --yes ]] && confirm="noconfirm"
      run_modules "$mods" "$confirm"
      exit $? ;;
    "")
      require_root; detect_os || die "Debian 12/13 required (detected: ${OS_PRETTY:-unknown})"; ui_init
      nv_detect_gpus; nv_identify_driver >/dev/null; nv_check_smi
      show_main_menu; exit 0 ;;
    *) err "Unknown option '$1'"; show_usage; exit 1 ;;
  esac
}

main "$@"
