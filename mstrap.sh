#!/bin/bash

DISK=./template.raw
SIZE=10G
FSTYPE=ext4
MAPPER=sda

# mount point has to conform to schroot.conf
CHROOT=/mnt/chroot

if [ ! -z $1 ]; then
    DISK=$1
fi
if [ ! -z $2 ]; then
    SIZE=$2
fi
if [ ! -z $3 ]; then
    FSTYPE=$3
fi
if [ ! -z $4 ]; then
    MAPPER=$4
fi

echo "File: $DISK"
echo "Size: $SIZE"
echo "FS type: $FSTYPE"
echo "Mount point: $CHROOT"


if [ $UID -eq 0 ]; then
    echo "Please don't run this as root.";
    exit 1;
fi

if [ -e $DISK ]; then
    echo "DISK file already exists";
    exit 1;
fi

if mountpoint -q $CHROOT; then
    echo "Mount point in use. Exiting.";
    exit 1;
fi

echo "Creating qcow2 image...."
dd if=/dev/zero of=$DISK $SIZE

echo "Superuser will be required for some things, hopefully we can cache the password long enough"
sudo -v

echo "Partitioning $DISK"
parted -s $DISK mklabel msdos
parted -s --align=none $DISK mkpart primary 64s 100%

for BLOCK in $(find /dev -name "loop[0-9]*"); do 
    echo "Testing $BLOCK"; 
    if echo "losetup $BLOCK > /dev/null 2>&1" | sudo sh; then 
        echo "$BLOCK OK"; 
        break; 
    fi 
done

if [ -z $BLOCK ]; then
    echo "No unused NBD device found. Exiting.";
    exit 1;
fi

echo "Using loop device $BLOCK"
if ! sudo losetup $BLOCK $DISK; then
    echo "Failed to setup loop device";
    exit 1;
fi

#   logical_start_sector num_sectors target_type target_args
# the formula for num_sectors is <size in gigs> * 1024^3 (gig in bytes) / 512 . 512 because:
#   Devices are created by loading a table that specifies a target 
#   for each sector (512 bytes) in the logical device.
echo "Creating partition table";
if ! echo "echo \"0 $[$SIZE*2097152] linear $BLOCK 0\" | dmsetup create $MAPPER > /dev/null 2>&1" \
        | sudo sh; then
    echo "Failed to create device $MAPPER mapper for $BLOCK";
    exit 1;
fi

echo "Creating mapper device for partition";
if ! echo "kpartx -a /dev/mapper/$MAPPER" | sudo sh; then
    echo "Failed to create device for the /dev/mapper/$MAPPER partition";
    exit 1;
fi

echo "Copying mapper device to /dev/m$MAPPER";
if [ -e /dev/m$MAPPER ] || [ -e /dev/m$MAPPER\1 ]; then
    echo "/dev/m$MAPPER or /dev/m$MAPPER\1 exist";
    exit 1;
else
    sudo ln -s $(readlink -f /dev/mapper/$MAPPER) /dev/m$MAPPER;
    sudo ln -s $(readlink -f /dev/mapper/$MAPPER\1) /dev/m$MAPPER\1;
fi

echo "Creating filesystem";
if ! echo "mkfs -t $FSTYPE /dev/m$MAPPER\1 > /dev/null 2>&1" | sudo sh; then
    echo "Failed to create $FSTYPE on /dev/m$MAPPER";
    exit 1;
fi

if [ -e $CHROOT ]; then
    echo "$CHROOT already exists. Moving on... ";
else
    if ! echo "mkdir -p $CHROOT" | sudo sh; then
        echo "Failed to create chroot directory $CHROOT";
        exit 1;
    fi
fi

if ! echo "mount -o uid=$UID /dev/m$MAPPER\1 $CHROOT" | sudo sh; then
    echo "Failed to mount $BLOCK on $CHROOT. Exiting.";
    exit 1;
fi

sudo mkdir $CHROOT/{dev,proc,sys}
sudo mkdir -p $CHROOT/boot/grub
sudo mkdir -p $CHROOT/root/.ssh

# schroot should take care of this, but i haven't looked into how to get
# multistrap to run inside schroot
sudo mount -t proc proc $CHROOT/proc
sudo mount -t sysfs sysfs $CHROOT/sys
sudo mount --bind /dev $CHROOT/dev
sudo mount -t devpts devpts $CHROOT/dev/pts

sudo multistrap -f ./multistrap.config

sudo rm -f $CHROOT/etc/resolv.conf
sudo rm -f $CHROOT/etc/ssh/*key*
sudo echo $(cat $HOME/.ssh/id_dsa.pub) $USER\@$HOST > $CHROOT/root/.ssh/authorized_keys
cp /etc/apt/apt.conf $CHROOT/etc/apt/apt.conf 2> /dev/null

echo -n         > $CHROOT/etc/network/interfaces
echo -n         > $CHROOT/etc/resolv.conf
echo image      > $CHROOT/etc/hostname
echo -n         > $CHROOT/etc/hosts
echo "Etc/UTC"  > $CHROOT/etc/timezone

schroot -d / -c multistrap locale-gen en_US.UTF-8
schroot -d / -c multistrap dpkg-reconfigure -f noninteractive -a
schroot -d / -c multistrap grub-install $BLOCK
schroot -d / -c multistrap update-grub


echo "Unmounting"
sudo umount $CHROOT
echo "Breaking down NBD"
sudo nbd-client -d $BLOCK

echo "Everything is done"

