#!/bin/bash

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# Ask for confirmation before proceeding
read -p "Are you sure you want to run this script? It may lead to data loss. (y/N): " confirm
if [ "${confirm^^}" != "Y" ]; then
    echo "Aborted."
    exit 1
fi

echo "Installing LVM2..."
xbps-install -Sy lvm2

# Prompt for device names
read -p "Enter the device name for the NVMe drive (e.g., /dev/nvme0n1): " nvme_device
read -p "Enter the device name for the SATA drive (e.g., /dev/sda): " sata_device

# Function to clean up in case of failure
cleanup() {
    echo "Unmounting and cleaning up..."
    swapoff /dev/vg_main/swap || true
    umount /mnt/home || true
    umount /mnt/boot || true
    umount /mnt || true
    vgchange -an vg_main || true
    lvremove -f vg_main || true
    vgremove -f vg_main || true
    pvremove -f "$nvme_device"2 || true
    pvremove -f "$sata_device" || true
    wipefs -a "$nvme_device" || true
    wipefs -a "$sata_device" || true

    exit 1
}

trap cleanup EXIT

set -e

# Create partitions on NVMe drive
echo "Creating partitions on $nvme_device..."
(
echo g
echo n
echo
echo
echo +512M
echo t
echo 1
echo n
echo
echo
echo
echo w
) | fdisk "$nvme_device"

# Format the boot partition as FAT32
echo "Formatting boot partition as FAT32..."
mkfs.fat -F32 "${nvme_device}p1"

# Create LVM physical volumes and volume group
echo "Creating LVM physical volumes..."
pvcreate -fy --config "devices { filter = [ \"a|$nvme_device"p2"|\", \"a|$sata_device|\", \"r|.*|\" ] }" "$nvme_device"p2
pvcreate -fy --config "devices { filter = [ \"a|$nvme_device"p2"|\", \"a|$sata_device|\", \"r|.*|\" ] }" "$sata_device"

echo "Creating LVM volume group..."
vgcreate vg_main "$nvme_device"p2 "$sata_device"

# Create logical volumes
echo "Creating logical volumes..."
lvcreate -y -L 32G -n swap vg_main
lvcreate -y -L 400G -n root vg_main
lvcreate -y -l 100%FREE -n home vg_main

# Create filesystems
echo "Creating filesystems..."
mkfs.xfs -f /dev/vg_main/root
mkfs.xfs -f /dev/vg_main/home
mkswap -f /dev/vg_main/swap

# Mount and setup fstab
echo "Mounting filesystems..."
mount /dev/vg_main/root /mnt
mkdir /mnt/boot
mkdir /mnt/home
mount "${nvme_device}p1" /mnt/boot
mount /dev/vg_main/home /mnt/home
swapon /dev/vg_main/swap

echo "Setting up /etc/fstab..."
mkdir -p /mnt/etc
cat <<EOF >> /mnt/etc/fstab
/dev/vg_main/root     /               xfs     defaults        0 0
/dev/vg_main/home     /home           xfs     defaults        0 0
${nvme_device}p1      /boot           vfat    defaults        0 0
/dev/vg_main/swap     swap            swap    defaults        0 0
EOF

echo "Filesystem setup complete."
trap - EXIT

