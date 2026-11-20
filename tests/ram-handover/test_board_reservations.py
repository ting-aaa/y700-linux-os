import contextlib
import io
from pathlib import Path
import runpy
import unittest


report = runpy.run_path(str(Path(__file__).with_name("board-reservations.py")))["report"]


class BoardRanges(unittest.TestCase):
    def setUp(self):
        self.rows = [
            "BOOT firmware", "BOOT memreserve", "BOOT its", "EFI_NAME SecureBoot present",
            "EFI_NAME BootOrder present", "EFI_NAME BootCurrent absent", "TABLE property 0x10000",
            *(f"TABLE CPU{i} {hex((i + 2) * 65536)}" for i in range(8)),
            "IOMEM ram 10000-9ffff", "IOMEM reserved_child 10000-9ffff",
            "MEMBLOCK memory 0x10000..0x9ffff", "MEMBLOCK reserved 0x10000..0x9ffff",
            "DT 00000000002000000000000000010000", "COMPLETE",
        ]

    def check_rows(self, rows):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            result = report(rows)
        self.assertNotIn("0x", out.getvalue())
        return result

    def test_union_covers_full_last_table(self):
        rows = self.rows.copy()
        pos = rows.index("MEMBLOCK reserved 0x10000..0x9ffff")
        rows[pos:pos+1] = ["MEMBLOCK reserved 0x10000..0x9fffe", "MEMBLOCK reserved 0x9ffff..0x9ffff"]
        self.assertTrue(self.check_rows(rows))
        self.assertFalse(self.check_rows(rows[:pos+1] + rows[pos+2:]))

    def test_reserved_listing_and_memblock_are_independent(self):
        for changed in ("IOMEM reserved_other 10000-9ffff", "IOMEM ram 10000-9ffff"):
            with self.subTest(changed=changed):
                rows = [changed if s.startswith("IOMEM reserved_child") else s for s in self.rows]
                self.assertFalse(self.check_rows(rows))
        rows = [s.replace("0x10000..0x9ffff", "0xa0000..0xaffff")
                if s.startswith("MEMBLOCK reserved") else s for s in self.rows]
        self.assertFalse(self.check_rows(rows))

    def test_incomplete_or_aliased_boot(self):
        for blocked in ("TABLE CPU7 0x90000", "COMPLETE", "BOOT memreserve"):
            with self.subTest(blocked=blocked), self.assertRaises(ValueError):
                self.check_rows([s for s in self.rows if s != blocked])
        for row in ("TABLE CPU7 0x80000", "TABLE CPU7 0x90001", "TABLE property 0x90000"):
            with self.subTest(row=row), self.assertRaises(ValueError):
                self.check_rows([row if s == "TABLE CPU7 0x90000" else s for s in self.rows])


if __name__ == "__main__":
    unittest.main()
