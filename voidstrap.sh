#!/bin/bash

set -e

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# Installation type (glibc or musl)
install_type="glibc"

# Set the target directory
target_dir="/mnt"

# Void Linux repository mirror
REPO="https://alpha.de.repo.voidlinux.org/current"

# Prompt for the username
read -r -p "Enter the username for the new user: " user_name

# Function to configure the Void Linux system
ln ./configure_void.sh /mnt/configure_void.sh

# Perform the chroot
echo "Setting up and entering chroot environment..."
if command -v xchroot >/dev/null 2>&1; then
    echo "Using xchroot to set up and enter chroot..."
    xchroot "${target_dir}" /bin/bash -c "/configure_void.sh"
else
    echo "xchroot not found, setting up chroot manually..."
    mount -t proc /proc "${target_dir}/proc"
    mount --rbind /sys "${target_dir}/sys"
    mount --rbind /dev "${target_dir}/dev"
    mount --rbind /run "${target_dir}/run"

    if [ "${install_type,,}" = "glibc" ]; then
        cp /usr/lib/x86_64-linux-gnu/libnss_* "${target_dir}/usr/lib/"
    elif [ "${install_type,,}" = "musl" ]; then
        cp /usr/lib/libnss_* "${target_dir}/usr/lib/"
    fi

    chroot "${target_dir}" /bin/bash -c "/configure_void.sh"
    # Unmount proc, sys, dev, and run
    echo "Unmounting chroot environment..."
    umount -R "${target_dir}/proc"
    umount -R "${target_dir}/sys"
    umount -R "${target_dir}/dev"
    umount -R "${target_dir}/run"
fi

rm /mnt/configure_void.sh

echo "System configuration complete."
