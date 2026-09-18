# debian-ufi001b

Minimal Debian for UFI001B (MSM8916 4G USB dongle).

## Features

- USB RNDIS/ECM with DHCP (192.168.68.1)
- WiFi STA/AP via WCNSS
- SSH (dropbear) - root/root
- Chinese WiFi SSID support
- No DietPi, minimal

## Default Credentials

- **SSH**: root / root
- **WiFi**: Configure via `iwconfig` or `wpa_supplicant`

## Quick Start

```bash
# Build
sudo bash build.sh

# Flash (via fastboot)
cd flash
sudo ./flash-all.sh
```

## SSH into Device

```bash
# Connect USB, then:
ssh root@192.168.68.1
```

## WiFi Configuration

```bash
# Scan WiFi
iwlist wlan0 scan

# Connect
wpa_passphrase "SSID" "password" > /etc/wpa_supplicant.conf
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
dhclient wlan0
```

## Build Structure

```
debian-ufi001b/
├── build.sh           # Main build script
├── config/            # Build configuration
├── overlay/           # Filesystem overlay
├── vendor/            # Firmware blobs
├── flash/             # Flash scripts
└── out/               # Build output
```

## Credits

Based on [OpenStick-Builder](https://github.com/kinsamanka/OpenStick-Builder) firmware loading scripts.
