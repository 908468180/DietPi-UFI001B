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
# without first-run there is no Stock SSH install step, so make sure dropbear
# is enabled explicitly or the device would only be reachable over USB gadgets.
chroot "$ROOTFS" systemctl enable dropbear.service >/dev/null 2>&1 || true

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

# --- pre-complete DietPi first-run (skip interactive first boot) ---
# Community-standard image-build practice (see DietPi .build/images/dietpi-build):
#   .install_stage=10 marks the first-run setup as already done, so the device
#   boots straight into the finished system - no whiptail, no network waiter,
#   no survey. Locale/timezone/password are applied here at build time instead.
echo "==> pre-completing DietPi first-run (skipping interactive first boot)"
mkdir -p "$ROOTFS/boot/dietpi"
echo 10 > "$ROOTFS/boot/dietpi/.install_stage"
echo 'SURVEY_OPTED_IN=-1' >> "$ROOTFS/boot/dietpi.txt"

LOCALE=$(sed -n 's/^AUTO_SETUP_LOCALE=//p' "$REPO_DIR/overlay/boot/dietpi.txt" | tail -n1)
TIMEZONE=$(sed -n 's/^AUTO_SETUP_TIMEZONE=//p' "$REPO_DIR/overlay/boot/dietpi.txt" | tail -n1)
: "${LOCALE:=en_US.UTF-8}"
: "${TIMEZONE:=UTC}"
echo "==> pinning locale ${LOCALE} / timezone ${TIMEZONE} (bypasses first-run)"
echo "${LOCALE} UTF-8" >> "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen >/dev/null 2>&1 || true
chroot "$ROOTFS" update-locale LANG="${LOCALE}" >/dev/null 2>&1 || true
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "$ROOTFS/etc/localtime"
echo "${TIMEZONE}" > "$ROOTFS/etc/timezone"

# --- tidy up ---
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static" "$ROOTFS/root/dietpi-convert.sh"
: > "$ROOTFS/root/.bash_history"
umount_chroot
trap - EXIT

echo "==> rootfs customized"
du -sh "$ROOTFS"