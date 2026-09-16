#!/bin/sh -e
# 03-fetch-firmware.sh - fetch stock Qualcomm firmware + mainline kernel,
# generate the partition table and patch the device tree.
#
# Produces (into $BUILD/files):
#   rpm.mbn, sbl1.mbn, tz.mbn   - stock, unchanged
#   gpt_both0.bin               - generated partition table (see tools/make_gpt.py)
# And patched kernel tree under $BUILD/work/kernel (used by 05-customize-rootfs.sh).

. "$SCRIPT_DIR/../config/build.conf"
. "$SCRIPT_DIR/../config/board.conf"

mkdir -p "$BUILD/work" "$BUILD/files"

# --- stock Qualcomm firmware (rpm/sbl1/tz) ---
FNAME=$(basename "$DB410C_FW_URL")
if [ ! -f "$BUILD/work/$FNAME" ]; then
    echo "==> downloading $DB410C_FW_URL"
    wget --no-verbose -O "$BUILD/work/$FNAME" "$DB410C_FW_URL"
fi
echo "$DB410C_FW_SHA256  $BUILD/work/$FNAME" | sha256sum -c -

if [ ! -f "$BUILD/files/rpm.mbn" ]; then
    unzip -o -j -d "$BUILD/files" "$BUILD/work/$FNAME" \
        "$DB410C_FW_ZIP/rpm.mbn" "$DB410C_FW_ZIP/sbl1.mbn" "$DB410C_FW_ZIP/tz.mbn"
fi

# --- mainline kernel (postmarketOS APK) ---
if [ ! -f "$BUILD/work/$KERNEL_APK" ]; then
    echo "==> downloading $PMOS_MIRROR/$KERNEL_APK"
    wget --no-verbose -O "$BUILD/work/$KERNEL_APK" "$PMOS_MIRROR/$KERNEL_APK"
fi
rm -rf "$BUILD/work/kernel"
mkdir -p "$BUILD/work/kernel"
tar xkzf "$BUILD/work/$KERNEL_APK" -C "$BUILD/work/kernel" \
    --exclude=.PKGINFO --exclude='.SIGN*'

# --- patch device tree (overclock / memory release) ---
DTB="$BUILD/work/kernel/boot/dtbs/qcom/$KERNEL_DTB"
python3 "$SCRIPT_DIR/../tools/patch_dtb.py" \
    --input "$DTB" \
    --output "$DTB" \
    --opp-mhz "$CPU_OPP_MHZ" \
    $([ "$RELEASE_MEMORY" = "1" ] && echo --release-memory || true)

# --- partition table ---
python3 "$SCRIPT_DIR/../tools/make_gpt.py" \
    --total-sectors "$DISK_TOTAL_SECTORS" \
    --output "$BUILD/files/gpt_both0.bin" \
    --info

echo "==> firmware artifacts:"
ls -l "$BUILD"/files/{rpm,sbl1,tz}.mbn "$BUILD/files/gpt_both0.bin"