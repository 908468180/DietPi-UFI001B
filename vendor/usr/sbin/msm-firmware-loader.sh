#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Vendored from https://github.com/kinsamanka/OpenStick-Builder
# (scripts/msm-firmware-loader.sh), unmodified upstream source, MIT.
# Loads firmware blobs from the firmware partitions (modem, persist, ...)
# at boot so WiFi (WCNSS) and the 4G modem work without shipping any
# proprietary binary in this repository. Runs before udev via
# msm-firmware-loader.service.

# Get the slot suffix for A/B devices.
ab_get_slot() {
	command -v qbootctl > /dev/null && \
		ab_slot_suffix=$(qbootctl -a | grep -o 'Active slot: ..' | cut -d ":" -f2 | xargs) || \
		ab_slot_suffix=$(grep -o 'androidboot\.slot_suffix=..' /proc/cmdline | cut -d "=" -f2) || :
	echo "$ab_slot_suffix"
}

FW_PARTITIONS="
	apnhlos
	bluetooth
	modem$(ab_get_slot)
	persist
"

BASEDIR="/lib/firmware/msm-firmware-loader"

mount -o mode=755,nodev,noexec,nosuid -t tmpfs none "$BASEDIR"

mkdir "$BASEDIR/mnt"
mkdir "$BASEDIR/target"

for part in /sys/block/mmcblk*/mmcblk*p*
do
	DEVNAME="$(grep DEVNAME "$part"/uevent | sed 's/DEVNAME=//g')"
	PARTNAME="$(grep PARTNAME "$part"/uevent | sed 's/PARTNAME=//g')"

	if [ -z "${FW_PARTITIONS##*"$PARTNAME"*}" ] && [ -n "$PARTNAME" ]
	then
		mkdir "$BASEDIR/mnt/$PARTNAME"
		mount -o ro,nodev,noexec,nosuid \
			"/dev/$DEVNAME" "$BASEDIR/mnt/$PARTNAME"
	fi
done

EXTRA_PATH="$(cat /sys/module/firmware_class/parameters/path)"

if [ -d "$EXTRA_PATH" ]
then
	for blob in "$EXTRA_PATH"/*
	do
		if ! [ -e "$blob" ]; then break; fi
		ln -s "$blob" "$BASEDIR/target/$(basename "$blob")"
	done
fi

for blob in "$BASEDIR"/mnt/*/image/*
do
	BLOBBASE="${blob##*/}"
	BLOBBASE="${BLOBBASE%.*}"

	for prefix in "$BASEDIR/target/$BLOBBASE."*
	do
		if [ -e "$prefix" ]; then continue 2; fi
	done

	for part in "$BASEDIR"/mnt/*/image/"$BLOBBASE"*
	do
		ln -s "$part" "$BASEDIR/target/$(basename "$part")"
	done
done

if [ -f "$BASEDIR"/mnt/persist/WCNSS_qcom_wlan_nv.bin ]
then
	ln -s "$BASEDIR"/mnt/persist/WCNSS_qcom_wlan_nv.bin "$BASEDIR"/target/WCNSS_qcom_wlan_nv.bin
fi

if [ -f "$BASEDIR/target/venus.mdt" ] && ! [ -d "$BASEDIR/target/qcom" ]
then
	mkdir -p "$BASEDIR/target/qcom/venus-x"
	for part in "$BASEDIR"/target/venus.*
	do
		ln -s "$part" "$BASEDIR/target/qcom/venus-x/$(basename "$part")"
	done
fi

VENUS_DIRS="
	venus-1.8
	venus-3.0
	venus-4.2
	venus-4.4
	venus-5.2
	venus-5.4
	vpu-1.0
	vpu-2.0
"

for vdir in $VENUS_DIRS
do
	if ! [ -d "$BASEDIR/target/qcom/$vdir" ] && [ -f "$BASEDIR/target/venus.mdt" ]
	then
		ln -s "$BASEDIR/target/qcom/venus-x" \
			"$BASEDIR/target/qcom/$vdir"
	fi
done

if [ -h "$BASEDIR"/target/WCNSS_qcom_wlan_nv.bin ]
then
	if ! [ -f "$BASEDIR"/target/wlan/prima/WCNSS_qcom_wlan_nv.bin ]
	then
		mkdir -p "$BASEDIR"/target/wlan/prima
		ln -s "$BASEDIR"/target/WCNSS_qcom_wlan_nv.bin "$BASEDIR"/target/wlan/prima/
	fi
fi

if [ -d "$BASEDIR"/mnt/bluetooth ]
then
	mkdir -p "$BASEDIR"/target/qca
	for btblob in "$BASEDIR"/mnt/bluetooth/image/*
	do
		ln -s "$btblob" "$BASEDIR"/target/qca/
	done
fi

find "$BASEDIR"/target/ \
	-name '*.mdt' \
	-exec sh -c 'ln -s $0 ${0%.mdt}.mbn' {} \;

printf "%s" "$BASEDIR/target" > /sys/module/firmware_class/parameters/path