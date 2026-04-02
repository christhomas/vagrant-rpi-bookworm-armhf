#!/usr/bin/env bash
#
# build-linux.sh — Build the entire Vagrant box on Linux
#
# Runs directly on Linux (CI runner or build VM). Handles everything:
#   1. Download RPi OS image
#   2. Convert to qcow2
#   3. Download QEMU-compatible kernel and extract vmlinuz + modules
#   4. Mount image via nbd and chroot to customize (vagrant user, SSH, etc.)
#   5. Install kernel modules on disk for post-boot driver loading
#   6. Build initrd with virtio drivers
#   7. Package .box file
#
# Output: ${PROJECT}/work/rpi-armhf.box
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="${BUILD_PROJECT:-$SCRIPT_DIR}"
WORK="/tmp/box-build"
OUTPUT="${PROJECT}/work"
NBD_DEV="/dev/nbd2"

# ─── Configuration ───────────────────────────────────────────────────────────────

RPI_IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2024-11-19/2024-11-19-raspios-bookworm-armhf-lite.img.xz"
KERNEL_DEB_URL="http://ftp.us.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-42-armmp-lpae_6.1.159-1_armhf.deb"

# ─── Helpers ─────────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
die()   { echo "FATAL: $*" >&2; exit 1; }

MNT_ROOT="${WORK}/mnt-root"

cleanup() {
    info "Cleaning up..."
    set +e
    pkill -9 gpg-agent 2>/dev/null || true
    sleep 1
    for mp in dev/pts dev/shm dev proc sys run; do
        umount -l "$MNT_ROOT/$mp" 2>/dev/null || true
    done
    umount -l "$MNT_ROOT" 2>/dev/null || true
    qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    set -e
}
trap cleanup EXIT

# ─── Install build dependencies ──────────────────────────────────────────────────

info "Installing build dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq qemu-utils qemu-user-static binfmt-support kmod e2fsprogs fdisk curl binutils xz-utils zstd python3 initramfs-tools xxd
modprobe nbd max_part=8 || true

# Enable binfmt for cross-architecture chroot (armhf on amd64/aarch64)
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "armv7l" ]]; then
    info "Enabling binfmt for ARM chroot on ${HOST_ARCH}..."
    update-binfmts --enable qemu-arm 2>/dev/null || true
fi

mkdir -p "$WORK" "$OUTPUT"

# ═════════════════════════════════════════════════════════════════════════════════
# Phase 1: Download and prepare RPi OS image
# ═════════════════════════════════════════════════════════════════════════════════

IMAGE_BASENAME="$(basename "$RPI_IMAGE_URL")"
COMPRESSED="${WORK}/${IMAGE_BASENAME}"
RAW="${WORK}/${IMAGE_BASENAME%.xz}"
QCOW2="${WORK}/box.img"

info "Phase 1: Download and prepare RPi OS image"

if [[ ! -f "$COMPRESSED" ]]; then
    info "Downloading: $RPI_IMAGE_URL"
    curl -L -o "$COMPRESSED" "$RPI_IMAGE_URL"
else
    info "Using cached: $COMPRESSED"
fi

if [[ ! -f "$RAW" ]]; then
    info "Decompressing..."
    xz -dk "$COMPRESSED"
fi

info "Converting to qcow2..."
qemu-img convert -f raw -O qcow2 "$RAW" "$QCOW2"

# ═════════════════════════════════════════════════════════════════════════════════
# Phase 2: Download QEMU-compatible kernel
# ═════════════════════════════════════════════════════════════════════════════════

KERNEL_DEB="${WORK}/kernel.deb"
KERNEL_EXTRACT="${WORK}/kernel-extract"

info "Phase 2: Download kernel"

if [[ ! -f "$KERNEL_DEB" ]]; then
    info "Downloading Debian armmp-lpae kernel..."
    curl -fsSL -o "$KERNEL_DEB" "$KERNEL_DEB_URL"
fi

rm -rf "$KERNEL_EXTRACT"
mkdir -p "$KERNEL_EXTRACT"
(cd "$KERNEL_EXTRACT" && ar x "$KERNEL_DEB" && tar xf data.tar.xz)

VMLINUZ=$(ls "${KERNEL_EXTRACT}"/boot/vmlinuz-*-armmp-lpae 2>/dev/null | sort -V | tail -1)
[[ -f "$VMLINUZ" ]] || die "vmlinuz not found in kernel package"

KVER=$(basename "$VMLINUZ" | sed 's/vmlinuz-//')
info "Kernel: $KVER"

# ═════════════════════════════════════════════════════════════════════════════════
# Phase 3: Customize image via nbd + chroot
# ═════════════════════════════════════════════════════════════════════════════════

info "Phase 3: Customize image"

modprobe nbd max_part=8
qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
sleep 2

info "Connecting image to $NBD_DEV..."
qemu-nbd --connect="$NBD_DEV" "$QCOW2"
sleep 3

for i in $(seq 1 10); do
    [[ -b "${NBD_DEV}p2" ]] && break
    sleep 1
done
[[ -b "${NBD_DEV}p2" ]] || die "Partition ${NBD_DEV}p2 did not appear"

info "Partitions:"
lsblk "$NBD_DEV"

info "Mounting filesystems..."
mkdir -p "$MNT_ROOT"
mount "${NBD_DEV}p2" "$MNT_ROOT"

mount -t proc  proc  "$MNT_ROOT/proc"
mount -t sysfs sysfs "$MNT_ROOT/sys"
mount --bind /dev     "$MNT_ROOT/dev"
mount --bind /dev/pts "$MNT_ROOT/dev/pts"
mount --bind /run     "$MNT_ROOT/run"

# Set up qemu-arm-static for armhf chroot
QEMU_ARM="$(command -v qemu-arm-static)"
cp "$QEMU_ARM" "$MNT_ROOT/usr/bin/qemu-arm-static"

cp /etc/resolv.conf "$MNT_ROOT/etc/resolv.conf"

# Make /boot/firmware mount non-fatal (not present in QEMU virt machine)
if [[ -f "$MNT_ROOT/etc/fstab" ]]; then
    sed -i '/\/boot\/firmware/s/defaults/defaults,nofail/' "$MNT_ROOT/etc/fstab"
fi

# Register binfmt_misc for ARM if not already registered
if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-arm ]]; then
    info "Registering binfmt_misc for ARM..."
    mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    echo ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff:/usr/bin/qemu-arm-static:F' \
        > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
fi

info "Running chroot customization..."
cp "${PROJECT}/chroot-rpi.sh" "$MNT_ROOT/tmp/chroot-rpi.sh"
chroot "$MNT_ROOT" /bin/bash /tmp/chroot-rpi.sh
rm -f "$MNT_ROOT/tmp/chroot-rpi.sh"

# ─── Install kernel modules on disk for post-boot driver loading ─────────────────

info "Installing kernel modules ($KVER) to disk..."
mkdir -p "$MNT_ROOT/lib/modules/${KVER}"
cp -r "${KERNEL_EXTRACT}/lib/modules/${KVER}/." "$MNT_ROOT/lib/modules/${KVER}/"

if [[ ! -f "$MNT_ROOT/lib/modules/${KVER}/kernel/drivers/block/virtio_blk.ko" ]]; then
    info "  Fixing missing virtio_blk.ko on disk..."
    mkdir -p "$MNT_ROOT/lib/modules/${KVER}/kernel/drivers/block"
    cp "${KERNEL_EXTRACT}/lib/modules/${KVER}/kernel/drivers/block/virtio_blk.ko" \
       "$MNT_ROOT/lib/modules/${KVER}/kernel/drivers/block/"
fi

chroot "$MNT_ROOT" depmod "${KVER}" 2>/dev/null || true

# ─── Build initrd inside chroot (correct architecture binaries) ──────────────────

info "Phase 4: Build initrd inside chroot"

INITRD="${WORK}/initrd.img"
CONFFILE="${KERNEL_EXTRACT}/boot/config-${KVER}"
cp "${CONFFILE}" "$MNT_ROOT/boot/config-${KVER}"

chroot "$MNT_ROOT" /bin/bash -e <<INITRDEOF
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq initramfs-tools 2>/dev/null || true

for mod in virtio virtio_ring virtio_pci virtio_blk virtio_net virtio_scsi virtiofs ext4; do
    echo "\$mod" >> /etc/initramfs-tools/modules
done

mkdir -p /etc/initramfs-tools/hooks
cat > /etc/initramfs-tools/hooks/virtio <<'HOOKEOF'
#!/bin/sh
set -e
. /usr/share/initramfs-tools/hook-functions
manual_add_modules virtio virtio_ring virtio_pci virtio_blk virtio_net virtio_scsi
HOOKEOF
chmod +x /etc/initramfs-tools/hooks/virtio

depmod -a "${KVER}"
mkinitramfs -o /tmp/initrd.img "${KVER}"
INITRDEOF

cp "$MNT_ROOT/tmp/initrd.img" "/tmp/initrd-base.img"
rm -f "$MNT_ROOT/tmp/initrd.img" "$MNT_ROOT/boot/config-${KVER}"

# ─── Patch initrd with insmod commands (host-side, just file editing) ────────────

info "Patching initrd with insmod commands..."
INITRD_WORK=/tmp/initrd-patch
rm -rf "$INITRD_WORK"
mkdir -p "$INITRD_WORK"
cd "$INITRD_WORK"

MAGIC=$(xxd -l 4 -p /tmp/initrd-base.img)
case "$MAGIC" in
    28b52ffd) zstd -d -c /tmp/initrd-base.img | cpio -id 2>/dev/null ;;
    1f8b*)    gzip -d -c /tmp/initrd-base.img | cpio -id 2>/dev/null ;;
    *)        cpio -id < /tmp/initrd-base.img 2>/dev/null ;;
esac

if [[ -d "${INITRD_WORK}/usr/lib/modules/${KVER}" ]]; then
    INITRD_MODPATH="usr/lib/modules/${KVER}/kernel/drivers"
else
    INITRD_MODPATH="lib/modules/${KVER}/kernel/drivers"
fi

SRCPATH="${KERNEL_EXTRACT}/lib/modules/${KVER}/kernel/drivers"
MODULES="virtio/virtio.ko virtio/virtio_ring.ko virtio/virtio_pci.ko
         virtio/virtio_pci_modern_dev.ko virtio/virtio_pci_legacy_dev.ko
         virtio/virtio_mmio.ko block/virtio_blk.ko net/virtio_net.ko"

for mod in $MODULES; do
    if [[ ! -f "${INITRD_WORK}/${INITRD_MODPATH}/${mod}" ]] && [[ -f "${SRCPATH}/${mod}" ]]; then
        info "  Injecting ${mod}"
        mkdir -p "${INITRD_WORK}/$(dirname "${INITRD_MODPATH}/${mod}")"
        cp "${SRCPATH}/${mod}" "${INITRD_WORK}/${INITRD_MODPATH}/${mod}"
    fi
done

if ! grep -q "Force-load virtio" "${INITRD_WORK}/init" 2>/dev/null; then
    python3 -c "
with open('${INITRD_WORK}/init') as f:
    content = f.read()

insmod = '''# Force-load virtio drivers for QEMU
MODBASE=/${INITRD_MODPATH}
/sbin/insmod \${MODBASE}/virtio/virtio.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/virtio/virtio_ring.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/virtio/virtio_pci_modern_dev.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/virtio/virtio_pci_legacy_dev.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/virtio/virtio_pci.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/block/virtio_blk.ko 2>/dev/null || true
/sbin/insmod \${MODBASE}/net/virtio_net.ko 2>/dev/null || true
'''

content = content.replace('load_modules', insmod + 'load_modules', 1)

with open('${INITRD_WORK}/init', 'w') as f:
    f.write(content)
"
fi

info "Repacking initrd..."
cd "$INITRD_WORK"
find . | cpio -o -H newc 2>/dev/null | zstd -f -o "$INITRD"

rm -rf /tmp/initrd-base.img "$INITRD_WORK"

# ─── Unmount ─────────────────────────────────────────────────────────────────────

info "Unmounting..."
for mp in dev/pts dev/shm dev proc sys run; do
    umount -l "$MNT_ROOT/$mp" 2>/dev/null || true
done
umount "$MNT_ROOT"
qemu-nbd --disconnect "$NBD_DEV"
sleep 2

# ═════════════════════════════════════════════════════════════════════════════════
# Phase 5: Package .box
# ═════════════════════════════════════════════════════════════════════════════════

info "Phase 5: Package .box"

BOX_DIR="${WORK}/box-contents"
rm -rf "$BOX_DIR"
mkdir -p "$BOX_DIR"

info "Compacting qcow2..."
qemu-img convert -O qcow2 -c "$QCOW2" "$BOX_DIR/box.img"

cp "$VMLINUZ" "$BOX_DIR/vmlinuz"
cp "$INITRD"  "$BOX_DIR/initrd.img"

cat > "$BOX_DIR/metadata.json" <<'EOF'
{
  "provider": "qemu-customkernel",
  "format": "qcow2",
  "architecture": "arm"
}
EOF

cat > "$BOX_DIR/Vagrantfile" <<'VEOF'
Vagrant.configure("2") do |config|
  config.vm.provider :qemu do |qe|
    qe.arch = "arm"
    qe.machine = "virt"
    qe.cpu = "cortex-a7"
    qe.memory = "512M"

    box_dir = File.dirname(__FILE__)
    qe.extra_qemu_args = [
      "-kernel", "#{box_dir}/vmlinuz",
      "-initrd", "#{box_dir}/initrd.img",
      "-append", "root=/dev/vda2 console=ttyAMA0",
    ]
  end
end
VEOF

info "Creating .box archive..."
(cd "$BOX_DIR" && tar czf "${OUTPUT}/rpi-armhf.box" metadata.json Vagrantfile box.img vmlinuz initrd.img)

BOX_SIZE=$(du -h "${OUTPUT}/rpi-armhf.box" | cut -f1)
info "Box ready: ${OUTPUT}/rpi-armhf.box ($BOX_SIZE)"
