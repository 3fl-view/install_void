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
read -p "Enter the username for the new user: " user_name

# Function to configure the Void Linux system
cat <<EOF > /mnt/configure_void.sh
# Configure repositories
mkdir -p /etc/xbps.d
echo "repository=$REPO" > /etc/xbps.d/00-repository-main.conf

# Update repositories
xbps-install -Suy

# Configure hostname
echo "voidlinux" > /etc/hostname

# Configure timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# Configure network
echo "Configuring network..."
echo 'config_enp0s3="dhcp"' >> /etc/rc.conf
ln -s /etc/sv/dhcpcd /etc/runit/runsvdir/default/

# Add user
echo "Adding user '$user_name'..."
useradd -m -G wheel -s /bin/bash "$user_name"

# Set passwords
echo "Setting root password..."
passwd
echo "Setting password for $user_name..."
passwd "$user_name"

# Install opendoas and configure it
echo "Installing and configuring opendoas..."
xbps-install -uy opendoas
echo 'permit persist :wheel' > /etc/doas.conf

# Install dracut and efibootmgr
echo "Installing dracut and efibootmgr..."
xbps-install -uy dracut efibootmgr

# Edit dracut configuration
echo 'hostonly="yes"' > /etc/dracut.conf.d/30.conf
echo 'use_fstab="yes"' >> /etc/dracut.conf.d/30.conf
echo 'add_drivers+=" vfat xfs "' >> /etc/dracut.conf.d/30.conf

# Edit /etc/default/efibootmgr-kernel-hook to allow xbps to modify boot entries using efibootmgr
cat <<TEOF > /etc/default/efibootmgr-kernel-hook
MODIFY_EFI_ENTRIES=1
OPTIONS="root=UUID=$(blkid -o value -s UUID /dev/vg_main/root) rw"
DISK="/dev/nvme0n1"
PART=1
TEOF

# Configure kernel and initramfs with xbps-reconfigure
echo "Configuring kernel and initramfs with xbps-reconfigure..."
xbps-reconfigure -fa
EOF

chmod +x /mnt/configure_void.sh

# Perform the chroot
echo "Setting up and entering chroot environment..."
if command -v xchroot >/dev/null 2>&1; then
    echo "Using xchroot to set up and enter chroot..."
    xchroot "${target_dir}" /bin/bash -cx "/configure_void.sh"
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

    chroot "${target_dir}" /bin/bash -c "chmod \+x /configure_void.sh; /configure_void.sh; rm /configure_void.sh"
    # Unmount proc, sys, dev, and run
    echo "Unmounting chroot environment..."
    umount -R "${target_dir}/proc"
    umount -R "${target_dir}/sys"
    umount -R "${target_dir}/dev"
    umount -R "${target_dir}/run"
fi

rm /mnt/configure_void.sh


echo "System configuration complete."
