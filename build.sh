#!/bin/bash -e
# build.sh - dietpi-ufi001b orchestrator.
# rebuild
#
# Produces a flash package in out/files/:
#   aboot.mbn hyp.mbn (custom bootloader)  rpm/sbl1/tz.mbn (stock)
#   gpt_both0.bin     boot.bin rootfs.bin (sparse)          SHA256SUMS
#
# REQUIRES a native arm64 host (GitHub Actions ubuntu-22.04-arm,
# or an arm64 CI/self-hosted machine).

cd "$(dirname "$0")"
REPO_DIR="$PWD"
SCRIPT_DIR="$REPO_DIR/scripts"
export SCRIPT_DIR REPO_DIR

. config/build.conf
. config/board.conf

BUILD="$PWD/build"
OUT="$PWD/out"
export BUILD OUT

# Add the DietPi first-run password to build.conf defaults if not set.
DIETPI_PASSWORD=${DIETPI_PASSWORD:-dietpi}
export DIETPI_PASSWORD

echo "=== dietpi-ufi001b build ==="
echo "board:          $BOARD_NAME ($BOARD)"
echo "kernel dtb:     $KERNEL_DTB (cpu ${CPU_OPP_MHZ}MHz, release_memory=${RELEASE_MEMORY})"
echo "archive:        out/files/"
echo ""

rm -rf "$OUT"
mkdir -p "$BUILD" "$OUT/files"

run() { # name, script
    echo "--- [$(basename "$2")] $1"
    "$2" || { echo "ERROR: $1 failed (exit $?)"; exit 1; }
    echo ""
}

run "deps"                   "$SCRIPT_DIR/01-deps.sh"
run "bootloader"             "$SCRIPT_DIR/02-build-bootloader.sh"
run "firmware/gpt/dtb"       "$SCRIPT_DIR/03-fetch-firmware.sh"
run "dietpi conversion"      "$SCRIPT_DIR/04-convert-dietpi.sh"
run "rootfs customization"   "$SCRIPT_DIR/05-customize-rootfs.sh"
run "images"                 "$SCRIPT_DIR/06-build-images.sh"

echo "=== build finished ==="
cp -a "$BUILD"/files/. "$OUT"/files/
cd "$OUT"/files && ls -lh
echo ""
echo "Flash it: see out/files/README-FLASH and the flash/ directory."