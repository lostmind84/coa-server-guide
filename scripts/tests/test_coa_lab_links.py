import importlib.util
import json
import os
import tempfile
import unittest
import unittest.mock
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("coa_lab_links", SCRIPTS / "coa_lab_links.py")
ll = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ll)

STATE_FILES = ["Ascension.exe", "Extensions.dll", "CoA64.exe", "d3d9.dll", "x64/sl.dlss.dll",
               "Data/patch.MPQ", "Data/patch-B.MPQ", "Data/enUS/locale-enUS.MPQ", "Data/Content/Spell.json",
               "WTF/Config.wtf", "Data/enUS/realmlist.wtf", "Data/patch-gone.MPQ"]


class LinksTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.user = self.root / "client"
        self.lab = self.root / "lab" / "ascension-lab"
        self.lab.mkdir(parents=True)
        for rel in STATE_FILES[:-1] + ["Data/patch-ZZA.mpq", "Interface/GLUES/x.blp", "Data/patch-AAP.mpq"]:
            self.write(self.user / rel, f"client {rel}")
        self.out = []
        env = {k: v for k, v in os.environ.items() if not k.startswith("COA_LAB_")}
        patcher = unittest.mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self._tmp.cleanup()

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def write_state(self, files=STATE_FILES):
        self.write(self.user / ll.LAUNCHER_STATE,
                   json.dumps({"version": "x", "files": {f: {"size": 1, "checksum": "0"} for f in files}}))

    def sync(self):
        return ll.sync(self.user, self.lab, out=self.out.append)

    # selection

    def test_state_json_selects_launcher_files_minus_excluded_and_private(self):
        self.write_state()
        source, selected, absent = ll.select(self.user)
        self.assertTrue(source.endswith("state.json"))
        self.assertEqual(selected, ["Ascension.exe", "Data/Content/Spell.json", "Data/enUS/locale-enUS.MPQ",
                                    "Data/patch-B.MPQ", "Data/patch.MPQ", "Extensions.dll"])
        self.assertEqual(absent, ["Data/patch-gone.MPQ"])

    def test_without_state_json_the_allow_list_applies(self):
        _, selected, _ = ll.select(self.user)
        self.assertEqual(selected, ["Ascension.exe", "Data/Content/Spell.json", "Data/enUS/locale-enUS.MPQ",
                                    "Data/patch-B.MPQ", "Data/patch.MPQ", "Extensions.dll"])
        self.assertNotIn("Data/patch-ZZA.mpq", selected)

    def test_patterns_and_exclusions_are_overridable(self):
        with unittest.mock.patch.dict(os.environ, {"COA_LAB_LINK_PATTERNS": "Data/*.mpq Data/*.MPQ",
                                                   "COA_LAB_LINK_EXCLUDE": "Data/patch-AAP.mpq"}):
            _, selected, _ = ll.select(self.user)
        self.assertIn("Data/patch-ZZA.mpq", selected)
        self.assertNotIn("Data/patch-AAP.mpq", selected)
        self.write_state()
        with unittest.mock.patch.dict(os.environ, {"COA_LAB_LINK_EXCLUDE": ""}):
            _, selected, _ = ll.select(self.user)
        self.assertIn("CoA64.exe", selected)
        self.assertNotIn("WTF/Config.wtf", selected, "private paths stay out whatever the exclusions")

    def test_unsafe_state_path_is_refused(self):
        self.write_state(["../outside.MPQ"])
        with self.assertRaises(ll.LinkError):
            ll.select(self.user)

    # sync

    def test_sync_links_archives_and_copies_executables(self):
        self.write_state()
        self.assertEqual(self.sync(), 0)
        mpq = self.lab / "Data/patch.MPQ"
        self.assertTrue(mpq.is_symlink())
        self.assertEqual(os.readlink(mpq), str(self.user / "Data/patch.MPQ"))
        exe = self.lab / "Ascension.exe"
        self.assertFalse(exe.is_symlink())
        self.assertEqual(exe.read_text(), "client Ascension.exe")
        self.assertFalse((self.lab / "CoA64.exe").exists())
        self.assertFalse((self.lab / "WTF").exists())
        manifest = json.loads((self.lab / ll.MANIFEST).read_text())
        self.assertEqual(manifest["files"]["Data/patch.MPQ"]["mode"], "link")
        self.assertEqual(manifest["files"]["Ascension.exe"]["mode"], "copy")

    def test_sync_follows_a_launcher_update_and_drops_unlisted_links(self):
        self.write_state()
        self.sync()
        # The launcher writes a .part and renames it over the target.
        part = self.user / "Ascension.exe.part"
        part.write_text("client Ascension.exe v2")
        os.replace(part, self.user / "Ascension.exe")
        self.write_state([f for f in STATE_FILES if f != "Data/patch-B.MPQ"])
        self.sync()
        self.assertEqual((self.lab / "Ascension.exe").read_text(), "client Ascension.exe v2")
        self.assertFalse((self.lab / "Data/patch-B.MPQ").exists())
        self.assertTrue((self.user / "Data/patch-B.MPQ").exists(), "the client's file is never touched")

    def test_sync_keeps_a_private_modified_file(self):
        self.write_state()
        self.write(self.lab / "Extensions.dll", "patched by hand")
        self.write(self.lab / "Data/patch-B.MPQ", "local patch")
        self.assertEqual(self.sync(), 2)
        self.assertEqual((self.lab / "Extensions.dll").read_text(), "patched by hand")
        self.assertFalse((self.lab / "Data/patch-B.MPQ").is_symlink())
        self.assertTrue(any("Data/patch-B.MPQ" in line for line in self.out))

    def test_sync_refuses_the_client_itself(self):
        self.write_state()
        with self.assertRaises(ll.LinkError):
            ll.sync(self.user, self.user / "Data", out=self.out.append)

    # check

    def test_check_reports_changes_since_the_sync(self):
        self.write_state()
        self.sync()
        self.assertEqual(ll.check(self.user, self.lab, out=self.out.append), 0)
        part = self.user / "Data/patch-B.MPQ.part"
        part.write_text("new patch-B, longer")
        os.replace(part, self.user / "Data/patch-B.MPQ")
        (self.user / "Data/patch.MPQ").unlink()
        self.write(self.user / "Data/patch-NEW.MPQ", "x")
        self.write_state(STATE_FILES + ["Data/patch-NEW.MPQ"])
        lines = []
        self.assertEqual(ll.check(self.user, self.lab, out=lines.append), 3)
        text = "\n".join(lines)
        self.assertIn("CHANGED Data/patch-B.MPQ", text)
        self.assertIn("MISSING Data/patch.MPQ", text)
        self.assertIn("NEW Data/patch-NEW.MPQ", text)

    def test_check_without_manifest_is_an_error(self):
        with self.assertRaises(ll.LinkError):
            ll.check(self.user, self.lab, out=self.out.append)

    # convert

    def copied_lab(self):
        for rel in STATE_FILES[:-1]:
            self.write(self.lab / rel, f"client {rel}")
        self.write(self.lab / "Data/patch-B.MPQ", "client Data/patch-B.MPQ but older")
        self.write(self.lab / "Data/patch-T.MPQ", "client Data/patch-T.MPQ")  # same size, other bytes below
        self.write(self.user / "Data/patch-T.MPQ", "client Data/patch-T.MPQ".upper())
        self.write(self.lab / "Interface/GLUES/x.blp", "client Interface/GLUES/x.blp")
        self.write(self.lab.parent / "secrets/account", "secret")

    def test_convert_replaces_only_identical_files(self):
        self.write_state(STATE_FILES + ["Data/patch-T.MPQ"])
        self.copied_lab()
        kept = ll.convert(self.user, [self.lab], out=self.out.append)
        self.assertEqual(kept, 2)
        self.assertTrue((self.lab / "Data/patch.MPQ").is_symlink())
        self.assertTrue((self.lab / "Data/enUS/locale-enUS.MPQ").is_symlink())
        self.assertFalse((self.lab / "Data/patch-B.MPQ").is_symlink())
        self.assertFalse((self.lab / "Data/patch-T.MPQ").is_symlink())
        self.assertFalse((self.lab / "Ascension.exe").is_symlink())
        self.assertEqual((self.lab / "WTF/Config.wtf").read_text(), "client WTF/Config.wtf")
        self.assertEqual((self.lab / "Interface/GLUES/x.blp").read_text(), "client Interface/GLUES/x.blp")
        self.assertEqual((self.lab.parent / "secrets/account").read_text(), "secret")
        text = "\n".join(self.out)
        self.assertIn("KEPT", text)
        self.assertIn("Data/patch-B.MPQ: size", text)
        self.assertIn("Data/patch-T.MPQ: same size, different sha256", text)
        lines = []
        self.assertEqual(ll.check(self.user, self.lab, out=lines.append), 2)
        self.assertIn("PRIVATE Data/patch-B.MPQ", "\n".join(lines))

    def test_convert_dry_run_changes_nothing(self):
        self.write_state()
        self.copied_lab()
        ll.convert(self.user, [self.lab], dry_run=True, out=self.out.append)
        self.assertFalse((self.lab / "Data/patch.MPQ").is_symlink())
        self.assertFalse((self.lab / ll.MANIFEST).exists())
        self.assertTrue(any("would replace" in line for line in self.out))


if __name__ == "__main__":
    unittest.main()
