#!/bin/bash

ROOTDIR=/mnt/chroot
QCOW=./template.qcow2
FSTYPE=ext4
SIZE=10G

if [ $GID -eq 0 || $UID -eq 0 ]; then
    echo "Please don't run this as root.";
    exit 1;
fi

if [ -z $(mount | grep $ROOTDIR) ]; then
    echo "Mount point in use. Exiting.";
    exit 1;
fi

echo "Creating qcow2 image...."
qemu-img create -f qcow2 $QCOW $SIZE

echo "Superuser will be required for some things, hopefully we can cache the password long enough"
sudo -v

echo "Loading NBD kernel module"
if ! echo "modprobe nbd 2> /dev/null"; then
    echo "Failed to load NBD module. Exiting.";
    exit 1;
fi

for NBDDEV in $(find /dev -name "nbd*"); do 
    echo "Testing $NBDDEV"; 
    if [ -z $(nbd-client -c $TEST) ]; then 
        echo "$NBDDEV OK"; 
        break; 
    fi 
done

if [ -z $NBDDEV ]; then
    echo "No unused NBD device found. Exiting.";
    exit 1;
fi

echo "Starting NBD daemon"
sudo start-stop-daemon --start -b -exec qemu-nbd -- --nocache $QCOW

echo "Starting NBD client"
sudo nbd-client localhost 1024 $NBDDEV

echo "Partitioning and formatting device."
echo "echo \",,L,*\" | sfdisk -D $NBDDEV" | sudo sh
mkfs -t ext4 $NBDDEV

mkdir -p $CHROOT
mount -o uid=$UID $NBDDEV $CHROOT

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


sudo umount $CHROOT
sudo nbd-client -d $NBDDEV

