# NVIDIA Tesla 470 Driver Installation Script for Debian 12

## Overview
This script removes any previously installed NVIDIA drivers, disables the Nouveau driver, and installs the NVIDIA Tesla 470 driver on a Debian 12 system. It also provides an optional benchmarking tool installation.

## Features
- **Cleans up old NVIDIA drivers**
- **Disables Nouveau driver** to prevent conflicts
- **Installs NVIDIA Tesla 470 driver**
- **Reboots system** to apply changes
- **Optional: Installs benchmarking tools** (`glxgears`, `vulkaninfo`)

## Prerequisites
- Root privileges are required to run this script.
- A Debian 12 system with a supported NVIDIA GPU (e.g., GeForce GT 710).

## Installation & Usage
### 1. Download the script
```bash
wget -O install_nvidia_tesla_470.sh https://your-link-to-script.sh
```

### 2. Make the script executable
```bash
chmod +x install_nvidia_tesla_470.sh
```

### 3. Run the script as root
```bash
./install_nvidia_tesla_470.sh
```

### 4. Verify installation after reboot
```bash
nvidia-smi
```

## Optional: Install Benchmarking Tools
After confirming the installation, you can install benchmarking tools manually:
```bash
sudo apt install -y mesa-utils vulkan-tools
```
To run tests:
```bash
glxgears
vulkaninfo | grep "GPU id"
```

## Troubleshooting
### 1. NVIDIA Driver Not Detected
- Check if the driver is loaded:
  ```bash
  lsmod | grep nvidia
  ```
- If empty, try manually loading it:
  ```bash
  modprobe nvidia
  ```
- Check system logs for errors:
  ```bash
  dmesg | grep -i nvidia
  ```

### 2. Secure Boot Issues
If the system uses **Secure Boot**, disable it in the BIOS as it may block NVIDIA drivers.

## License
This script is provided as-is without warranty. Use at your own risk.

