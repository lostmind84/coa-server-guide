"""Tests for scripts/coa-lab-footprint. Run: python3 -m unittest discover -s scripts/tests -p 'test_*.py'"""
import importlib.machinery
import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "coa-lab-footprint"
loader = importlib.machinery.SourceFileLoader("coa_lab_footprint", str(SCRIPT))
spec = importlib.util.spec_from_loader("coa_lab_footprint", loader)
footprint = importlib.util.module_from_spec(spec)
loader.exec_module(footprint)


class FakeProc:
    def __init__(self, root: Path):
        self.root = root

    def add(self, pid, ppid, comm="proc", environ=(), rss=None, pss=None, utime=0, stime=0):
        directory = self.root / str(pid)
        directory.mkdir(parents=True)
        fields = ["S", str(ppid)] + ["0"] * 9 + [str(utime), str(stime)] + ["0"] * 20
        (directory / "stat").write_text(f"{pid} ({comm}) " + " ".join(fields) + "\n")
        (directory / "environ").write_bytes(b"".join(item.encode() + b"\0" for item in environ))
        if rss is not None:
            (directory / "smaps_rollup").write_text(
                f"00400000-7fff0000 ---p 00000000 00:00 0 [rollup]\nRss: {rss} kB\nPss: {pss} kB\n"
                "Pss_Anon: 1 kB\nShared_Clean: 2 kB\n")


class FootprintTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.proc_root = Path(self.tmp.name)
        self.proc = FakeProc(self.proc_root)

    def tearDown(self):
        self.tmp.cleanup()

    def test_tree_follows_parent_links(self):
        self.proc.add(1, 0)
        self.proc.add(2, 1)
        self.proc.add(3, 2)
        self.proc.add(9, 0)
        self.assertEqual(sorted(footprint.process_tree(1, self.proc_root)), [1, 2, 3])

    def test_prefix_processes_adds_wineserver_outside_tree(self):
        self.proc.add(1, 0)
        self.proc.add(2, 1, environ=["WINEPREFIX=/lab/prefix"])
        self.proc.add(7, 0, comm="wineserver", environ=["HOME=/h", "WINEPREFIX=/lab/prefix"])
        self.proc.add(8, 0, comm="wineserver", environ=["WINEPREFIX=/user/prefix"])
        self.proc.add(9, 0, environ=["WINEPREFIX=/lab/prefix-2"])
        self.assertEqual(sorted(footprint.prefix_processes("/lab/prefix", self.proc_root)), [2, 7])

    def test_memory_sums_rss_and_pss(self):
        self.proc.add(1, 0, rss=100, pss=60)
        self.proc.add(2, 1, rss=50, pss=30)
        self.assertEqual(footprint.memory_kib([1, 2], self.proc_root), {"rss_kib": 150, "pss_kib": 90})

    def test_vanished_process_is_skipped(self):
        self.proc.add(1, 0, rss=100, pss=60)
        self.assertEqual(footprint.memory_kib([1, 42], self.proc_root), {"rss_kib": 100, "pss_kib": 60})
        self.assertEqual(footprint.cpu_seconds([42], self.proc_root, ticks=100), 0.0)
        self.assertEqual(footprint.process_tree(42, self.proc_root), [])

    def test_cpu_parses_comm_with_parens(self):
        self.proc.add(5, 1, comm="wine (preloader)", utime=300, stime=100)
        self.assertEqual(footprint.cpu_seconds([5], self.proc_root, ticks=100), 4.0)


if __name__ == "__main__":
    unittest.main()
