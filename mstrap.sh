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

sudo sh << SU || exit 1

    # If chroot config exists, lets see if we want to make a backup
    if [ -e /etc/schroot/chroot.d/multistrap.conf ]; then
        echo "Found chroot config. Make backup?";
        read ANS;
        if [ $(echo $ANS | awk '{ print tolower(substr($0,1,1)) }') != 'y' ]; then
            cp -f /etc/schroot/chroot.d/multistrap.conf ./schroot.bak-$(date +%Y%m%d%H%M%S);
        fi
    fi

    # create schroot config file for multistrap environment
    cat << SCHROOTCONF | sed -e 's/^ *//g' > /etc/schroot/chroot.d/multistrap.conf
        [multistrap]
        description=Multistrap chroot config
        directory=$CHROOT
        personality=linux32
        root-users=$(whoami)
        type=plain
        users=$(whoami)
    SCHROOTCONF

    # find free loop device
    for BLOCK in $(find /dev -name "loop[0-9]*"); do 
        echo "Testing $BLOCK"; 
        if losetup $BLOCK > /dev/null 2>&1; then 
            echo "$BLOCK OK"; 
            break; 
        fi 
    done
    
    if [ -z $BLOCK ]; then
        echo "No unused NBD device found. Exiting.";
        exit 1;
    fi
    
    # Attach image to loop device
    echo "Using loop device $BLOCK"
    if ! losetup $BLOCK $DISK; then
        echo "Failed to setup loop device";
        exit 1;
    fi
    
    #   logical_start_sector num_sectors target_type target_args
    # the formula for num_sectors is <size in gigs> * 1024^3 (gig in bytes) / 512 . 512 because:
    #   Devices are created by loading a table that specifies a target 
    #   for each sector (512 bytes) in the logical device.
    echo "Creating partition table";
    if ! echo "0 $[$SIZE*2097152] linear $BLOCK 0" | dmsetup create $MAPPER > /dev/null 2>&1; \
            then
        echo "Failed to create device $MAPPER mapper for $BLOCK";
        exit 1;
    fi
    
    echo "Creating mapper device for partition";
    if ! kpartx -a /dev/mapper/$MAPPER; then
        echo "Failed to create device for the /dev/mapper/$MAPPER partition";
        exit 1;
    fi
    
    echo "Copying mapper device to /dev/m$MAPPER";
    if [ -e /dev/m$MAPPER ] || [ -e /dev/m$MAPPER\1 ]; then
        echo "/dev/m$MAPPER or /dev/m$MAPPER\1 exist";
        exit 1;
    else
        ln -s $(readlink -f /dev/mapper/$MAPPER) /dev/m$MAPPER;
        ln -s $(readlink -f /dev/mapper/$MAPPER\1) /dev/m$MAPPER\1;
    fi
    
    echo "Creating filesystem";
    if ! mkfs -t $FSTYPE /dev/m$MAPPER\1 > /dev/null 2>&1; then
        echo "Failed to create $FSTYPE on /dev/m$MAPPER";
        exit 1;
    fi
    
    if [ -e $CHROOT ]; then
        echo "$CHROOT already exists. Moving on... ";
    else
        if ! mkdir -p $CHROOT; then
            echo "Failed to create chroot directory $CHROOT";
            exit 1;
        fi
    fi
    
    if ! echo "mount -o uid=$UID /dev/m$MAPPER\1 $CHROOT"; then
        echo "Failed to mount $BLOCK on $CHROOT. Exiting.";
        exit 1;
    fi
    
    mkdir $CHROOT/{dev,proc,sys}
    mkdir -p $CHROOT/boot/grub
    mkdir -p $CHROOT/root/.ssh
    
    # schroot should take care of this, but i haven't looked into how to get
    # multistrap to run inside schroot
    mount -t proc proc $CHROOT/proc
    mount -t sysfs sysfs $CHROOT/sys
    mount --bind /dev $CHROOT/dev
    
    multistrap -f ./multistrap.conf
SU

echo $(cat $HOME/.ssh/id_dsa.pub) $USER\@$HOST > $CHROOT/root/.ssh/authorized_keys
cp /etc/apt/apt.conf $CHROOT/etc/apt/apt.conf 2> /dev/null

schroot -d / -u root -c multistrap sh << CHROOT || exit 1
    rm -f /etc/resolv.conf
    rm -f /etc/ssh/*key*
    
    echo -n         > /etc/network/interfaces
    echo -n         > /etc/resolv.conf
    echo image      > /etc/hostname
    echo -n         > /etc/hosts
    echo "Etc/UTC"  > /etc/timezone

    locale-gen en_US.UTF-8
    dpkg-reconfigure -f noninteractive -a

    BOOTDIR=/boot/grub
    UUID=$(blkid -p -o value -s UUID /dev/m$MAPPER\1)

    cp /usr/lib/grub/i386-pc/* $BOOTDIR

    echo "(hd0) /dev/m$MAPPER" > $BOOTDIR/device.map

    echo "search.fs_uuid $UUID root " > $BOOTDIR/load.cfg
    echo 'set prefix=(hd0,1)/boot/grub' >> $BOOTDIR/load.cfg
    echo 'set root=(hd0,1)' >> $BOOTDIR/load.cfg

    cat << BEGIN_GRUB_CFG | sed -e 's/^ *//g' > $BOOTDIR/grub.cfg
        set default=0
        set timeout=5
        insmod part_msdos
        insmod ext2
    BEGIN_GRUB_CFG 

    for i in /boot/vmlinu[xz]-* /vmlinu[xz]-* ; do
        KVER=$(basename $i | cut -d- -f2-)
        KDIR=$(dirname $i)
        DEBVER=$(cat /etc/debian_version | tr -d '\n')

        if [ -e $KDIR/initrd.img-$KVER ]; then
            cat << GRUBCFG | sed -e 's/^ *//g' >> $BOOTDIR/grub.cfg
                menuentry "DEBIAN $DEBVER Linux $KVER" {
                    set root=(hd0,1)
                    search --no-floppy --fs-uuid --set $UUID
                    linux $i root=UUID=$UUID ro quiet splash
                    initrd $KDIR/initrd.img-$KVER
                }
            GRUBCFG
        fi
    done

    grub-setup -b boot.img -c core.img -r "(hd0,1)" --directory=$BOOTDIR \
        --device-map=$BOOTDIR/device.map "(hd0)"

CHROOT


echo "Unmounting"
sudo umount $CHROOT

echo "Everything is done"

