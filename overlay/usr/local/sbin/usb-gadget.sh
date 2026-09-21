#!/bin/bash
# usb-gadget.sh - configure UFI001B in USB device mode (configfs) and bring
# up the gadget interface with a static address.
#
# Modes (config/board.conf USB_GADGET):
#   0 = off
#   1 = ECM only
#   2 = RNDIS + ECM  (default; Windows prefers RNDIS)

set -e

case "${USB_GADGET:-2}" in
    0) exit 0 ;;
esac

modprobe libcomposite 2>/dev/null || true
mount -t configfs configfs /sys/kernel/config 2>/dev/null || true

UDC=$(ls /sys/class/udc/ 2>/dev/null | head -n1)
if [ -z "$UDC" ]; then
    echo "usb-gadget: no UDC available (USB not in device mode?)" >&2
    exit 0
fi

CONF=/sys/kernel/config/usb_gadget/ufi001b
if [ ! -d "$CONF" ]; then
    mkdir -p "$CONF"
    echo 0x1d6b > "$CONF/idVendor"   # Linux Foundation
    echo 0x0104 > "$CONF/idProduct"  # Ethernet/RNDIS gadget
    mkdir -p "$CONF/strings/0x409"
    echo "$(cat /proc/sys/kernel/hostname)" > "$CONF/strings/0x409/serialnumber"
    echo "UFI001B" > "$CONF/strings/0x409/manufacturer"
    echo "DietPi UFI001B Ethernet" > "$CONF/strings/0x409/product"
    mkdir -p "$CONF/configs/c.1"
    echo 120 > "$CONF/configs/c.1/MaxPower"
    if [ "${USB_GADGET:-2}" = "1" ]; then
        mkdir -p "$CONF/functions/ecm.usb0"
        ln -s "$CONF/functions/ecm.usb0" "$CONF/configs/c.1/ecm0"
    else
        mkdir -p "$CONF/functions/rndis.usb0"
        mkdir -p "$CONF/functions/ecm.usb0"
        ln -s "$CONF/functions/rndis.usb0" "$CONF/configs/c.1/rndis"
        ln -s "$CONF/functions/ecm.usb0" "$CONF/configs/c.1/ecm0"
    fi
    echo "$UDC" > "$CONF/UDC"
fi

IP="${USB_GADGET_IP:-192.168.68.1/24}"
for d in usb0 usb1; do
    ip link set dev "$d" up 2>/dev/null || true
    ip addr flush dev "$d" 2>/dev/null || true
    ip addr add "$IP" dev "$d" 2>/dev/null || true
done

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
exit 0