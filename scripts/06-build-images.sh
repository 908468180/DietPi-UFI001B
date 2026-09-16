#!/bin/sh -e
# 06-build-images.sh - build boot/rootfs raw images and the flash package.

. "$SCRIPT_DIR/../config/build.conf"
. "$SCRIPT_DIR/../config/board.conf"

ROOTFS="$BUILD/work/rootfs"
WORK="$BUILD/work"

echo "==> assembling /boot (64 MiB ext2)"
rm -f "$WORK/boot.raw"
truncate -s 67108864 "$WORK/boot.raw"
mkfs.ext2 -q -q -L boot -d "$ROOTFS/boot" "$WORK/boot.raw" 2>/dev/null || {
    # older e2fsprogs: fill via loop mount
    mkfs.ext2 -q -q -L boot "$WORK/boot.raw"
    mkdir -p "$WORK/bootmnt"
    mount -o loop "$WORK/boot.raw" "$WORK/bootmnt"
    cp -a "$ROOTFS/boot/." "$WORK/bootmnt/"
    umount "$WORK/bootmnt"
}

echo "==> assembling rootfs (1.5 GiB ext4)"
mv "$ROOTFS/boot" "$WORK/boot-part"
rm -f "$WORK/rootfs.raw"
truncate -s 1610612736 "$WORK/rootfs.raw"
mkfs.ext4 -q -q -d "$ROOTFS" -E discard=on "$WORK/rootfs.raw" 2>/dev/null || {
    mkfs.ext4 -q -q "$WORK/rootfs.raw"
    mkdir -p "$WORK/rootmnt"
    mount -o loop "$WORK/rootfs.raw" "$WORK/rootmnt"
    cp -a "$ROOTFS/." "$WORK/rootmnt/"
    umount "$WORK/rootmnt"
}
mv "$WORK/boot-part" "$ROOTFS/boot"

echo "==> sparse images"
img2simg "$WORK/boot.raw" "$BUILD/files/boot.bin"
img2simg "$WORK/rootfs.raw" "$BUILD/files/rootfs.bin"

# rootfs label: DietPi uses LABEL=rootfs? keep plain, PARTUUID is used.
echo "==> checksums"
( cd "$BUILD/files" && sha256sum aboot.mbn hyp.mbn rpm.mbn sbl1.mbn tz.mbn \
    gpt_both0.bin boot.bin rootfs.bin > SHA256SUMS )

echo "==> flash package:"
ls -l "$BUILD"/files