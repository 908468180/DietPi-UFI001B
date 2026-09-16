# Flashing dietpi-ufi001b

Brick risk is real: proceed at your own risk, and **always back up the stock
firmware first**. This procedure is the community-standard one used by
OpenStick-Builder for this family of MSM8916 dongles.

## Prerequisites

- **edl tool**: <https://github.com/bkerler/edl>
- **fastboot**: `sudo apt install fastboot` (or the standalone binary on Windows)
- **Enter EDL mode** on the stick:
  <https://wiki.postmarketos.org/wiki/Zhihe_series_LTE_dongles_(generic-zhihe)#How_to_enter_flash_mode>

## Files

The image package ships these files (`out/files/` after a build):

| file              | contents                                             |
|-------------------|------------------------------------------------------|
| `aboot.mbn`       | lk1st primary bootloader (extlinux support), test-signed |
| `hyp.mbn`         | qhypstub hypervisor stub, test-signed                |
| `rpm.mbn` `sbl1.mbn` `tz.mbn` | stock Qualcomm firmware (unchanged)         |
| `gpt_both0.bin`   | new partition table (rootfs fills the full eMMC)     |
| `boot.bin`        | 64 MiB ext2 (sparse): vmlinuz, dtb, extlinux.conf, dietpi.txt |
| `rootfs.bin`      | 1.5 GiB ext4 (sparse): DietPi system                 |
| `SHA256SUMS`      | checksums                                            |

## Procedure

1. **Back up the original partitions** (do this on the untouched device):

   ```shell
   for n in fsc fsg modem modemst1 modemst2 persist sec; do
       edl r $n $n.bin
   done
   ```

   Keep these files! `modem` contains your baseband firmware, the others are
   calibration/state partitions. `flash-all.sh --backup` does this for you.

2. **Install the custom bootloader and reboot into fastboot:**

   ```shell
   edl w aboot aboot.mbn
   edl erase boot
   edl reset
   ```

3. **Flash the image:**

   ```shell
   fastboot flash partition gpt_both0.bin
   fastboot flash aboot aboot.mbn
   fastboot flash hyp hyp.mbn
   fastboot flash rpm rpm.mbn
   fastboot flash sbl1 sbl1.mbn
   fastboot flash tz tz.mbn
   fastboot flash boot boot.bin
   fastboot flash rootfs rootfs.bin
   ```

4. **Restore the original partitions:**

   ```shell
   for n in fsc fsg modem modemst1 modemst2 persist sec; do
       fastboot flash $n $n.bin
   done
   fastboot reboot
   ```

Scripts that run steps 1-4: `flash-all.sh` (Linux/macOS) and
`flash-all.cmd` (Windows).

## Expected boot

- lk1st loads `/boot/extlinux/extlinux.conf` from the ext2 boot partition,
  boots the 6.6 mainline kernel with `msm8916-thwc-ufi001c.dtb`.
- First boot runs the **DietPi first-run setup fully automatically**
  (~2-5 minutes), then reboots.
- USB: plug the stick into a PC -> RNDIS (or ECM) interface `usb0`
  `192.168.68.1/24`. SSH: `ssh root@192.168.68.1` (password `dietpi`,
  change it in `/boot/dietpi.txt` first!).
- Serial console: `ttyMSM0` 115200.

## Restoring the factory Android system

Re-flash the full `edl rf <backup_file>` image you made before flashing.