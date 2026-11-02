import contextlib
import importlib.machinery
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "coa-worktree-cleanup"
loader = importlib.machinery.SourceFileLoader("coa_worktree_cleanup", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
cleanup = importlib.util.module_from_spec(spec)
loader.exec_module(cleanup)

WORLD_ID = "0123456789ab"
SCHEMA = f"coa_test_{WORLD_ID}_world"


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True)


class FakeMysql:
    def __init__(self, token="t1", connections="0"):
        self.token = token
        self.connections = connections
        self.statements = []

    def __call__(self, statement):
        self.statements.append(statement)
        if "SCHEMATA" in statement:
            return "1\n"
        if "SELECT token" in statement:
            return self.token + "\n"
        if "PROCESSLIST" in statement:
            return self.connections + "\n"
        return ""


class CacheOnlyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        main = self.tmp / "coa"
        (main / "src/server/coa").mkdir(parents=True)
        (main / "src/server/coa/keep").write_text("x")
        (main / ".gitignore").write_text(".cache/\nbuild/\nenv/\n")
        run("git", "init", "-q", cwd=main)
        run("git", "add", ".", cwd=main)
        run("git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init", cwd=main)
        self.worktree = self.tmp / "coa-wt"
        run("git", "worktree", "add", "-q", "-b", "work", str(self.worktree), cwd=main)
        cache = self.worktree / cleanup.CACHE_ROOT / "slots/slot-0/abc"
        cache.mkdir(parents=True)
        self.metadata = cache / "world.json"
        self.metadata.write_text(json.dumps({"world_id": WORLD_ID, "token": "t1", "state": "ready"}))
        self.mysql = FakeMysql()
        self.saved = cleanup.mysql, cleanup.merged_pull_request
        self.foreign_directory = cleanup.foreign_directory
        cleanup.mysql = self.mysql
        cleanup.merged_pull_request = lambda *args: None

    def tearDown(self):
        cleanup.mysql, cleanup.merged_pull_request = self.saved

    def main(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cleanup.main([str(self.worktree), *args])
        return code, out.getvalue(), err.getvalue()

    def test_full_cleanup_refuses_unpushed_worktree(self):
        code, _, err = self.main("--yes")
        self.assertEqual(code, 1)
        self.assertIn("push it first", err)
        self.assertTrue(self.metadata.exists())

    def test_cache_only_dry_run_changes_nothing(self):
        code, out, _ = self.main("--cache-only")
        self.assertEqual(code, 0)
        self.assertIn(f"would drop {SCHEMA}", out)
        self.assertNotIn("worktree", out.replace(str(self.worktree), ""))
        self.assertTrue(self.metadata.exists())
        self.assertFalse(any("DROP" in s for s in self.mysql.statements))

    def test_cache_only_drops_cache_and_keeps_unpushed_worktree(self):
        code, out, _ = self.main("--cache-only", "--yes")
        self.assertEqual(code, 0, out)
        self.assertIn(f"DROP DATABASE `{SCHEMA}`;", self.mysql.statements)
        self.assertFalse(self.metadata.exists())
        self.assertTrue((self.worktree / "src/server/coa/keep").exists())

    def test_cache_only_refuses_leased_cache(self):
        (self.metadata.parent / "lease.json").write_text("{}")
        code, _, err = self.main("--cache-only", "--yes")
        self.assertEqual(code, 1)
        self.assertIn("leased", err)
        self.assertTrue(self.metadata.exists())

    def test_cache_only_refuses_cache_with_connections(self):
        self.mysql.connections = "2"
        code, _, err = self.main("--cache-only", "--yes")
        self.assertEqual(code, 1)
        self.assertIn("connection", err)

    def test_refuses_foreign_owned_directory_before_dropping_anything(self):
        cleanup.foreign_directory = lambda root: str(self.metadata.parent)
        try:
            code, _, err = self.main("--cache-only", "--yes")
        finally:
            cleanup.foreign_directory = self.foreign_directory
        self.assertEqual(code, 1)
        self.assertIn("owned by another user", err)
        self.assertIn("chown -R", err)
        self.assertFalse(any("DROP" in s for s in self.mysql.statements))
        self.assertTrue(self.metadata.exists())

    def test_owned_tree_has_no_foreign_directory(self):
        self.assertIsNone(cleanup.foreign_directory(self.worktree))

    def test_full_cleanup_deletes_pushed_branch_when_main_checkout_lags(self):
        remote = self.tmp / "remote.git"
        run("git", "init", "-q", "--bare", str(remote), cwd=self.tmp)
        main = self.tmp / "coa"
        run("git", "remote", "add", "origin", str(remote), cwd=main)
        (self.worktree / "src/server/coa/fix").write_text("y")
        run("git", "add", ".", cwd=self.worktree)
        run("git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "fix", cwd=self.worktree)
        run("git", "push", "-q", "origin", "work", cwd=self.worktree)
        code, out, err = self.main("--yes")
        self.assertEqual(code, 0, out + err)
        self.assertFalse(self.worktree.exists())
        branches = subprocess.run(["git", "branch", "--list", "work"], cwd=main, capture_output=True, text=True)
        self.assertEqual(branches.stdout.strip(), "")

    def test_cache_only_refuses_main_checkout(self):
        self.worktree = self.tmp / "coa"
        code, _, err = self.main("--cache-only")
        self.assertEqual(code, 1)
        self.assertIn("not a linked worktree", err)


if __name__ == "__main__":
    unittest.main()
