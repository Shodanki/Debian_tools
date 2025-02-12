#!/bin/bash

echo "?? Removing any existing NVIDIA drivers..."
apt remove --purge -y '^nvidia-.*' 'libnvidia*' 'xserver-xorg-video-nvidia' 'cuda*'
apt autoremove -y
apt clean

echo "?? Disabling Nouveau driver..."
echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
echo "options nouveau modeset=0" >> /etc/modprobe.d/blacklist-nouveau.conf
update-initramfs -u

echo "?? Updating package lists..."
apt update

echo "??? Installing NVIDIA Tesla 470 driver..."
apt install -y nvidia-tesla-470-driver

echo "?? Rebooting system to apply changes..."
sleep 3
reboot

# The script continues after reboot

