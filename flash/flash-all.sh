#!/bin/bash -e
# flash-all.sh - flash the dietpi-ufi001b image to an UFI001B.
#
# Requires: edl (https://github.com/bkerler/edl), fastboot (`sudo apt install fastboot`)
# Usage:    bash flash-all.sh [--backup]
# Run with --backup first to store fsc/fsg/modem/modemst1/modemst2/persist/sec
# from the ORIGINAL Android system before overwriting anything.
# Files are expected in ./files (build artifact) or given as $FILES_DIR.

FILES_DIR=${FILES_DIR:-"./files"}

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }
}
require edl
require fastboot

for f in "$FILES_DIR"/{aboot,hyp,rpm,sbl1,tz}.mbn \
         "$FILES_DIR/gpt_both0.bin" \
         "$FILES_DIR/boot.bin" "$FILES_DIR/rootfs.bin"; do
    [ -f "$f" ] || { echo "missing image file: $f"; exit 1; }
done

if [ "${1:-}" = "--backup" ] || [ ! -f "$FILES_DIR/modem.bin" ]; then
    echo "[1/5] Backing up original partitions..."
    [ -f "$FILES_DIR/modem.bin" ] || mkdir -p "$FILES_DIR"
    for n in fsc fsg modem modemst1 modemst2 persist sec; do
        echo "  - $n"
        edl r "$n" "$FILES_DIR/$n.bin" 2>/dev/null || true
    done
else
    echo "[1/5] Backup found, skipping"
fi

echo "[2/5] Installing custom bootloader (lk1st)..."
edl w aboot "$FILES_DIR/aboot.mbn" 2>/dev/null
edl e boot 2>/dev/null
edl reset 2>/dev/null
echo "  Waiting for device to enter fastboot..."
sleep 5

echo "[3/5] Flashing partition table + firmware..."
fastboot flash partition "$FILES_DIR/gpt_both0.bin"
fastboot flash aboot "$FILES_DIR/aboot.mbn"
fastboot flash hyp "$FILES_DIR/hyp.mbn"
fastboot flash rpm "$FILES_DIR/rpm.mbn"
fastboot flash sbl1 "$FILES_DIR/sbl1.mbn"
fastboot flash tz "$FILES_DIR/tz.mbn"
fastboot flash boot "$FILES_DIR/boot.bin"
echo "  Firmware done."

echo "[4/5] Flashing rootfs..."
fastboot flash rootfs "$FILES_DIR/rootfs.bin"
echo "  Rootfs done."

echo "[5/5] Restoring modem partitions..."
for n in fsc fsg modem modemst1 modemst2 persist sec; do
    echo "  - $n"
    fastboot flash "$n" "$FILES_DIR/$n.bin" 2>/dev/null || true
done

echo ""
echo "=============================="
echo "  Flash complete! Rebooting..."
echo "=============================="
fastboot reboot 2>/dev/null

echo ""
echo "Device will boot DietPi. SSH in via 192.168.68.1 (RNDIS)."
