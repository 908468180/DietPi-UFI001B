# dietpi-ufi001b

Turn a **UFI001B** (qualcomm **MSM8916** 4G USB dongle, 512MB RAM / 3.6GB eMMC)
into a **DietPi** single-board computer -- about 2 GiB of DietPi, the whole
eMMC mostly free. Reproducible image build on GitHub Actions (arm64 runner),
flashable from Windows or Linux, no proprietary blobs in this repository.

```
lk1st (custom primary bootloader)  ->  extlinux.conf  ->  6.6 mainline kernel (postmarketOS)  ->  DietPi
                                           boot ext2 64 MiB | rootfs ext4 1.5 GiB (resizeable to full eMMC)
```

## Features

- **DietPi** as the OS (custom firmware not needed - DietPi runs on any Debian)
- **Mainline kernel 6.6** (postmarketOS `linux-postmarketos-qcom-msm8916`), no
  kernel compilation needed
- **extlinux boot** via **lk1st** + **qhypstub** (both built from source,
  test-signed) - swap kernels without repacking boot images
- **USB network**: RNDIS + ECM gadget (Windows prefers RNDIS), static
  `192.168.68.1/24`, dnsmasq DHCP for the host PC, and **IPv4 NAT**
  (iptables MASQUERADE) so the PC shares the stick's WiFi/4G uplink
- **WiFi (WCN3620) / Bluetooth / 4G modem** firmware loaded at first boot from
  your own `modem` partition by `msm-firmware-loader` (no blobs vendored here)
- **Default ~1.2 GHz CPU OPP** snapped to real A53 PLL rates
  (`400/800/998.4/1094.4/1152/1190.4/1209.6 MHz` — not round 1000/1100/1200
  placeholders, which the PLL cannot lock to) and **~85 MiB extra RAM** by
  releasing the modem reserved-memory region -- both knobs in
  `config/board.conf`
- Community-proven partition table (`tools/make_gpt.py`), rootfs fills the
  whole eMMC (7,569,375 sectors on this unit)

## Requirements / expectations

- The build runs on a **native arm64 host** (GitHub Actions
  `ubuntu-22.04-arm` or an arm64 machine). Reasons: DietPi's installer is
  executed inside the rootfs booted as a systemd container
  (`systemd-nspawn`), and neither systemd-nspawn nor DietPi run
  cross-architecturally.
- This is research-grade tinkering on factory-firmware hardware. Read
  `flash/README.md` before flashing; back up first.

## Build

On GitHub: fork, run the **Build** workflow (`workflow_dispatch`), download the
artifact. Locally on arm64 Ubuntu:

```sh
./build.sh
```

Artifacts land in `out/files/`:

```
aboot.mbn  hyp.mbn  rpm.mbn  sbl1.mbn  tz.mbn   # bootloader + stock firmware
gpt_both0.bin  boot.bin  rootfs.bin             # images
SHA256SUMS
```

## Flash

See [flash/README.md](flash/README.md). TL;DR: EDL mode, back up
`fsc fsg modem modemst1 modemst2 persist sec`, `edl w aboot aboot.mbn`,
reboot to fastboot, `fastboot flash partition gpt_both0.bin` + the images,
restore the backups, reboot. One-shot scripts: `flash/flash-all.cmd`
(Windows) / `flash/flash-all.sh` (Linux).

After first boot (DietPi first-run finishes automatically) connect the stick's
USB port to a PC: `ssh root@192.168.68.1` (default password `dietpi` - change
it!).

## Configuration

| file | knob | default | meaning |
|---|---|---|---|
| `config/board.conf` | `CPU_OPP_MHZ` | `1200` | CPU OPP target; `0` = stock (998.4 MHz). Values are snapped to real A53 PLL rates (400/800/998.4/1094.4/1152/1190.4/1209.6) so the clock framework and OPP table stay in sync. |
| | `RELEASE_MEMORY` | `1` | free the modem carve-out (~85 MiB to RAM): static DTB patch **and** runtime disable by the ported lk2nd-rproc module in lk1st. `LK2ND_RPROC_MODE=no_modem` (modem only) or `none` (also disable adsp+venus, audio via LPASS; matches the community "release memory" build) |
| | `USB_GADGET` | `2` | `0` off, `1` ECM, `2` RNDIS+ECM |
| | `USB_GADGET_IP` | `192.168.68.1/24` | gadget static address |
| | `DISK_TOTAL_SECTORS` | `7569375` | eMMC geometry |
| | `LK1ST_COMPATIBLE` | `thwc,ufi001c` | lk1st device match |
| | `LK1ST_BUNDLE_DTB` | `msm8916-512mb-mtp.dtb` | lk1st bundled DTB |
| `config/build.conf` | `DISTRO_TARGET` | `7` | DietPi distro (7=bookworm) |
| | `KERNEL_APK` | ...`6.6-r5.apk` | mainline kernel package |
| `overlay/boot/dietpi.txt` | `AUTO_SETUP_*` | | DietPi first-run answers |
| | `AUTO_SETUP_SWAPFILE_SIZE` | `256` | zram swap size in MiB (`0` disables swap; `1` = DietPi auto ≈ RAM/2 = 236) |
| | `AUTO_SETUP_SWAPFILE_LOCATION` | `zram` | official `dietpi-set_swapfile` backend; resize/disable later via `dietpi-config` → Advanced Options → Swap file |
| `overlay/etc/sysctl.d/99-zram-swappiness.conf` | `vm.swappiness` | `1` | DietPi writes `50` for zram in `98-dietpi-zram-swap.conf`; this drop-in keeps DietPi's disk-swap default of `1` (last-resort / anti-OOM) |

## Known differences from upstream DietPi

The image keeps DietPi as stock as possible, but intentionally diverges in a
few places so this headless dongle works. Documented so upgrades are not a
surprise:

- **`/boot/dietpi/func/dietpi-wifidb` is patched** (hex-encoded SSID decoding,
  upstream DietPi issue #3495): `05-customize-rootfs.sh` rewrites the `iw dev
  scan` line to decode `\xNN` escapes, otherwise encrypted/hidden networks
  with non-ASCII SSIDs cannot be selected. DietPi master does not carry the
  fix yet, verify before removing the patch.
- **`/var/lib/dietpi/services/fs_partition_resize.sh` is patched**
  (multi-digit partition numbers): stock parses only `p1`..`p9` via
  `'p[1-9]$'` + fixed-width `${ROOT_DEV: -1}`/`::-2`, but the UFI001B GPT
  puts rootfs at `mmcblk0p14`, so the official first-boot expansion aborted
  with `Unsupported root device naming scheme` right after disabling itself
  - image filesystem never grew. `05-customize-rootfs.sh` widens both
  naming regexes to `[1-9][0-9]*` and parses PART/DRIVE with
  `##*p`/`%p*` (resp. `##*[a-z]`/`%%[0-9]*` for sd-style). Verify before
  removing: DietPi master still carried the single-digit-only parser when
  checked (2026-09-23).
- **No system bus / `dbus`** on `SERVER_PROFILE=1` images - stock DietPi
  removes it and root only tooling (`sudo systemctl` via systemd's private
  socket) works fine; plain `systemctl` from a non-root shell will fail.
- **`SERVER_PROFILE=1` purges the wireless firmware blobs**
  (`firmware-iwlwifi`/`-atheros`/`-brcm80211`/`-realtek`/`-misc-nonfree`,
  ~215 MiB) and the modem userspace (`modemmanager`, `polkitd`, ...) that
  DietPi-Installer installs by default - MSM8916 uses neither.
- Custom systemd units (`usb-gadget.service`, `msm-firmware-loader.service`)
  and the DTB/kernel surgery (OPP overclock, reserved-memory release) have no
  upstream equivalent; revert knobs in `config/board.conf`.
- **zram swap + low swappiness** (stock DietPi would create a ~1.5 GiB
  `/var/swap` file on first boot with `SIZE=1`/`LOCATION=/var/swap` defaults):
  `overlay/boot/dietpi.txt` pins `AUTO_SETUP_SWAPFILE_SIZE=256` +
  `AUTO_SETUP_SWAPFILE_LOCATION=zram`, so first boot runs the official
  `dietpi-set_swapfile 256 zram`. Size/disable stays adjustable after flash
  via `dietpi-config` → Advanced Options → Swap file. `dietpi-set_swapfile`
  writes `vm.swappiness=50` for zram (`98-dietpi-zram-swap.conf`);
  `overlay/etc/sysctl.d/99-zram-swappiness.conf` overrides it back to `1`
  (DietPi's own disk-swap default, "prevent OOM only") without patching
  DietPi scripts.
- **USB internet sharing** installs the `iptables` package and
  `usb-gadget.sh` adds an idempotent
  `POSTROUTING -s <usb-subnet> ! -d <usb-subnet> -j MASQUERADE` so the host
  PC reuses the stick's WiFi/4G uplink (same rule as OpenStick-Builder's
  ifupdown hook). Stock DietPi has no NAT userspace on SERVER_PROFILE=1.

## Other UFI boards

Same build with a different DTB / compatible: set `KERNEL_DTB`
(`msm8916-thwc-ufi001c.dtb`, `msm8916-thwc-uf896.dtb`, ...) and the matching
`LK1ST_*` values, keep the same partition table.

## Repository layout

```
scripts/      01..06 build steps (deps, bootloader, firmware+dtb, dietpi,
              customize, images)
tools/        make_gpt.py (partition table), patch_dtb.py (DTB surgery),
              lk2nd-rproc/ (ported lk2nd-rproc.c, runtime memory release)
overlay/      files installed onto the rootfs (extlinux.conf, dietpi.txt,
              usb gadget, fstab, ...)
vendor/       msm-firmware-loader.sh (upstream, MIT)
flash/        flashing scripts + instructions
config/       build & board settings
```

## Credits / sources

- [OpenStick-Builder](https://github.com/kinsamanka/OpenStick-Builder) - boot
  chain, partition table, firmware loader, flashing procedure
- [msm8916-mainline](https://github.com/msm8916-mainline) - lk1st, qhypstub,
  qtestsign
- [postmarketOS](https://postmarketos.org) - prebuilt 6.6 mainline kernel
- [DietPi](https://dietpi.com) - the operating system
- This project's analysis notes (device dump, overclock/memory-reduction
  reverse engineering) live alongside, produced during the research.

## License

MIT, see [LICENSE](LICENSE). Vendored upstream code stays under its own
license (see headers).