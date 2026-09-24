#!/bin/sh -e
# 05-customize-rootfs.sh - install device packages after the DietPi conversion.
#
# dietpi-installer resets all APT packages (marks every package as
# auto-installed then autoremoves the leftovers), so every board-specific
# package must be installed AFTER the conversion - that is this step.

. "$SCRIPT_DIR/../config/build.conf"
. "$SCRIPT_DIR/../config/board.conf"

ROOTFS="$BUILD/work/rootfs"
[ -d "$ROOTFS/boot/dietpi" ] || [ -d "$ROOTFS/DietPi" ] \
    || { echo "no converted DietPi rootfs at $ROOTFS"; exit 1; }
[ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ] \
    || { echo "05 requires a native arm64 host"; exit 1; }

# chrooted apt needs DNS (shared host netns); the installer may have rewritten it.
rm -f "$ROOTFS/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

mount_chroot() {
    mount -o bind /proc "$ROOTFS/proc" 2>/dev/null || true
    mount -o bind /sys "$ROOTFS/sys" 2>/dev/null || true
    mount -o bind /dev "$ROOTFS/dev" 2>/dev/null || true
    mount -o bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null || true
    mount -o bind /run "$ROOTFS/run" 2>/dev/null || true
}
umount_chroot() {
    for m in run dev/pts dev sys proc; do
        umount "$ROOTFS/$m" 2>/dev/null || true
    done
}

mount_chroot
trap umount_chroot EXIT

# --- board packages (survive the installer's autoremove purge) ---
# Only packages the official DietPi installer does NOT provide are listed
# here; DietPi-Installer already installs iw, wpasupplicant, wireless-regdb,
# ifupdown, kmod, locales, procps, systemd-timesyncd, udev, usbutils, wget
# and dropbear. iproute2 is kept explicit because the usb-gadget script uses `ip`.
echo "==> apt update"
chroot "$ROOTFS" apt-get update
echo "==> installing board packages"
chroot "$ROOTFS" apt-get install -y --no-install-recommends \
    dnsmasq \
    iproute2 \
    iptables
if [ "$SERVER_PROFILE" != "1" ]; then
    # 4G-ready profile: keep the modem userspace stack.
    chroot "$ROOTFS" apt-get install -y --no-install-recommends \
        modemmanager qrtr-tools rmtfs
fi
chroot "$ROOTFS" apt-get clean
rm -rf "$ROOTFS/var/lib/apt/lists"/*

# --- dropbear SSH (no password login from the factory) ---
echo "==> installing dropbear"
chroot "$ROOTFS" apt-get install -y --no-install-recommends dropbear
echo "==> generating dropbear host keys + setting root password"
chroot "$ROOTFS" /usr/sbin/dropbearkey -t ed25519 \
    -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true
chroot "$ROOTFS" /usr/sbin/dropbearkey -t rsa \
    -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null || true
echo "root:$DIETPI_PASSWORD" | chroot "$ROOTFS" chpasswd

# --- mainline kernel (vmlinuz + dtbs + modules) ---
echo "==> installing mainline kernel"
tar xkzf "$BUILD/work/$KERNEL_APK" -C "$ROOTFS" \
    --exclude=.PKGINFO --exclude='.SIGN*'

# The APK carries the stock (unpatched) DTBs, so re-apply the DTB patch here:
# the tar extraction above clobbered the patched copy made in 03-fetch-firmware.sh.
echo "==> re-applying DTB patch (overclock / memory release)"
DTB="$ROOTFS/boot/dtbs/qcom/$KERNEL_DTB"
python3 "$SCRIPT_DIR/../tools/patch_dtb.py" \
    --input "$DTB" \
    --output "$DTB" \
    --opp-mhz "$CPU_OPP_MHZ" \
    $([ "$RELEASE_MEMORY" = "1" ] && echo --release-memory || true) \
    $([ "$AGGRESSIVE_MEMORY" = "1" ] && echo --aggressive || true)

# --- DietPi / device overlay ---
echo "==> applying overlay"
cp -a "$REPO_DIR/overlay/boot/." "$ROOTFS/boot/"
cp -a "$REPO_DIR/overlay/etc/." "$ROOTFS/etc/"
cp -a "$REPO_DIR/overlay/usr/." "$ROOTFS/usr/"
cp "$REPO_DIR/vendor/usr/sbin/msm-firmware-loader.sh" "$ROOTFS/usr/sbin/"
chmod 0755 "$ROOTFS/usr/sbin/msm-firmware-loader.sh" \
          "$ROOTFS/usr/local/sbin/usb-gadget.sh" \
          "$ROOTFS/boot/Automation_Custom_PreScript.sh" \
          "$ROOTFS/boot/Automation_Custom_Script.sh"

# --- board services for a headless server (SERVER_PROFILE=1) ---
if [ "$SERVER_PROFILE" = "1" ]; then
    echo "==> server profile: strip modem/desktop-only userspace"
    # Never leave the modem stack around (ModemManager+polkitd RSS ~18MiB).
    chroot "$ROOTFS" apt-get purge -y \
        modemmanager libmm-glib0 libqmi-glib5 polkitd \
        qrtr-tools rmtfs || true
    # Remove legacy wireless firmware blobs (nothing on MSM8916 uses them);
    # container firmware tarballs ~215MiB of a 4GiB eMMC.
    chroot "$ROOTFS" apt-get purge -y \
        firmware-iwlwifi firmware-atheros firmware-brcm80211 \
        firmware-realtek firmware-misc-nonfree || true
    chroot "$ROOTFS" apt-get autoremove -y --purge || true
    # No virtual console on a headless board (serial ttyMSM0 stays for rescue).
    chroot "$ROOTFS" systemctl mask getty@tty1.service || true
fi

# --- enable board services ---
echo "==> enabling services"
chroot "$ROOTFS" systemctl enable usb-gadget.service >/dev/null 2>&1 || true
chroot "$ROOTFS" systemctl enable msm-firmware-loader.service >/dev/null 2>&1 || true
chroot "$ROOTFS" systemctl enable dnsmasq.service >/dev/null 2>&1 || true

# --- WCNSS WiFi firmware ---
echo "==> installing WCNSS firmware"
mkdir -p "$ROOTFS/lib/firmware"
cp "$REPO_DIR/vendor/lib/firmware/wcnss"*.mdt "$ROOTFS/lib/firmware/" 2>/dev/null || true
cp "$REPO_DIR/vendor/lib/firmware/wcnss"*.b* "$ROOTFS/lib/firmware/" 2>/dev/null || true
mkdir -p "$ROOTFS/lib/firmware/wlan/prima"
cp "$REPO_DIR/vendor/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin" "$ROOTFS/lib/firmware/wlan/prima/" 2>/dev/null || true

# --- patch DietPi WiFi scan to decode hex-encoded SSIDs (upstream issue #3495) ---
echo "==> patching DietPi WiFi scan for hex-encoded SSIDs"
WIFIDB="$ROOTFS/boot/dietpi/func/dietpi-wifidb"
if [ -f "$WIFIDB" ]; then
    perl -i -pe 's{(iw dev "\$wifi_iface" scan)}{$1 | perl -pe "s/\\x([0-9a-fA-F]{2})/chr(hex(\$1))/ge"}' "$WIFIDB"
fi

# --- patch DietPi first-boot rootfs resize: multi-digit partition numbers ---
# Stock matches only single-digit partitions ('p[1-9]$' plus fixed-width
# ${ROOT_DEV: -1} / ${ROOT_DEV::-2} parsing), but the UFI001B GPT places
# rootfs at mmcblk0p14 (13 Qualcomm partitions precede it). The official
# script aborts with 'Unsupported root device naming scheme' on first boot -
# right after disabling itself, so it never retries and the 1.5 GiB image
# filesystem never grows into the full-eMMC partition. Guarded like 04's
# BOOT_DEVICE check: fail the build loudly if upstream changes these lines.
echo "==> patching DietPi fs_partition_resize for multi-digit partitions"
RESIZE_SH="$ROOTFS/var/lib/dietpi/services/fs_partition_resize.sh"
[ -f "$RESIZE_SH" ] || { echo "missing $RESIZE_SH"; exit 1; }
python3 - "$RESIZE_SH" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

hits = dict.fromkeys(
    ("sd_regex", "mmc_regex", "sd_part", "mmc_part", "sd_drive", "mmc_drive"), 0
)
for i, line in enumerate(lines):
    if "=~" in line and "[a-z][1-9]$" in line:
        lines[i] = line.replace("[a-z][1-9]$", "[a-z][1-9][0-9]*$")
        hits["sd_regex"] += 1
    elif "=~" in line and "p[1-9]$" in line:
        lines[i] = line.replace("p[1-9]$", "p[1-9][0-9]*$")
        hits["mmc_regex"] += 1
    elif "ROOT_PART=${ROOT_DEV: -1}" in line and "/dev/sda1" in line:
        lines[i] = line.replace("${ROOT_DEV: -1}", "${ROOT_DEV##*[a-z]}")
        hits["sd_part"] += 1
    elif "ROOT_PART=${ROOT_DEV: -1}" in line and "/dev/mmcblk0p1" in line:
        lines[i] = line.replace("${ROOT_DEV: -1}", "${ROOT_DEV##*p}")
        hits["mmc_part"] += 1
    elif "ROOT_DRIVE=${ROOT_DEV::-1}" in line:
        lines[i] = line.replace("${ROOT_DEV::-1}", "${ROOT_DEV%%[0-9]*}")
        hits["sd_drive"] += 1
    elif "ROOT_DRIVE=${ROOT_DEV::-2}" in line:
        lines[i] = line.replace("${ROOT_DEV::-2}", "${ROOT_DEV%p*}")
        hits["mmc_drive"] += 1

bad = {k: v for k, v in hits.items() if v != 1}
if bad:
    sys.exit(f"fs_partition_resize patch mismatch, expected exactly 1 hit each: {hits}")

with open(path, "w") as f:
    f.writelines(lines)
print(f"patched {path}: {hits}")
PYEOF
bash -n "$RESIZE_SH"

# --- tidy up ---
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static" "$ROOTFS/root/dietpi-convert.sh"
: > "$ROOTFS/root/.bash_history"
umount_chroot
trap - EXIT

echo "==> rootfs customized"
du -sh "$ROOTFS"