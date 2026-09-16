import argparse
from pathlib import Path
import struct
import uuid
import zlib

SECTOR = 512
SECTORS = 131072
RESERVED = 32
FAT_SECTORS = 1024
DATA_SECTOR = RESERVED + 2 * FAT_SECTORS
BLOCK = 2048
IMAGE_BLOCK = 24


def check_efi(data):
    if data[:2] != b"MZ" or len(data) < 64:
        raise ValueError("Input is not a PE executable")

    pe = struct.unpack_from("<I", data, 60)[0]

    if pe + 160 > len(data) or data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Invalid PE header")

    machine, = struct.unpack_from("<H", data, pe + 4)
    magic, = struct.unpack_from("<H", data, pe + 24)
    subsystem, = struct.unpack_from("<H", data, pe + 92)

    if (machine, magic, subsystem) != (0x8664, 0x20B, 10):
        raise ValueError("Expected an x86_64 PE32+ EFI application")


def directory_entry(name, attributes, cluster, size=0):
    entry = bytearray(32)
    entry[:11] = name
    entry[11] = attributes
    date = ((2026 - 1980) << 9) | (1 << 5) | 1

    struct.pack_into("<HH", entry, 16, date, date)
    struct.pack_into("<H", entry, 20, cluster >> 16)
    struct.pack_into("<H", entry, 24, date)
    struct.pack_into("<HI", entry, 26, cluster & 0xFFFF, size)

    return entry


def fat_image(executable):
    check_efi(executable)

    clusters = (len(executable) + SECTOR - 1) // SECTOR
    cluster_count = SECTORS - DATA_SECTOR

    if clusters + 3 > cluster_count:
        raise ValueError("EFI executable exceeds the boot volume")

    image = bytearray(SECTORS * SECTOR)
    image[:11] = b"\xeb\x58\x90GRANITE "

    struct.pack_into(
        "<HBHBHHBHHHII", image, 11,
        SECTOR, 1, RESERVED, 2, 0, 0, 0xF8, 0, 63, 255, 0, SECTORS,
    )

    struct.pack_into("<IHHIHH", image, 36, FAT_SECTORS, 0, 0, 2, 1, 6)
    struct.pack_into("<BBBI", image, 64, 0x80, 0, 0x29, 0x47524E33)

    image[71:82] = b"GRANITEOS  "
    image[82:90] = b"FAT32   "
    image[510:512] = b"\x55\xaa"

    struct.pack_into("<I", image, SECTOR, 0x41615252)
    struct.pack_into(
        "<III", image, SECTOR + 484,
        0x61417272, cluster_count - clusters - 3, 5 + clusters,
    )
    struct.pack_into("<I", image, SECTOR + 508, 0xAA550000)

    image[6 * SECTOR:7 * SECTOR] = image[:SECTOR]
    image[7 * SECTOR:8 * SECTOR] = image[SECTOR:2 * SECTOR]

    fat = bytearray(FAT_SECTORS * SECTOR)
    for index, value in enumerate([0x0FFFFFF8, 0xFFFFFFFF, 0x0FFFFFFF, 0x0FFFFFFF, 0x0FFFFFFF]):
        struct.pack_into("<I", fat, index * 4, value)

    for index in range(clusters):
        cluster = 5 + index
        value = 0x0FFFFFFF if index == clusters - 1 else cluster + 1
        struct.pack_into("<I", fat, cluster * 4, value)

    for copy in range(2):
        start = (RESERVED + copy * FAT_SECTORS) * SECTOR
        image[start:start + len(fat)] = fat

    root = DATA_SECTOR * SECTOR
    image[root:root + 32] = directory_entry(b"GRANITEOS  ", 8, 0)
    image[root + 32:root + 64] = directory_entry(b"EFI        ", 16, 3)
    for cluster, parent, name, child, size in [
        (3, 0, b"BOOT       ", 4, 0),
        (4, 3, b"BOOTX64 EFI", 5, len(executable)),
    ]:
        start = (DATA_SECTOR + cluster - 2) * SECTOR
        image[start:start + 32] = directory_entry(b".          ", 16, cluster)
        image[start + 32:start + 64] = directory_entry(b"..         ", 16, parent)
        image[start + 64:start + 96] = directory_entry(name, 16 if size == 0 else 32, child, size)

    start = (DATA_SECTOR + 3) * SECTOR
    image[start:start + len(executable)] = executable

    return image


def both16(value):
    return struct.pack("<H", value) + struct.pack(">H", value)


def both32(value):
    return struct.pack("<I", value) + struct.pack(">I", value)


def record(name, block, size, directory=False):
    result = bytearray(33 + len(name) + (len(name) % 2 == 0))
    result[0] = len(result)
    result[2:10] = both32(block)
    result[10:18] = both32(size)
    result[18:25] = bytes([126, 1, 1, 0, 0, 0, 0])
    result[25] = 2 if directory else 0
    result[28:32] = both16(1)
    result[32] = len(name)
    result[33:33 + len(name)] = name

    return result


def iso_image(fat):
    total = IMAGE_BLOCK + (len(fat) + BLOCK - 1) // BLOCK
    image = bytearray(total * BLOCK)

    pvd = bytearray(BLOCK)

    pvd[:7] = b"\x01CD001\x01"
    pvd[8:40] = b"GRANITEOS".ljust(32)
    pvd[40:72] = b"GRANITEOS_BOOT".ljust(32)
    pvd[80:88] = both32(total)
    pvd[120:124] = both16(1)
    pvd[124:128] = both16(1)
    pvd[128:132] = both16(BLOCK)
    pvd[132:140] = both32(10)

    struct.pack_into("<I", pvd, 140, 19)
    struct.pack_into(">I", pvd, 148, 20)

    pvd[156:190] = record(b"\0", 21, BLOCK, True)
    pvd[190:813] = b" " * 623

    for offset in (813, 830, 847, 864):
        pvd[offset:offset + 17] = b"2026010100000000\0"

    pvd[881] = 1
    image[16 * BLOCK:17 * BLOCK] = pvd

    boot = bytearray(BLOCK)
    boot[:7] = b"\x00CD001\x01"
    boot[7:30] = b"EL TORITO SPECIFICATION"

    struct.pack_into("<I", boot, 71, 22)

    image[17 * BLOCK:18 * BLOCK] = boot
    image[18 * BLOCK:18 * BLOCK + 7] = b"\xffCD001\x01"
    image[19 * BLOCK:19 * BLOCK + 10] = struct.pack("<BBIHH", 1, 0, 21, 1, 0)
    image[20 * BLOCK:20 * BLOCK + 10] = struct.pack(">BBIHH", 1, 0, 21, 1, 0)

    root = b"".join([
        record(b"\0", 21, BLOCK, True),
        record(b"\1", 21, BLOCK, True),
        record(b"BOOT.CAT;1", 22, BLOCK),
        record(b"ESP.IMG;1", IMAGE_BLOCK, len(fat)),
    ])
    image[21 * BLOCK:21 * BLOCK + len(root)] = root

    catalog = bytearray(BLOCK)
    catalog[0:2] = b"\x01\xef"
    catalog[4:28] = b"GraniteOS UEFI".ljust(24, b"\0")
    catalog[30:32] = b"\x55\xaa"
    checksum = (-sum(struct.unpack("<16H", catalog[:32]))) & 0xFFFF
    struct.pack_into("<H", catalog, 28, checksum)
    struct.pack_into("<BBHBBHI", catalog, 32, 0x88, 0, 0, 0, 0, 1, IMAGE_BLOCK)
    image[22 * BLOCK:23 * BLOCK] = catalog
    image[IMAGE_BLOCK * BLOCK:IMAGE_BLOCK * BLOCK + len(fat)] = fat

    return image


def disk_image(fat):
    start = 2048
    total = start + SECTORS + 2048
    image = bytearray(total * SECTOR)
    struct.pack_into(
        "<B3sB3sII", image, 446, 0, b"\0\x02\0", 0xEE,
        b"\xff\xff\xff", 1, total - 1,
    )
    image[510:512] = b"\x55\xaa"

    entries = bytearray(128 * 128)
    entries[:16] = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b").bytes_le
    entries[16:32] = uuid.UUID("e90b7001-041b-482e-9e2c-6fbc9af36a01").bytes_le

    struct.pack_into("<QQQ", entries, 32, start, start + SECTORS - 1, 0)

    name = "GraniteOS Boot".encode("utf-16-le")
    entries[56:56 + len(name)] = name
    entries_crc = zlib.crc32(entries)

    for current, backup, table in [(1, total - 1, 2), (total - 1, 1, total - 33)]:
        header = bytearray(SECTOR)

        struct.pack_into(
            "<8sIIIIQQQQ16sQIII", header, 0,
            b"EFI PART", 0x10000, 92, 0, 0, current, backup, 34, total - 34,
            uuid.UUID("ccefb72e-930c-421b-89d1-dd2fd90b3713").bytes_le,
            table, 128, 128, entries_crc,
        )

        struct.pack_into("<I", header, 16, zlib.crc32(header[:92]))

        image[current * SECTOR:(current + 1) * SECTOR] = header
        image[table * SECTOR:table * SECTOR + len(entries)] = entries

    image[start * SECTOR:(start + SECTORS) * SECTOR] = fat
    for backup in (0, 6):
        struct.pack_into("<I", image, (start + backup) * SECTOR + 28, start)

    return image


def main():
    parser = argparse.ArgumentParser(description="Build FAT32, UEFI ISO, and GPT boot media")
    parser.add_argument("--efi", type=Path, default=Path("zig-out/esp/EFI/BOOT/BOOTX64.EFI"))
    parser.add_argument("--output", type=Path, default=Path("zig-out"))
    args = parser.parse_args()

    fat = fat_image(args.efi.read_bytes())
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "esp.img").write_bytes(fat)

    iso = args.output / "granite.iso"
    iso.write_bytes(iso_image(fat))
    print(iso.resolve())

    disk = args.output / "granite.img"
    disk.write_bytes(disk_image(fat))
    print(disk.resolve())


if __name__ == "__main__":
    main()
