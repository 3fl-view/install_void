#!/bin/bash

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# Run LVM.sh to create partitions and filesystems
echo "Running LVM.sh..."
. ./disk_config.sh
lvm_exit_code=$?

# Check if LVM.sh was successful
if [ $lvm_exit_code -ne 0 ]; then
    echo "LVM.sh encountered an error. Exiting install_void.sh."
    exit 1
fi

# Install Void Linux on the given filesystem
echo "Installing Void Linux on the created filesystem..."
xbps-install -Sy -R https://alpha.de.repo.voidlinux.org/current -r /mnt base-system lvm2 xfsprogs exfatprogs

# Prompt the user whether to install void-repo-nonfree
read -p "Do you want to install void-repo-nonfree? (y/n) " nonfree_reply
if [[ "${nonfree_reply,,}" =~ ^(yes|y)$ ]]; then
    echo "Installing void-repo-nonfree..."
    xbps-install -y -R https://alpha.de.repo.voidlinux.org/current -r /mnt void-repo-nonfree
    xbps-install -Sy -r /mnt
fi

# Prompt the user to install additional packages
echo "You can now install additional packages."
echo "Enter the package names separated by spaces or leave empty to skip this step."
read -p "Packages: " additional_packages
if [ -n "$additional_packages" ]; then
    xbps-install -y -r /mnt $additional_packages
fi

# Run voidstrap.sh for post-install configuration
echo "Running voidstrap.sh..."
./voidstrap.sh
