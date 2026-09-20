#!/bin/sh -e
# 02-build-bootloader.sh - build qhypstub + lk1st + test-signed mbn images.
#
# Produces (into $BUILD/files):
#   aboot.mbn  - lk1st primary bootloader (msm8916, uz801-v3 compatible),
#                test-signed with qtestsign
#   hyp.mbn    - qhypstub hypervisor stub, test-signed
#
# rpm/sbl1/tz come from the stock Qualcomm firmware in 03-fetch-firmware.sh.

. "$SCRIPT_DIR/../config/build.conf"
. "$SCRIPT_DIR/../config/board.conf"

mkdir -p "$BUILD/src" "$BUILD/files"

clone() { # dir url
    if [ ! -d "$BUILD/src/$1" ]; then
        git clone --depth 1 "$2" "$BUILD/src/$1"
    fi
}

clone qhypstub https://github.com/msm8916-mainline/qhypstub
clone lk2nd    https://github.com/msm8916-mainline/lk2nd
clone qtestsign https://github.com/msm8916-mainline/qtestsign

# --- qhypstub (hyp.mbn) ---
make -C "$BUILD/src/qhypstub" CROSS_COMPILE=aarch64-linux-gnu-

# --- lk1st (aboot.mbn) ---
# Reduce eMMC HS200 speed - old/recycled flash chips can fail at full speed.
if ! grep -q 'USE_TARGET_HS200_CAPS' "$BUILD/src/lk2nd/project/lk1st-msm8916.mk"; then
    echo 'DEFINES += USE_TARGET_HS200_CAPS=1' >> "$BUILD/src/lk2nd/project/lk1st-msm8916.mk"
fi

# --- lk2nd-rproc (runtime memory release) ---
# Ports lk2nd-rproc.c (commit 64d3c6c) onto the current DEV_TREE_UPDATE() hook.
# It disables the modem remoteproc and deletes its /reserved-memory carve-out
# right before the kernel is started, so the modem RAM becomes general RAM.
# The file lands in lk2nd/util/, whose rules.mk uses a stable LOCAL_DIR
# (appending to lk2nd/rules.mk would inherit lk2nd/util via the include).
mkdir -p "$BUILD/src/lk2nd/lk2nd/util"
cp "$SCRIPT_DIR/../tools/lk2nd-rproc/lk2nd-rproc.c" \
    "$BUILD/src/lk2nd/lk2nd/util/lk2nd-rproc.c"
if ! grep -q 'lk2nd-rproc.o' "$BUILD/src/lk2nd/lk2nd/util/rules.mk"; then
    printf '\nOBJS += $(LOCAL_DIR)/lk2nd-rproc.o\n' >> "$BUILD/src/lk2nd/lk2nd/util/rules.mk"
fi
# RELEASE_MEMORY=1 -> RPROC_MODE_NO_MODEM (free the modem carve-out at runtime).
if [ "$RELEASE_MEMORY" = "1" ]; then
    if ! grep -q 'LK2ND_RPROC_MODE' "$BUILD/src/lk2nd/project/lk1st-msm8916.mk"; then
        echo 'DEFINES += LK2ND_RPROC_MODE=RPROC_MODE_NO_MODEM' \
            >> "$BUILD/src/lk2nd/project/lk1st-msm8916.mk"
    fi
fi

make -C "$BUILD/src/lk2nd" \
    LK2ND_BUNDLE_DTB="$LK1ST_BUNDLE_DTB" \
    LK2ND_COMPATIBLE="$LK1ST_COMPATIBLE" \
    TOOLCHAIN_PREFIX=arm-none-eabi- \
    lk1st-msm8916

# --- test signing (qtestsign, Python) ---
python3 "$BUILD/src/qtestsign/qtestsign.py" hyp \
    "$BUILD/src/qhypstub/qhypstub.elf" \
    -o "$BUILD/files/hyp.mbn"
python3 "$BUILD/src/qtestsign/qtestsign.py" aboot \
    "$BUILD/src/lk2nd/build-lk1st-msm8916/emmc_appsboot.mbn" \
    -o "$BUILD/files/aboot.mbn"

ls -l "$BUILD/files/aboot.mbn" "$BUILD/files/hyp.mbn"