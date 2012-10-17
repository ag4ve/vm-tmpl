#!/bin/bash

ROOTDIR=/mnt/chroot
NBDDEV=/dev/nbd0
QCOW=./template.qcow2
FSTYPE=ext4
SIZE=10G


if [ $GID -ne 0 || $UID -ne 0 ]; then
    echo "you must be root";
    exit 1;
fi


qemu-img create -f qcow2 $QCOW $SIZE

sudo modprobe nbd

sudo start-stop-daemon --start -b -exec qemu-nbd -- --nocache --connect=$NBDPID $QCOW

sudo nbd-client localhost 1024 $NBDDEV

echo -e "echo \",,L,*\" | sfdisk -D $NBDDEV" | sudo sh
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

