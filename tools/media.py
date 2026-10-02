from pathlib import Path
import struct
import sys
import uuid
import zlib

SECTOR = 512
SECTORS = 131072
RESERVED = 32
FAT_SECTORS = 1024
DATA_SECTOR = RESERVED + 2 * FAT_SECTORS
BLOCK = 2048
IMAGE_BLOCK = 24
DATA_SECTORS = 262144
FOREIGN_DATA = 65536
FOREIGN_FREE = 196608
ESP = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
GRANITE = uuid.UUID("c9fd8a72-4f14-4449-ae67-540225bb22a4")
BASIC = uuid.UUID("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7")


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


def fat_image(executable, folder=b"BOOT       ", name=b"BOOTX64 EFI"):
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
    for cluster, parent, entry, child, size in [
        (3, 0, folder, 4, 0),
        (4, 3, name, 5, len(executable)),
    ]:
        start = (DATA_SECTOR + cluster - 2) * SECTOR
        image[start:start + 32] = directory_entry(b".          ", 16, cluster)
        image[start + 32:start + 64] = directory_entry(b"..         ", 16, parent)
        image[start + 64:start + 96] = directory_entry(entry, 16 if size == 0 else 32, child, size)

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


def gpt(total, disk, partitions):
    image = bytearray(total * SECTOR)
    struct.pack_into(
        "<B3sB3sII", image, 446, 0, b"\0\x02\0", 0xEE,
        b"\xff\xff\xff", 1, total - 1,
    )
    image[510:512] = b"\x55\xaa"

    entries = bytearray(128 * 128)
    for index, (kind, unique, first, last, name) in enumerate(partitions):
        entry = index * 128
        entries[entry:entry + 16] = kind.bytes_le
        entries[entry + 16:entry + 32] = unique.bytes_le
        struct.pack_into("<QQQ", entries, entry + 32, first, last, 0)
        encoded = name.encode("utf-16-le")
        entries[entry + 56:entry + 56 + len(encoded)] = encoded

    entries_crc = zlib.crc32(entries)

    for current, backup, table in [(1, total - 1, 2), (total - 1, 1, total - 33)]:
        header = bytearray(SECTOR)

        struct.pack_into(
            "<8sIIIIQQQQ16sQIII", header, 0,
            b"EFI PART", 0x10000, 92, 0, 0, current, backup, 34, total - 34,
            disk.bytes_le, table, 128, 128, entries_crc,
        )

        struct.pack_into("<I", header, 16, zlib.crc32(header[:92]))

        image[current * SECTOR:(current + 1) * SECTOR] = header
        image[table * SECTOR:table * SECTOR + len(entries)] = entries

    return image


def disk_image(fat):
    start = 2048
    total = start + SECTORS + 2048
    image = gpt(total, uuid.UUID("ccefb72e-930c-421b-89d1-dd2fd90b3713"), [
        (ESP, uuid.UUID("e90b7001-041b-482e-9e2c-6fbc9af36a01"), start, start + SECTORS - 1, "GraniteOS Boot"),
    ])

    image[start * SECTOR:(start + SECTORS) * SECTOR] = fat
    for backup in (0, 6):
        struct.pack_into("<I", image, (start + backup) * SECTOR + 28, start)

    return image


def data_image():
    return gpt(DATA_SECTORS, uuid.UUID("5b0e6d8c-2f4a-4c1e-9d3b-7a8f1e2c4d60"), [
        (GRANITE, uuid.UUID("0d7c3a91-6e2b-4f85-b1a4-3c9e8f2d7b15"), 2048, DATA_SECTORS - 34, "GraniteOS Data"),
    ])


def stub():
    """A PE header standing in for another OS's boot manager; firmware never runs it."""
    executable = bytearray(1703)
    executable[:2] = b"MZ"
    struct.pack_into("<I", executable, 60, 128)
    executable[128:132] = b"PE\0\0"
    struct.pack_into("<HH", executable, 132, 0x8664, 0)
    struct.pack_into("<H", executable, 152, 0x20B)
    struct.pack_into("<H", executable, 220, 10)
    return bytes(executable)


def foreign_image():
    """A disk another OS already owns: its ESP, a data partition, then room for GraniteOS."""
    esp_start = 2048
    data_start = esp_start + SECTORS
    total = data_start + FOREIGN_DATA + FOREIGN_FREE + 34
    image = gpt(total, uuid.UUID("7d1f0a52-93b4-4e2a-8c61-2f5b0e9d4a17"), [
        (ESP, uuid.UUID("3c8e2b74-5a19-4d06-b7f2-91e4c0a6d358"), esp_start, data_start - 1, "EFI system partition"),
        (BASIC, uuid.UUID("a4b9e6d1-0c72-4f3e-95a8-6d2e1b7c0f49"), data_start, data_start + FOREIGN_DATA - 1, "Basic data partition"),
    ])

    image[esp_start * SECTOR:data_start * SECTOR] = fat_image(stub(), b"MICROSOF   ", b"BOOTMGFWEFI")
    for backup in (0, 6):
        struct.pack_into("<I", image, (esp_start + backup) * SECTOR + 28, esp_start)

    pattern = b"Existing OS data must survive GraniteOS. "
    size = FOREIGN_DATA * SECTOR
    image[data_start * SECTOR:(data_start + FOREIGN_DATA) * SECTOR] = (pattern * (size // len(pattern) + 1))[:size]
    image[(data_start + FOREIGN_DATA) * SECTOR:(total - 34) * SECTOR] = b"\xa5" * (FOREIGN_FREE * SECTOR)
    return image


def partitions(disk):
    """Map partition type to (first, last, unique) after checking both GPT copies' checksums."""
    total = len(disk) // SECTOR
    found = {}
    for lba in (1, total - 1):
        header = bytearray(disk[lba * SECTOR:lba * SECTOR + 92])
        checksum, = struct.unpack_from("<I", header, 16)
        struct.pack_into("<I", header, 16, 0)
        table, count, size, crc = struct.unpack_from("<QIII", header, 72)
        entries = disk[table * SECTOR:table * SECTOR + count * size]
        if header[:8] != b"EFI PART" or zlib.crc32(header) != checksum or zlib.crc32(entries) != crc:
            raise ValueError(f"GPT copy at {lba} is invalid")
        copy = {}
        for offset in range(0, len(entries), size):
            kind = uuid.UUID(bytes_le=bytes(entries[offset:offset + 16]))
            if kind.int:
                first, last = struct.unpack_from("<QQ", entries, offset + 32)
                copy[kind] = (first, last, uuid.UUID(bytes_le=bytes(entries[offset + 16:offset + 32])))
        if found and copy != found:
            raise ValueError("GPT copies disagree")
        found = copy
    return found


def fat_files(volume):
    """Read every file of a FAT32 volume into {path: bytes}."""
    per = volume[13] * SECTOR
    reserved, = struct.unpack_from("<H", volume, 14)
    fat_size, = struct.unpack_from("<I", volume, 36)
    root, = struct.unpack_from("<I", volume, 44)
    fat = volume[reserved * SECTOR:(reserved + fat_size) * SECTOR]
    data = (reserved + volume[16] * fat_size) * SECTOR

    def chain(cluster):
        while 2 <= cluster < 0x0FFFFFF8:
            yield volume[data + (cluster - 2) * per:data + (cluster - 1) * per]
            cluster = struct.unpack_from("<I", fat, cluster * 4)[0] & 0x0FFFFFFF

    files = {}

    def walk(cluster, prefix):
        listing = b"".join(chain(cluster))
        for offset in range(0, len(listing), 32):
            entry = listing[offset:offset + 32]
            if entry[0] == 0:
                return
            if entry[0] == 0xE5 or entry[11] in (0x0F, 0x08) or entry[:1] == b".":
                continue
            name = prefix + entry[:8].rstrip().decode() + ("." + entry[8:11].rstrip().decode() if entry[8:11].strip() else "")
            high, = struct.unpack_from("<H", entry, 20)
            low, size = struct.unpack_from("<HI", entry, 26)
            if entry[11] & 0x10:
                walk(high << 16 | low, name + "/")
            else:
                files[name] = b"".join(chain(high << 16 | low))[:size]

    walk(root, "")
    return files


def verify_install(disk, efi):
    """Check an installed disk: the other OS is untouched and GraniteOS sits in the old free space."""
    before = foreign_image()
    old, new = partitions(before), partitions(disk)
    for kind in (ESP, BASIC):
        if new[kind] != old[kind]:
            raise ValueError(f"Partition {kind} moved")
    first, last, _ = old[BASIC]
    if disk[first * SECTOR:(last + 1) * SECTOR] != before[first * SECTOR:(last + 1) * SECTOR]:
        raise ValueError("Existing OS data changed")
    start, end, _ = new.get(GRANITE, (0, 0, None))
    if start <= last or start % 2048 or end >= len(disk) // SECTOR - 33:
        raise ValueError("GraniteOS partition is outside the free space")
    first, last, _ = old[ESP]
    files_before = fat_files(before[first * SECTOR:(last + 1) * SECTOR])
    files_after = fat_files(disk[first * SECTOR:(last + 1) * SECTOR])
    for path, contents in files_before.items():
        if files_after.get(path) != contents:
            raise ValueError(f"Existing ESP file {path} changed")
    if files_after.get("EFI/GRANITE/BOOTX64.EFI") != efi:
        raise ValueError("Installed loader is missing or differs")


def build(efi, output):
    fat = fat_image(efi.read_bytes())
    output.mkdir(parents=True, exist_ok=True)
    (output / "esp.img").write_bytes(fat)
    (output / "granite.iso").write_bytes(iso_image(fat))
    (output / "granite.img").write_bytes(disk_image(fat))
    (output / "data.img").write_bytes(data_image())
    (output / "foreign.img").write_bytes(foreign_image())


if __name__ == "__main__":
    efi = Path("zig-out/esp/EFI/BOOT/BOOTX64.EFI")
    if sys.argv[1:2] == ["verify"] and len(sys.argv) == 3:
        verify_install(Path(sys.argv[2]).read_bytes(), efi.read_bytes())
        print("Existing OS preserved; GraniteOS installed beside it.")
    else:
        build(efi, Path("zig-out"))
