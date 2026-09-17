"""Tests for scripts/coa-probe-read.py. Run: python3 -m unittest discover -s scripts/tests -p 'test_*.py'"""
import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "coa-probe-read.py"
spec = importlib.util.spec_from_file_location("coa_probe_read", SCRIPT)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)

SAMPLE = (
    b'\nCoaProbeDB = {\n'
    rb'	"{\"command\":\"ping\",\"req\":\"r1\",\"result\":{\"pong\":true}}", -- [1]' b'\n'
    rb'	"{\"command\":\"item\",\"req\":\"r2\",\"result\":{\"text\":\"a\\nb\"}}", -- [2]' b'\n'
    rb'	"{\"command\":\"ping\",\"req\":\"r1\",\"result\":{\"pong\":false}}", -- [3]' b'\n'
    rb'	"{\"req\":\"r3\",\"result\":{\"name\":\"Fr\195\168re\"}}", -- [4]' b'\n'
    b'}\n'
)


class LuaUnescapeTest(unittest.TestCase):
    def test_simple_escapes(self):
        self.assertEqual(reader.lua_unescape(r'a\"b\\c\nd'), 'a"b\\c\nd')

    def test_decimal_escape(self):
        self.assertEqual(reader.lua_unescape(r'\65\066'), "AB")


class FindAnswerTest(unittest.TestCase):
    def test_newest_answer_wins(self):
        self.assertEqual(reader.find_answer(SAMPLE, "r1")["result"], {"pong": False})

    def test_json_escape_inside_lua_string(self):
        self.assertEqual(reader.find_answer(SAMPLE, "r2")["result"]["text"], "a\nb")

    def test_utf8_from_decimal_escapes(self):
        self.assertEqual(reader.find_answer(SAMPLE, "r3")["result"]["name"], "Frère")

    def test_missing_request(self):
        self.assertIsNone(reader.find_answer(SAMPLE, "nope"))

    def test_ignores_non_json_strings(self):
        self.assertIsNone(reader.find_answer(b'X = {\n\t"not json", -- [1]\n}\n', "r1"))


class MainTest(unittest.TestCase):
    def test_prints_answer(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "CoaProbe.lua"
            path.write_bytes(SAMPLE)
            out = io.StringIO()
            with redirect_stdout(out):
                code = reader.main(["coa-probe-read.py", str(path), "r2"])
        self.assertEqual(code, 0)
        self.assertIn('"req": "r2"', out.getvalue())

    def test_missing_file(self):
        self.assertEqual(reader.main(["coa-probe-read.py", "/nonexistent/CoaProbe.lua", "r1"]), 1)

    def test_usage(self):
        self.assertEqual(reader.main(["coa-probe-read.py"]), 2)


if __name__ == "__main__":
    unittest.main()
