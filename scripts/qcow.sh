#!/usr/bin/env bash

set -eux

# disable apt prompts
export DEBIAN_FRONTEND=noninteractive

# external variables that must be set
echo vars: $ARCH $BINFMT_ARCH $UBUNTU_VERSION $DOCKER_VERSION $RUNTIME

FILENAME="ubuntu-${UBUNTU_VERSION}-minimal-cloudimg-${ARCH}"

SCRIPT_DIR=$(realpath "$(dirname "$(dirname $0)")")
IMG_DIR="$SCRIPT_DIR/dist/img"
CHROOT_DIR=/mnt/anvil-img

FILE="$IMG_DIR/$FILENAME"

install_dependencies() (
    apt-get update
    apt-get install -y file fdisk libdigest-sha-perl qemu-utils util-linux dosfstools parted
)

convert_file() (
    qemu-img convert -p -f qcow2 -O raw $FILE.img $FILE.raw
)

extract_partition_offset() (
    parted -m -s $FILE.raw unit s print | grep ':ext4:' | grep -v ':boot:' | tail -n1 | cut -d: -f2 | sed 's/s//'
)

extract_boot_partition_offset() (
    parted -m -s $FILE.raw unit s print | grep ':ext4:' | grep 'bls_boot' | cut -d: -f2 | sed 's/s//'
)

mount_partitions() {
    root_offset=$(extract_partition_offset)
    boot_offset=$(extract_boot_partition_offset)
    mkdir -p $CHROOT_DIR
    ROOT_LOOP=$(losetup -f --show -o $(($root_offset * 512)) $FILE.raw)
    BOOT_LOOP=$(losetup -f --show -o $(($boot_offset * 512)) $FILE.raw)
    mount $ROOT_LOOP $CHROOT_DIR
    mkdir -p $CHROOT_DIR/boot
    mount $BOOT_LOOP $CHROOT_DIR/boot
}

unmount_partitions() {
    umount $CHROOT_DIR/boot || true
    umount $CHROOT_DIR || true
    losetup -d $BOOT_LOOP || true
    losetup -d $ROOT_LOOP || true
}

chroot_exec() (
    chroot $CHROOT_DIR "$@"
)

install_packages() (
    # necessary
    chroot_exec mount -t proc proc /proc
    chroot_exec mount -t devpts devpts /dev/pts

    # internet
    chroot_exec mv /etc/resolv.conf /etc/resolv.conf.bak
    echo 'nameserver 1.1.1.1' >$CHROOT_DIR/etc/resolv.conf

    # prepare packages
    chroot_exec apt-get update

    # packages common to all runtimes, to prevent from final purging
    chroot_exec apt-get install -y iptables socat sshfs cloud-init lsb-release python3-apt gnupg curl wget dnsmasq rsync

    # none
    if [ "$RUNTIME" == "none" ]; then
        (
            chroot_exec apt-get install -y htop inetutils-ping dnsutils net-tools netcat-openbsd telnet vim-tiny nano
            chroot_exec apt-get purge -y dmsetup xz-utils
        )
    fi

    # docker
    if [ "$RUNTIME" == "docker" ]; then
        (
            chroot_exec curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
            chroot_exec sh /tmp/get-docker.sh --version $DOCKER_VERSION
            chroot_exec rm /tmp/get-docker.sh
            chroot_exec apt-mark hold docker-ce docker-ce-cli containerd.io
            chroot_exec apt-get purge -y dmsetup xz-utils
        )
    fi

    # containerd
    if [ "$RUNTIME" == "containerd" ]; then
        (
            cd /tmp
            tar Cxfz ${CHROOT_DIR}/usr/local /build/dist/containerd/containerd-utils-${ARCH}.tar.gz
            chroot_exec mkdir -p /opt/cni
            chroot_exec mv /usr/local/libexec/cni /opt/cni/bin
            chroot_exec apt-get purge -y dmsetup xz-utils
        )
    fi

    # incus
    if [ "$RUNTIME" == "incus" ]; then
        (
            chroot_exec mkdir -p /etc/apt/keyrings/
            chroot_exec curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
            zabbly_suite=$(. /etc/os-release && echo "${VERSION_CODENAME}")
            # fallback for distros not yet supported by zabbly
            case "$zabbly_suite" in
                resolute) zabbly_suite="noble" ;;
            esac
            chroot_exec sh -c "cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: ${zabbly_suite}
Components: main
Architectures: \$(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc

EOF"
            chroot_exec apt-get update
            chroot_exec apt-get install -y htop inetutils-ping dnsutils net-tools netcat-openbsd telnet vim-tiny nano
            chroot_exec apt-get install -y incus incus-base incus-client incus-extra incus-ui-canonical zfsutils-linux btrfs-progs lvm2 thin-provisioning-tools
            chroot_exec apt-mark hold incus incus-base incus-client incus-extra incus-ui-canonical zfsutils-linux btrfs-progs lvm2 thin-provisioning-tools
        )
    fi

    chroot_exec apt-get purge -y apport console-setup-linux dbus-user-session liblocale-gettext-perl lxd-agent-loader lxd-installer parted pciutils pollinate python3-gi snapd ssh-import-id
    chroot_exec apt-get purge -y ubuntu-advantage-tools ubuntu-cloud-minimal ubuntu-drivers-common ubuntu-release-upgrader-core unattended-upgrades systemd-resolved

    chroot_exec apt-get autoremove -y
    chroot_exec apt-get clean -y
    chroot_exec sh -c "rm -rf /var/lib/apt/lists/* /var/cache/apt/*"

    # binfmt
    (
        cd /tmp
        tar xfz /build/dist/binfmt/binfmt-${ARCH}.tar.gz
        chown root:root binfmt qemu-i386 qemu-${BINFMT_ARCH}
        mv binfmt qemu-i386 qemu-${BINFMT_ARCH} ${CHROOT_DIR}/usr/bin
    )

    # clean traces
    chroot_exec rm /etc/resolv.conf
    chroot_exec mv /etc/resolv.conf.bak /etc/resolv.conf
    chroot_exec umount /dev/pts
    chroot_exec umount /proc

    # fill partition with zeros, to recover space during compression
    chroot_exec dd if=/dev/zero of=/root/zero || echo done
    chroot_exec rm -f /root/zero
)

extract_kernel() (
    kernel_file=$(ls ${CHROOT_DIR}/boot/vmlinuz-* 2>/dev/null | head -n1)

    if [ -n "$kernel_file" ] && [ -f "$kernel_file" ]; then
        cp "$kernel_file" "${IMG_DIR}/${FILENAME}-${RUNTIME}-vmlinuz"
        shasum -a 512 "${IMG_DIR}/${FILENAME}-${RUNTIME}-vmlinuz" >"${IMG_DIR}/${FILENAME}-${RUNTIME}-vmlinuz.sha512sum"
    fi
)

compress_file() (
    qcow_file="${FILE}-${RUNTIME}"
    qemu-img convert -p -f raw -O qcow2 -c $FILE.raw $qcow_file.qcow2
    dir="$(dirname $qcow_file)"
    filename="$(basename $qcow_file)"
    (cd $dir && shasum -a 512 "${filename}.qcow2" >"${filename}.qcow2.sha512sum")
    rm $FILE.raw
)

# perform all actions
install_dependencies
convert_file
mount_partitions
install_packages
extract_kernel
unmount_partitions
compress_file

# ensure files are readable by non-root users (e.g. GitHub Actions runner)
chmod -R a+r "${IMG_DIR}"
