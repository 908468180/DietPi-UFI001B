#!/usr/bin/env python3
"""Generate gpt_both0.bin for UFI001B (and same-family MSM8916 dongles).

Layout follows OpenStick-Builder (github.com/kinsamanka/OpenStick-Builder),
which is the proven extlinux boot scheme for this hardware. boot/rootfs
partitions use the exact PARTUUIDs referenced by extlinux.conf and fstab:

    rootfs: A7AB80E8-E9D1-E8CD-F157-93F69B1D141E
    boot:   80780B1D-0FE1-27D3-23E4-9244E62F8C46

Unlike the OpenStick template (rootfs size 2015 sectors on a placeholder
disk), the rootfs partition here is extended to the real end of the eMMC
(last usable LBA). The produced file is 67 sectors (34304 bytes):
34-sector primary GPT + 32-sector backup entry array + 1-sector backup
header, byte-for-byte matching the structure of the community
gpt_both0.bin files.

Only the Python standard library is used, so it runs anywhere.

Usage:
    python3 make_gpt.py [--total-sectors N] [--output FILE] [--info]
"""

import argparse
import struct
import zlib
import uuid

PARTSECT = 512

# Disk geometry (UFI001B 001b.bin factory backup).
DEFAULT_TOTAL_SECTORS = 7569375

# Disk GUID used by OpenStick-Builder (reproducibility).
DISK_GUID = "DB708ACF-2E04-8DE2-BAFE-30C9B26444C5"

# (name, start_lba, size_lba, type_guid, part_guid)
PARTITIONS = [
    ("fsc", 4096, 2, "57B90A16-22C9-E33B-8F5D-0E81686A68CB", "89BEF928-6B3F-432E-970E-46926F6BD579"),
    ("fsg", 4098, 3072, "638FF8E2-22C9-E33B-8F5D-0E81686A68CB", "2B772340-E0F0-4A95-B652-27ADE619EF14"),
    ("modem", 7170, 131072, "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", "709AEC75-FFB4-4218-9A2E-A38C9D689D6D"),
    ("modemst1", 138242, 3072, "EBBEADAF-22C9-E33B-8F5D-0E81686A68CB", "D747B414-92EA-4098-AA56-0ED0AAB1F6DC"),
    ("modemst2", 141314, 3072, "0A288B1F-22C9-E33B-8F5D-0E81686A68CB", "057F46B4-9F89-4AA4-9A60-1735B4E2DB4B"),
    ("persist", 144386, 65536, "6C95E238-E343-4BA8-B489-8681ED22AD0B", "ACD4F30F-6A99-42B2-9262-A3FECEB2B46B"),
    ("sec", 209922, 32, "303E6AC3-AF15-4C54-9E9B-D9A8FBECF401", "DD07C606-826C-4B5E-BE75-F5FCAA91E623"),
    ("hyp", 209954, 1024, "E1A6A689-0C8D-4CC6-B4E8-55A4320FBD8A", "CB49D0D3-C49B-4586-986C-BDADBF545FEF"),
    ("rpm", 210978, 1024, "098DF793-D712-413D-9D4E-89D711772228", "B5154BA2-C18D-4A17-A8CD-97EEDC0BEF31"),
    ("sbl1", 212002, 1024, "DEA0BA2C-CBDD-4805-B4F9-F428251C3E98", "B166535F-4B99-48F6-AA77-16F27669FD2F"),
    ("tz", 213026, 2048, "A053AA7F-40B8-4B1C-BA08-2F68AC71A4F4", "A983B7C4-FC3A-4F88-823E-91D5DB06337F"),
    ("aboot", 215074, 2048, "400FFDCD-22E0-47E7-9A23-F16ED9382388", "22675009-60A3-401F-8D3F-44CD32ED394C"),
    ("boot", 217122, 131072, "20117F86-E985-4357-B9EE-374BC1D8487D", "80780B1D-0FE1-27D3-23E4-9244E62F8C46"),
    ("rootfs", 348194, -1, "1B81E7E6-F50D-419B-A739-2AEEF8DA3335", "A7AB80E8-E9D1-E8CD-F157-93F69B1D141E"),
]

NUM_ENTRIES = 128
ENTRY_SZ = 128
PRIMARY_SECTORS = 34          # LBA 0..33 (MBR + header + entry array)
BACKUP_ENTRIES_SECTORS = 32   # 128 * 128 / 512


def guid_to_bytes(guid_hex):
    """EFI GUID to on-disk bytes (mixed-endian)."""
    if isinstance(guid_hex, str):
        u = uuid.UUID(guid_hex)
        g = u.hex
    else:
        g = guid_hex
    f0, f1, f2, tail = g[:8], g[8:12], g[12:16], g[16:]
    return struct.pack("<IHH", int(f0, 16), int(f1, 16), int(f2, 16)) + bytes.fromhex(tail)


def guid_bytes_to_str(b):
    """Inverse of guid_to_bytes()."""
    f0, f1, f2 = struct.unpack("<IHH", b[:8])
    return "%08X-%04X-%04X-%s-%s" % (f0, f1, f2, b[8:10].hex().upper(), b[10:16].hex().upper())


def make_entry(name, start, last, type_guid, part_guid):
    enc = b""
    enc += guid_to_bytes(type_guid)
    enc += guid_to_bytes(part_guid)
    enc += struct.pack("<QQQ", start, last, 0)
    name_b = name.encode("utf-16-le")[:72]
    enc += name_b.ljust(72, b"\x00")
    assert len(enc) == ENTRY_SZ
    return enc


def make_mbr(total_sectors):
    mbr = bytearray(PARTSECT)
    mbr[510:512] = b"\x55\xaa"
    # One 0xEE protective partition covering the whole disk.
    p = bytearray(16)
    p[0] = 0x00
    p[1] = 0x02
    p[2] = 0x00
    p[3] = 0x00
    p[4] = 0xEE
    p[5:8] = b"\xff\xff\xff"
    p[8:12] = struct.pack("<I", 1)            # start LBA
    p[12:16] = struct.pack("<I", total_sectors - 1)  # size in sectors
    mbr[446:462] = p
    return bytes(mbr)


def make_gpt_header(total_sectors, my_lba, entries_lba, disk_guid_bytes, entry_array):
    last_usable = total_sectors - PRIMARY_SECTORS  # total - 34
    header = b"EFI PART"
    header += struct.pack("<III", 0x00010000, 92, 0)  # rev, size, crc(placeholder)
    header += struct.pack("<I", 0)                    # reserved
    header += struct.pack("<QQ", my_lba, total_sectors - 1)   # self, alternate
    header += struct.pack("<QQ", 34, last_usable)     # first/last usable
    header += disk_guid_bytes
    header += struct.pack("<Q", entries_lba)
    header += struct.pack("<II", NUM_ENTRIES, ENTRY_SZ)
    arr_crc = zlib.crc32(entry_array) & 0xFFFFFFFF
    header += struct.pack("<I", arr_crc)
    header = header.ljust(92, b"\x00")
    # Fill CRC over the 92-byte header (crc field currently zero).
    head_crc = zlib.crc32(header) & 0xFFFFFFFF
    header = header[:16] + struct.pack("<I", head_crc) + header[20:]
    return header.ljust(PARTSECT, b"\x00")


def build(total_sectors, disk_guid=DISK_GUID):
    last_usable = total_sectors - PRIMARY_SECTORS
    entries = []
    for name, start, size, tguid, pguid in PARTITIONS:
        if size == -1:
            last = last_usable
            size = last - start + 1
        else:
            last = start + size - 1
        entries.append(make_entry(name, start, last, tguid, pguid))

    entry_array = b"".join(entries)
    entry_array += b"\x00" * (NUM_ENTRIES * ENTRY_SZ - len(entry_array))
    assert len(entry_array) == NUM_ENTRIES * ENTRY_SZ

    dguid = guid_to_bytes(disk_guid)
    primary = b""
    primary += make_mbr(total_sectors)
    primary += make_gpt_header(total_sectors, 1, 2, dguid, entry_array)
    primary += entry_array
    assert len(primary) == PRIMARY_SECTORS * PARTSECT

    # Backup entries live at total-33 .. total-2; header at total-1.
    backup_entries = make_gpt_header(total_sectors, total_sectors - 1, total_sectors - 33, dguid, entry_array)
    backup_entries += entry_array

    return {
        "primary": primary,
        "backup_entries": entry_array,
        "backup_header": bytes(backup_entries[:PARTSECT]),
        "last_usable": last_usable,
        "entries": entries,
        "entry_meta": PARTITIONS,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--total-sectors", type=int, default=DEFAULT_TOTAL_SECTORS,
                    help="eMMC size in 512-byte sectors (default %d)" % DEFAULT_TOTAL_SECTORS)
    ap.add_argument("--output", default="gpt_both0.bin")
    ap.add_argument("--info", action="store_true", help="print table and exit")
    args = ap.parse_args()

    if args.total_sectors < PRIMARY_SECTORS + BACKUP_ENTRIES_SECTORS + 2:
        raise SystemExit("total-sectors too small")

    blob = build(args.total_sectors)
    with open(args.output, "wb") as f:
        f.write(blob["primary"])
        f.write(blob["backup_entries"])
        f.write(blob["backup_header"])
    print("wrote %s (%d bytes)" % (args.output,
          len(blob["primary"]) + len(blob["backup_entries"]) + len(blob["backup_header"])))
    if args.info:
        print("disk total sectors :", args.total_sectors)
        print("last usable LBA    :", blob["last_usable"])
        print("%-9s %10s %10s %10s  %s" % ("name", "start", "size", "end", "part-guid"))
        for meta, ent in zip(blob["entry_meta"], blob["entries"]):
            name, start, _size, _t, pguid = meta
            end = struct.unpack("<Q", ent[40:48])[0]
            print("%-9s %10d %10d %10d  %s" % (name, start, end - start + 1, end, pguid))


if __name__ == "__main__":
    main()