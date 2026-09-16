#!/bin/sh -e
# 04-convert-dietpi.sh - bootstrap Debian rootfs, convert to DietPi.
#
# The DietPi installer is run inside the freshly bootstrapped arm64 rootfs
# exactly the way DietPi's own images are built (run the installer on the
# live system). We boot the rootfs as a systemd container with
# systemd-nspawn.
#
# REQUIREMENT: this step must run natively on an arm64 host (e.g. GitHub
# Actions ubuntu-22.04-arm runner). systemd-nspawn executes the container's
# PID 1 natively, so qemu-user is not a fallback here. debootstrap still
# works under qemu on x86-64, but the nspawn step will abort.

. "$SCRIPT_DIR/../config/build.conf"
. "$SCRIPT_DIR/../config/board.conf"

ROOTFS="$BUILD/work/rootfs"
MACHINE=$(uname -m)

if [ "$MACHINE" != "aarch64" ] && [ "$MACHINE" != "arm64" ]; then
    echo "ERROR: 04 needs a native arm64 host for systemd-nspawn."
    echo "       Use an ubuntu-22.04-arm runner or a local arm64 machine."
    exit 1
fi

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

echo "==> debootstrap $DISTRO_RELEASE"
# minbase omits the init system; --include adds systemd (+systemd-sysv provides
# /sbin/init) so that systemd-nspawn --boot below has a PID 1 to run.
debootstrap --variant=minbase --arch arm64 \
    --include=systemd,systemd-sysv \
    "$DISTRO_RELEASE" "$ROOTFS" "$DEBIAN_MIRROR"

cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DISTRO_RELEASE main contrib non-free-firmware
deb $DEBIAN_MIRROR-security $DISTRO_RELEASE-security main contrib non-free-firmware
deb $DEBIAN_MIRROR $DISTRO_RELEASE-updates main contrib non-free-firmware
EOF

# debootstrap leaves /etc/resolv.conf empty; the container shares the host
# netns, so point it at the host resolver (127.0.0.53 systemd-resolved).
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

# --- DietPi conversion driver (runs as PID1 command inside the container) ---
cat > "$ROOTFS/root/dietpi-convert.sh" <<'EOSCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
echo "==> [dietpi] inside container: $(uname -m) $(cat /etc/debian_version)"

# DietPi build flags are read from the environment by the installer.
export GITOWNER GITBRANCH IMAGE_CREATOR PREIMAGE_INFO \
       HW_MODEL WIFI_REQUIRED GUEST_NETWORK_REQUIRED DISTRO_TARGET \
       TEST_KERNEL TEST_UBOOT RK35XX_MAINLINE

apt-get update -qq
apt-get install -y --no-install-recommends git ca-certificates curl

if [ ! -d /root/DietPi ]; then
    git clone --depth 1 "https://github.com/${GITOWNER}/DietPi"
fi
cd /root/DietPi

echo "==> [dietpi] running dietpi-installer (HW_MODEL=$HW_MODEL)"
bash ./.build/images/dietpi-installer
echo "==> [dietpi] installer finished OK"
EOSCRIPT
chmod +x "$ROOTFS/root/dietpi-convert.sh"

echo "==> systemd-nspawn: booting DietPi conversion"
systemd-nspawn --register=no --keep-unit \
    -D "$ROOTFS" \
    --boot /usr/lib/systemd/systemd \
    --console=pipe \
    -E GITOWNER="$GITOWNER" \
    -E GITBRANCH="$GITBRANCH" \
    -E IMAGE_CREATOR="$IMAGE_CREATOR" \
    -E PREIMAGE_INFO="$PREIMAGE_INFO" \
    -E HW_MODEL=22 \
    -E WIFI_REQUIRED=1 \
    -E GUEST_NETWORK_REQUIRED=0 \
    -E DISTRO_TARGET="$DISTRO_TARGET" \
    -E TEST_KERNEL=0 \
    -E TEST_UBOOT=0 \
    -E RK35XX_MAINLINE=0 \
    "systemd.run=1" \
    "systemd.run_command=/root/dietpi-convert.sh" \
    "systemd.run_success_action=exit" \
    "systemd.run_failure_action=exit"

echo "==> DietPi conversion complete"
ls -d "$ROOTFS"/DietPi 2>/dev/null || true