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