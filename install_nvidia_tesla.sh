#!/bin/bash
# NVIDIA Tesla Driver Installation Script with Optional NVENC Support

set -e  # Exit on error

# Ensure the script is executed with root privileges
if [[ $EUID -ne 0 ]]; then
  echo "? This script must be run as root. Please run with sudo or as root."
  exit 1
fi

# Function: Remove existing drivers, disable Nouveau, and update package lists
prepare_system() {
  echo "?? Removing any existing NVIDIA drivers..."
  apt remove --purge -y '^nvidia-.*' 'libnvidia*' 'xserver-xorg-video-nvidia' 'cuda*'
  apt autoremove -y
  apt clean

  echo "?? Disabling Nouveau driver..."
  cat <<EOF > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
  update-initramfs -u

  echo "?? Updating package lists..."
  apt update
}

# Function: Install the default Tesla driver (matches the provided default installation)
install_tesla() {
  echo "??? Installing NVIDIA Tesla 470 driver..."
  apt install -y nvidia-tesla-470-driver
}

# Function: Install additional packages for NVENC support
install_nvenc() {
  echo "?? Installing CUDA Toolkit for NVENC/NVDEC..."
  apt install -y nvidia-cuda-toolkit nvidia-utils-470

  echo "?? Installing FFmpeg with NVIDIA support..."
  apt install -y ffmpeg
}

# Display installation options to the user
echo "==================================================="
echo "       NVIDIA Tesla Driver Installation"
echo "==================================================="
echo ""
echo "Please select an installation type:"
echo "1) Tesla driver only (default)"
echo "2) Tesla driver with NVENC support"
read -rp "Enter your choice [1-2]: " choice

# Process the user's selection
case "$choice" in
  2)
    echo "? You selected: Tesla driver with NVENC support."
    prepare_system
    install_tesla
    install_nvenc
    ;;
  1|*)
    echo "? You selected: Tesla driver only."
    prepare_system
    install_tesla
    ;;
esac

echo "?? Rebooting system to apply changes..."
sleep 3
reboot
