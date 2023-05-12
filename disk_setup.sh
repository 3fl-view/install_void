#!/bin/bash

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

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# Ask for confirmation before proceeding
cat <<EOF
WARNING! This script is about to COMPLETELY and IRREVOCABLY destroy your current
partition table, and replace it with the configuration you are about to set up.
If you are especially unlucky, this will be done multiple times over. I cannot
stress this enough: THIS CANNOT BE UNDONE!
EOF

read -r -p 'Type "I have said goodbye to all of my hard drive data and know what I am doing": ' confirm
if [ "${confirm^^}" != "I have said goodbye to all of my hard drive data and know what I am doing" ]; then
    echo "Aborted."
    exit 1
fi

# Autogenerating list of drives
disk_list=("$(lsblk -dno NAME)")

echo "Available drives:"
for i in "${!disk_list[@]}"; do
    echo "$((i + 1)): ${disk_list[$i]}"
done

read -rp "Choose the root drive by entering its number (1-${#disk_list[@]}): " root_drive_selection
root_drive="${disk_list[$((root_drive_selection - 1))]}"

echo "You have selected /dev/$root_drive as the root drive."

echo "Select a file system management tool:"
echo "1: LVM"
echo "2: ZFS"
echo "3: BTRFS"

read -rp "Enter your choice (1-3): " vol_manager_choice

case $vol_manager_choice in
    1)
        vol_manager="LVM"
        ;;
    2)
        vol_manager="ZFS"
        ;;
    3)
        vol_manager="BTRFS"
        ;;
    *)
        echo "Invalid selection. Exiting."
        exit 1
        ;;
esac

echo "You have selected $filesystem as your file system management tool."
echo "Root drive: /dev/$root_drive"
echo "Filesystem: $filesystem"

echo "Select disks (enter the numbers separated by spaces, 'a' for all, or 'n' for none):"
select_options=("${disk_list[@]}" "All" "None")
select_indices=$(seq 1 $((${#disk_list[@]} + 2)))

read -rp "Enter your choice(s): "
select disk in "${select_options[@]}"; do
    if [[ " ${select_indices[*]} " =~ $REPLY ]]; then
        if [ "$disk" == "All" ]; then
            disk_pool=("${disk_list[@]}")
        elif [ "$disk" == "None" ]; then
            disk_pool=()
        else
            disk_pool+=("$disk")
        fi
        break
    else
        echo "Invalid choice. Please try again."
    fi
done

# Sorting Drives for optimization
SSD_pool=()
HDD_pool=()
nvme_pool=()
for disk in "${disk_pool[@]}"; do
    if [[ $disk =~ ^sd ]]; then
        is_rota="$(lsblk -dno ROTA "/dev/$disk")"
        if [ "$is_rota" -eq 1 ]; then
            HDD_pool+=("$disk")
        elif [ "$is_rota" -eq 0 ]; then
            SSD_pool+=("$disk")
        fi
    elif [[ $disk =~ ^nvme ]]; then
        nvme_pool+=("$disk")
    fi
done

# TO-DO: make the illusion of choice no longer an illusion
echo "Installing LVM2..."
xbps-install -Sy lvm2 xtools

# Prompt for device names
read -r -p "Enter the device name for the NVMe drive (e.g., /dev/nvme0n1): " nvme_device
read -r -p "Enter the device name for the SATA drive (e.g., /dev/sda): " sata_device

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
mkfs.fat -n BOOT -F32 "${nvme_device}p1"

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
mkfs.xfs -f -m crc=1 -n ftype=1 -l size=64m,su=4096 -d agcount=64 -i size=512 /dev/vg_main/root
mkfs.xfs -f -m crc=1 -n ftype=1 -l size=64m,su=4096 -d agcount=64 -i size=512 /dev/vg_main/home
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
cat <<EOF >>/mnt/etc/fstab
/dev/vg_main/root     /               xfs     defaults,noatime,allocsize=1g,lazytime,discard          0 1
/dev/vg_main/home     /home           xfs     defaults,noatime,allocsize=1g,lazytime,nodiscard        0 0
${nvme_device}p1      /boot           vfat    defaults,umask=0077                                               0 2
/dev/vg_main/swap     none            swap    sw                                                                0 0
EOF

read -r -p "Enter a value for swappiess. The higher your value, the more likely it\
is that your system will use your swap partition. Lower is recommended for\
SSDs. (Range 0-100, Default 10):" swappiness
if [[ $((swappiness)) -gt 0 && $((swappiness)) -lt 100 ]]; then
    echo vm.swappiness=swappiness >/mnt/etc/sysctl.conf
elif [ -z "$(swappiness)" ]; then
    echo vm.swappiness=10 >/mnt/etc/sysctl.conf
fi

echo "Filesystem setup complete."
trap - EXIT
