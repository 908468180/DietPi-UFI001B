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

# --- Fetch DietPi SOURCE ON THE HOST and bind-mount it into the container.
# 02-build-bootloader.sh proves plain https git clones to github.com work on
# the runner host, while git inside the nspawn container spuriously asked for
# credentials. Cloning on the host also keeps a proper .git checkout for the
# installer. ---
DIETPI_SRC="$BUILD/work/dietpi-src"
if [ ! -d "$DIETPI_SRC/.git" ]; then
    rm -rf "$DIETPI_SRC"
    echo "==> cloning DietPi ($GITOWNER/$GITBRANCH) on host"
    GIT_TERMINAL_PROMPT=0 git clone --depth 1 -b "$GITBRANCH" \
        "https://github.com/${GITOWNER}/DietPi" "$DIETPI_SRC"
fi

# --- DietPi conversion driver (runs as a systemd oneshot unit inside the
# container). systemd.run= (kernel-command-line generator) has proven
# unreliable on the ubuntu-22.04-arm runner (EXEC/203), so we boot the
# container normally and select our unit via the default-unit parameter. ---
cat > "$ROOTFS/root/dietpi-convert.sh" <<'EOSCRIPT'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
trap 'systemctl poweroff || true' EXIT
echo "==> [dietpi] inside container: $(uname -m) $(cat /etc/debian_version)"

# DietPi build flags are read from the environment by the installer.
export GITOWNER GITBRANCH IMAGE_CREATOR PREIMAGE_INFO \
       HW_MODEL WIFI_REQUIRED GUEST_NETWORK_REQUIRED DISTRO_TARGET \
       TEST_KERNEL TEST_UBOOT RK35XX_MAINLINE

if [ ! -d /root/DietPi/.git ]; then
    echo "ERROR: DietPi checkout not found inside container (bind mount failed)"
    exit 1
fi
cd /root/DietPi

echo "==> [dietpi] running dietpi-installer (HW_MODEL=$HW_MODEL)"
bash ./.build/images/dietpi-installer
echo "==> [dietpi] installer finished OK"
touch /etc/dietpi-convert.ok
EOSCRIPT

cat > "$ROOTFS/etc/systemd/system/dietpi-convert.service" <<'EOF'
[Unit]
Description=DietPi conversion
After=systemd-remount-fs.service

[Service]
Type=oneshot
ExecStart=/bin/bash /root/dietpi-convert.sh
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chmod +x "$ROOTFS/root/dietpi-convert.sh"

echo "==> systemd-nspawn: booting DietPi conversion"
timeout 2400 systemd-nspawn --register=no --keep-unit \
    -D "$ROOTFS" \
    --boot /usr/lib/systemd/systemd \
    --console=pipe \
    --bind="$DIETPI_SRC:/root/DietPi" \
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
    "systemd.unit=dietpi-convert.service"

if [ ! -f "$ROOTFS/etc/dietpi-convert.ok" ]; then
    echo "ERROR: DietPi conversion did not complete successfully"
    exit 1
fi
echo "==> DietPi conversion complete"
ls -d "$ROOTFS"/DietPi 2>/dev/null || true