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
echo "==> apt update"
chroot "$ROOTFS" apt-get update
echo "==> installing board packages"
chroot "$ROOTFS" apt-get install -y --no-install-recommends \
    dnsmasq \
    ifupdown \
    iproute2 \
    kmod \
    locales \
    modemmanager \
    procps \
    qrtr-tools \
    rmtfs \
    systemd-timesyncd \
    udev \
    usbutils \
    wget
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

# --- mainline kernel (vmlinuz + dtbs + modules), dtb already patched ---
echo "==> installing mainline kernel"
tar xkzf "$BUILD/work/$KERNEL_APK" -C "$ROOTFS" \
    --exclude=.PKGINFO --exclude='.SIGN*'

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

# --- enable board services ---
echo "==> enabling services"
chroot "$ROOTFS" systemctl enable usb-gadget.service >/dev/null 2>&1 || true
chroot "$ROOTFS" systemctl enable msm-firmware-loader.service >/dev/null 2>&1 || true
chroot "$ROOTFS" systemctl enable dnsmasq.service >/dev/null 2>&1 || true

# --- patch DietPi to skip first-run network check ---
echo "==> patching DietPi to skip first-run"
# Remove the first-run flag so DietPi skips the entire first-boot setup
rm -f "$ROOTFS/boot/dietpi/.dietpi-first-run"
# Also disable automated setup to avoid interactive prompts
sed -i 's/^AUTO_SETUP_AUTOMATED=1/AUTO_SETUP_AUTOMATED=0/' "$ROOTFS/boot/dietpi.txt" 2>/dev/null || true

# --- WCNSS WiFi firmware ---
echo "==> installing WCNSS firmware"
mkdir -p "$ROOTFS/lib/firmware"
cp "$REPO_DIR/vendor/lib/firmware/wcnss"*.mdt "$ROOTFS/lib/firmware/" 2>/dev/null || true
cp "$REPO_DIR/vendor/lib/firmware/wcnss"*.b* "$ROOTFS/lib/firmware/" 2>/dev/null || true

# --- tidy up ---
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static" "$ROOTFS/root/dietpi-convert.sh"
: > "$ROOTFS/root/.bash_history"
umount_chroot
trap - EXIT

echo "==> rootfs customized"
du -sh "$ROOTFS"