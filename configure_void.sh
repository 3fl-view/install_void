#!/bin/bash

if [ "$(stat -c %d:%i /)" == "$(stat -c %d:%i /proc/1/root/.)" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: The script must be run as root" >&2
        exit 1
    fi
else
    echo "Error: The script must be run in a chroot environment" >&2
    exit 2
fi

# Configure repositories
mkdir -p /etc/xbps.d
echo "repository=$REPO" >/etc/xbps.d/00-repository-main.conf

# Update repositories
xbps-install -Suy

# Configure hostname
echo "voidlinux" >/etc/hostname

# Configure timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# Configure network
echo "Configuring network..."
echo 'config_enp0s3="dhcp"' >>/etc/rc.conf
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
cat <<EOF >/etc/doas.conf
permit persist :wheel
permit nopass keepenv :wheel cmd xbps-install
permit nopass keepenv :wheel cmd xbps-remove
EOF

# Install dracut and efibootmgr
echo "Installing dracut and efibootmgr..."
xbps-install -uy dracut efibootmgr

# Edit dracut configuration
echo 'hostonly="yes"' >/etc/dracut.conf.d/30.conf
echo 'use_fstab="yes"' >>/etc/dracut.conf.d/30.conf

# Edit /etc/default/efibootmgr-kernel-hook to allow xbps to modify boot entries using efibootmgr
cat <<EOF >/etc/default/efibootmgr-kernel-hook
MODIFY_EFI_ENTRIES=1
OPTIONS="root=/dev/vg_main/root loglevel 4"
DISK="/dev/nvme0n1"
PART=1
EOF

# Configure kernel and initramfs with xbps-reconfigure
echo "Configuring kernel and initramfs with xbps-reconfigure..."
xbps-reconfigure -fa
