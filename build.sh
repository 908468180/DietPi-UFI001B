#!/bin/bash
set -euo pipefail
# ============================================================================
# debian-ufi001b: Minimal Debian for UFI001B (MSM8916 4G USB dongle)
# ============================================================================
# Features:
#   - USB RNDIS/ECM with DHCP (192.168.68.1)
#   - WiFi STA/AP via WCNSS
#   - SSH (dropbear)
#   - No DietPi, minimal
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SCRIPT_DIR/build"
ROOTFS="$BUILD/rootfs"
OUT="$SCRIPT_DIR/out"

. "$SCRIPT_DIR/config/build.conf"

echo "==> debian-ufi001b ($DISTRO/$ARCH)"

# --- clean ---
rm -rf "$BUILD"
mkdir -p "$BUILD" "$OUT"

# --- debootstrap ---
echo "==> bootstrap"
debootstrap --arch="$ARCH" --foreign "$DISTRO" "$ROOTFS" \
    http://deb.debian.org/debian

cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"

# --- apt sources ---
cat > "$ROOTFS/etc/apt/sources.list" << EOF
deb http://deb.debian.org/debian $DISTRO main contrib non-free non-free-firmware
deb http://deb.debian.org/debian $DISTRO-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $DISTRO-security main contrib non-free non-free-firmware
EOF

# --- packages ---
echo "==> packages"
chroot "$ROOTFS" apt-get update
chroot "$ROOTFS" apt-get install -y --no-install-recommends \
    bash-completion ca-certificates curl \
    dnsmasq dropbear ethtool fonts-wqy-zenhei ifupdown \
    iproute2 iw kmod locales nano net-tools \
    procps sudo systemd-timesyncd udev usbutils wget

# --- locale ---
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen
echo "LANG=en_US.UTF-8" > "$ROOTFS/etc/default/locale"

# --- root password ---
echo "root:root" | chroot "$ROOTFS" chpasswd

# --- hostname ---
echo "ufi001b" > "$ROOTFS/etc/hostname"

# --- overlay ---
echo "==> overlay"
cp -a "$SCRIPT_DIR/overlay/." "$ROOTFS/"

# --- firmware ---
echo "==> firmware"
mkdir -p "$ROOTFS/lib/firmware/wlan/prima"
cp "$SCRIPT_DIR/vendor/lib/firmware/wcnss"*.mdt "$ROOTFS/lib/firmware/" 2>/dev/null || true
cp "$SCRIPT_DIR/vendor/lib/firmware/wcnss"*.b* "$ROOTFS/lib/firmware/" 2>/dev/null || true
cp "$SCRIPT_DIR/vendor/lib/firmware/wlan/prima/WCNSS_qcom_wlan_nv.bin" \
    "$ROOTFS/lib/firmware/wlan/prima/" 2>/dev/null || true

# --- iwlist wrapper ---
install -m 0755 /dev/stdin "$ROOTFS/usr/local/bin/iwlist" << 'EOF'
#!/bin/sh
IFACE=""
for arg in "$@"; do case "$arg" in wlan*|wl*) IFACE="$arg" ;; esac; done
[ -z "$IFACE" ] && { echo "Usage: iwlist <iface> scan"; exit 1; }
iw dev "$IFACE" scan 2>/dev/null | perl -pe 's/\\x([0-9a-fA-F]{2})/chr(hex($1))/ge' \
    | awk '/BSS /{b=substr($2,1,17);n++}/freq:/{f=$2}/signal:/{s=$2}/SSID:/{printf "Cell %d - %s  Freq:%s  Signal:%s  ESSID:\"%s\"\n",n,b,f,s,substr($0,index($0,": ")+2)}'
EOF

# --- services ---
chroot "$ROOTFS" systemctl enable ssh 2>/dev/null || true

# --- finalize ---
: > "$ROOTFS/root/.bash_history"
rm -rf "$ROOTFS/tmp"/*

echo "==> done"
du -sh "$ROOTFS"
