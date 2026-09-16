import struct
import unittest
import uuid
import zlib

import media


class MediaTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.efi = bytearray(1703)
        cls.efi[:2] = b"MZ"
        struct.pack_into("<I", cls.efi, 60, 128)
        cls.efi[128:132] = b"PE\0\0"
        struct.pack_into("<H", cls.efi, 132, 0x8664)
        struct.pack_into("<H", cls.efi, 152, 0x20B)
        struct.pack_into("<H", cls.efi, 220, 10)
        cls.fat = media.fat_image(cls.efi)

    def test_fat_directory_and_file_chain(self):
        image = self.fat
        sector, = struct.unpack_from("<H", image, 11)
        reserved, = struct.unpack_from("<H", image, 14)
        fat_size, = struct.unpack_from("<I", image, 36)
        total, = struct.unpack_from("<I", image, 32)
        start = reserved + image[16] * fat_size
        self.assertGreaterEqual(total - start, 65525)
        self.assertEqual(len(image), total * sector)
        self.assertEqual(image[510:512], b"\x55\xaa")
        self.assertEqual(image[:sector], image[6 * sector:7 * sector])
        first_fat = image[reserved * sector:(reserved + fat_size) * sector]
        self.assertEqual(first_fat, image[(reserved + fat_size) * sector:start * sector])

        cluster = 2
        for component in (b"EFI        ", b"BOOT       ", b"BOOTX64 EFI"):
            offset = (start + cluster - 2) * sector
            entries = [image[pos:pos + 32] for pos in range(offset, offset + sector, 32)]
            entry = next(entry for entry in entries if entry[:11] == component)
            high, = struct.unpack_from("<H", entry, 20)
            low, = struct.unpack_from("<H", entry, 26)
            cluster = (high << 16) | low

        size, = struct.unpack_from("<I", entry, 28)
        contents = bytearray()
        seen = set()
        while cluster < 0x0FFFFFF8:
            self.assertNotIn(cluster, seen)
            seen.add(cluster)
            offset = (start + cluster - 2) * sector
            contents += image[offset:offset + sector]
            cluster, = struct.unpack_from("<I", first_fat, cluster * 4)

        self.assertEqual(contents[:size], self.efi)

    def test_iso_catalog_and_embedded_volume(self):
        iso = media.iso_image(self.fat)
        self.assertEqual(iso[16 * 2048:16 * 2048 + 7], b"\x01CD001\x01")
        total, = struct.unpack_from("<I", iso, 16 * 2048 + 80)
        self.assertEqual(total * 2048, len(iso))
        catalog_block, = struct.unpack_from("<I", iso, 17 * 2048 + 71)
        catalog = iso[catalog_block * 2048:(catalog_block + 1) * 2048]
        self.assertEqual(catalog[:2], b"\x01\xef")
        self.assertEqual(sum(struct.unpack("<16H", catalog[:32])) & 0xFFFF, 0)
        self.assertEqual(catalog[32], 0x88)
        image_block, = struct.unpack_from("<I", catalog, 40)
        self.assertEqual(iso[image_block * 2048:], self.fat)

    def test_gpt_primary_backup_checksums_and_esp(self):
        disk = media.disk_image(self.fat)
        self.assertEqual(disk[450], 0xEE)
        total = len(disk) // 512
        for lba in (1, total - 1):
            header = bytearray(disk[lba * 512:lba * 512 + 92])
            self.assertEqual(header[:8], b"EFI PART")
            checksum, = struct.unpack_from("<I", header, 16)
            struct.pack_into("<I", header, 16, 0)
            self.assertEqual(checksum, zlib.crc32(header))
            current, backup = struct.unpack_from("<QQ", header, 24)
            self.assertEqual(current, lba)
            self.assertEqual(backup, total - 1 if lba == 1 else 1)
            table, count, size, crc = struct.unpack_from("<QIII", header, 72)
            entries = disk[table * 512:table * 512 + count * size]
            self.assertEqual(zlib.crc32(entries), crc)
            self.assertEqual(
                uuid.UUID(bytes_le=bytes(entries[:16])),
                uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b"),
            )
            first, last = struct.unpack_from("<QQ", entries, 32)
            self.assertEqual((last - first + 1) * 512, len(self.fat))
            hidden, = struct.unpack_from("<I", disk, first * 512 + 28)
            self.assertEqual(first, hidden)
            self.assertEqual(disk[first * 512 + 4096:(last + 1) * 512], self.fat[4096:])

    def test_rejects_non_efi_inputs(self):
        with self.assertRaises(ValueError):
            media.fat_image(b"not an executable")

        invalid = bytearray(self.efi)
        struct.pack_into("<H", invalid, 220, 3)
        with self.assertRaises(ValueError):
            media.fat_image(invalid)


if __name__ == "__main__":
    unittest.main()
