#!/bin/bash

QCOW=./template.qcow2
SIZE=10G
FSTYPE=ext4

# mount point has to conform to schroot.conf
ROOTDIR=/mnt/chroot

if [ -z $1 ]; then
    QCOW=$1
fi
if [ -z $2 ]; then
    SIZE=$2
fi
if [ -z $3 ]; then
    FSTYPE=$3
fi


if [ $UID -eq 0 ]; then
    echo "Please don't run this as root.";
    exit 1;
fi

if [ -e $QCOW ]; then
    echo "QCOW file already exists";
    exit 1;
fi

if mountpoint -q $ROOTDIR; then
    echo "Mount point in use. Exiting.";
    exit 1;
fi

echo "Creating qcow2 image...."
qemu-img create -f qcow2 $QCOW $SIZE

echo "Superuser will be required for some things, hopefully we can cache the password long enough"
sudo -v

echo "Loading NBD kernel module"
if ! echo "modprobe nbd > /dev/null 2>&1" | sudo sh; then
    echo "Failed to load NBD module. Exiting.";
    exit 1;
fi

for NBDDEV in $(find /dev -name "nbd?"); do 
    echo "Testing $NBDDEV"; 
    if [ -z $(nbd-client -c $NBDDEV) ]; then 
        echo "$NBDDEV OK"; 
        break; 
    fi 
done

if [ -z $NBDDEV ]; then
    echo "No unused NBD device found. Exiting.";
    exit 1;
fi

echo "Starting NBD daemon"
sudo start-stop-daemon --start -b --exec /usr/bin/qemu-nbd -- --nocache $QCOW

echo "Starting NBD client"
sudo nbd-client localhost 1024 $NBDDEV

echo "Partitioning and formatting device."
echo "echo \",,L,*\" | sfdisk -D $NBDDEV" | sudo sh
sudo mkfs -t ext4 $NBDDEV

mkdir -p $CHROOT
sudo mount -o uid=$UID $NBDDEV $CHROOT

mkdir $CHROOT/{dev,proc,sys}
mkdir -p $CHROOT/boot/grub
mkdir -p $CHROOT/root/.ssh

# schroot should take care of this, but i haven't looked into how to get
# multistrap to run inside schroot
sudo mount -t proc proc $CHROOT/proc
sudo mount -t sysfs sysfs $CHROOT/sys
sudo mount --bind /dev $CHROOT/dev
sudo mount -t tmpfs tmpfs $CHROOT/dev/shm
sudo mount -t devpts devpts $CHROOT/dev/pts

multistrap -f ./multistrap.config

rm -f $CHROOT/etc/resolv.conf
rm -f $CHROOT/etc/ssh/*key*
echo $(cat $HOME/.ssh/id_dsa.pub) $USER\@$HOST > $CHROOT/root/.ssh/authorized_keys
cp /etc/apt/apt.conf $CHROOT/etc/apt/apt.conf 2> /dev/null

echo -n         > $CHROOT/etc/network/interfaces
echo -n         > $CHROOT/etc/resolv.conf
echo image      > $CHROOT/etc/hostname
echo -n         > $CHROOT/etc/hosts
echo "Etc/UTC"  > $CHROOT/etc/timezone

schroot -d / -c multistrap locale-gen en_US.UTF-8
schroot -d / -c multistrap dpkg-reconfigure -f noninteractive -a
schroot -d / -c multistrap grub-install --boot-directory=/boot $NBDDEV
schroot -d / -c multistrap update-grub


echo "Unmounting"
sudo umount $CHROOT
echo "Breaking down NBD"
sudo nbd-client -d $NBDDEV

echo "Everything is done"

