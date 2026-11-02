"""Tests for scripts/coa-verify. Run: python3 -m unittest discover -s scripts/tests -p 'test_*.py'"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "coa-verify"
loader = importlib.machinery.SourceFileLoader("coa_verify", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
coa_verify = importlib.util.module_from_spec(spec)
loader.exec_module(coa_verify)


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True)


class FakeDocker:
    def __init__(self, images=(), running_containers=()):
        self.images = set(images)
        self.running_containers = set(running_containers)
        self.calls = []

    def __call__(self, args, **kwargs):
        self.calls.append(args)
        if args[:3] == ["docker", "image", "inspect"]:
            ok = args[3] in self.images
            return subprocess.CompletedProcess(args, 0 if ok else 1, stdout="", stderr="")
        if args[:2] == ["docker", "ps"]:
            name = args[3].removeprefix("name=^").removesuffix("$")
            out = name + "\n" if name in self.running_containers else ""
            return subprocess.CompletedProcess(args, 0, stdout=out, stderr="")
        raise AssertionError(f"unexpected docker call: {args}")


class FakeRun:
    def __init__(self):
        self.commands = []

    def __call__(self, command, **kwargs):
        self.commands.append(command)
        return subprocess.CompletedProcess(command, 0)


class MainCheckoutTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.main_repo = self.tmp / "coa"
        self.main_repo.mkdir()
        run("git", "init", "-q", cwd=self.main_repo)
        run("git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init", "--allow-empty",
            cwd=self.main_repo)

    def test_main_checkout_of_main_repo_is_itself(self):
        self.assertEqual(coa_verify.main_checkout(self.main_repo), self.main_repo.resolve())

    def test_main_checkout_of_worktree_is_main_repo(self):
        worktree = self.tmp / "coa-wt"
        run("git", "worktree", "add", "-q", "-b", "work", str(worktree), cwd=self.main_repo)
        self.assertEqual(coa_verify.main_checkout(worktree), self.main_repo.resolve())


class DockerChecksTest(unittest.TestCase):
    def test_image_present(self):
        docker = FakeDocker(images={"coa-verify-env:24.04"})
        self.assertTrue(coa_verify.image_present("coa-verify-env:24.04", docker=docker))
        self.assertFalse(coa_verify.image_present("coa-verify-env:25.04", docker=docker))

    def test_mysql_running(self):
        docker = FakeDocker(running_containers={"coa-test-mysql"})
        self.assertTrue(coa_verify.mysql_running("coa-test-mysql", docker=docker))
        self.assertFalse(coa_verify.mysql_running("other", docker=docker))


class RamSettingsTest(unittest.TestCase):
    def test_ram_settings_paths(self):
        tree = Path("/work/coa-wt")
        secrets = Path("/secrets")
        srv = Path("/srv/coa")
        settings = coa_verify.ram_settings(tree, secrets=secrets, srv_coa=srv)
        self.assertEqual(settings["worldserver_config"], "/secrets/worldserver.ram.conf")
        self.assertEqual(settings["database_client_config"], "/secrets/ram-client.cnf")
        self.assertEqual(settings["server_modules_dir"], "/work/coa-wt/env/dist/etc/modules")
        self.assertEqual(settings["modules_config_dir"], "/srv/coa/etc/modules")
        self.assertEqual(settings["dbc_directory"], "/srv/coa/server-data/dbc")

    def test_write_settings_creates_gitignored_cache_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp)
            path = coa_verify.write_settings(tree, {"a": "b"})
            self.assertEqual(path, tree / ".cache/coa-verify/settings.ram.json")
            self.assertEqual(json.loads(path.read_text()), {"a": "b"})


class BuildDockerCommandTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        self.srv = self.tmp / "srv-coa"
        self.ccache = self.tmp / "ccache"
        self.repo.mkdir()

    def test_same_repo_and_tree_mounts_once(self):
        command = coa_verify.build_docker_command(self.repo, self.repo, self.ccache, "coa-verify-env:24.04", [],
                                                    srv_coa=self.srv)
        mounts = [command[i + 1] for i, a in enumerate(command) if a == "-v"]
        self.assertEqual(mounts.count(f"{self.repo}:{self.repo}"), 1)
        self.assertIn(f"{self.ccache}:/ccache", mounts)
        self.assertNotIn(str(self.srv / "server-data"), " ".join(mounts))

    def test_worktree_mounts_both_and_passes_args(self):
        tree = self.tmp / "coa-wt"
        command = coa_verify.build_docker_command(self.repo, tree, self.ccache, "coa-verify-env:24.04",
                                                    ["--stages", "source"], srv_coa=self.srv)
        mounts = [command[i + 1] for i, a in enumerate(command) if a == "-v"]
        self.assertIn(f"{self.repo}:{self.repo}", mounts)
        self.assertIn(f"{tree}:{tree}", mounts)
        self.assertEqual(command[command.index("-w") + 1], str(tree))
        self.assertEqual(command[-2:], ["--stages", "source"])
        w_index = command.index("-w")
        self.assertEqual(command[w_index + 2:w_index + 5], ["coa-verify-env:24.04", "python3", "-B"])

    def test_srv_coa_dirs_mounted_readonly_when_present(self):
        (self.srv / "server-data").mkdir(parents=True)
        (self.srv / "etc").mkdir(parents=True)
        command = coa_verify.build_docker_command(self.repo, self.repo, self.ccache, "coa-verify-env:24.04", [],
                                                    srv_coa=self.srv)
        joined = " ".join(command)
        self.assertIn(f"{self.srv / 'server-data'}:{self.srv / 'server-data'}:ro", joined)
        self.assertIn(f"{self.srv / 'etc'}:{self.srv / 'etc'}:ro", joined)

    def test_env_file_mounted_only_when_present(self):
        command = coa_verify.build_docker_command(self.repo, self.repo, self.ccache, "coa-verify-env:24.04", [],
                                                    srv_coa=self.srv)
        self.assertNotIn("--env-file", command)
        (self.srv).mkdir(parents=True, exist_ok=True)
        (self.srv / "coa.env").write_text("A=1\n")
        command = coa_verify.build_docker_command(self.repo, self.repo, self.ccache, "coa-verify-env:24.04", [],
                                                    srv_coa=self.srv)
        self.assertIn("--env-file", command)
        self.assertEqual(command[command.index("--env-file") + 1], str(self.srv / "coa.env"))

    def test_ram_secrets_mounted_readonly_when_given(self):
        secrets = self.tmp / "secrets"
        command = coa_verify.build_docker_command(self.repo, self.repo, self.ccache, "coa-verify-env:24.04", [],
                                                    srv_coa=self.srv, ram_secrets=secrets)
        joined = " ".join(command)
        self.assertIn(f"{secrets}:{secrets}:ro", joined)


class MainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.main_repo = self.tmp / "coa"
        self.main_repo.mkdir()
        run("git", "init", "-q", cwd=self.main_repo)
        run("git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init", "--allow-empty",
            cwd=self.main_repo)
        self.worktree = self.tmp / "coa-wt"
        run("git", "worktree", "add", "-q", "-b", "work", str(self.worktree), cwd=self.main_repo)
        self.saved = (coa_verify.image_present, coa_verify.mysql_running, coa_verify.run_docker,
                      coa_verify.CCACHE_DIR)
        coa_verify.CCACHE_DIR = self.tmp / "ccache"
        self.fake_run = FakeRun()
        coa_verify.run_docker = self.fake_run

    def tearDown(self):
        (coa_verify.image_present, coa_verify.mysql_running, coa_verify.run_docker,
         coa_verify.CCACHE_DIR) = self.saved

    def call(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = coa_verify.main(["--worktree", str(self.worktree), *args])
        return code, out.getvalue(), err.getvalue()

    def test_refuses_when_image_missing(self):
        coa_verify.image_present = lambda image: False
        code, _, err = self.call("--stages", "source")
        self.assertEqual(code, 2)
        self.assertIn("docker build", err)
        self.assertEqual(self.fake_run.commands, [])

    def test_passes_through_args_when_image_present(self):
        coa_verify.image_present = lambda image: True
        code, _, _ = self.call("--stages", "source")
        self.assertEqual(code, 0)
        self.assertEqual(len(self.fake_run.commands), 1)
        self.assertEqual(self.fake_run.commands[0][-2:], ["--stages", "source"])
        self.assertTrue(coa_verify.CCACHE_DIR.is_dir())

    def test_ram_refuses_when_test_mysql_not_running(self):
        coa_verify.image_present = lambda image: True
        coa_verify.mysql_running = lambda container: False
        code, _, err = self.call("--ram", "--stages", "gameplay")
        self.assertEqual(code, 2)
        self.assertIn("coa-test-mysql", err)
        self.assertEqual(self.fake_run.commands, [])

    def test_ram_writes_settings_and_appends_flag(self):
        coa_verify.image_present = lambda image: True
        coa_verify.mysql_running = lambda container: True
        code, _, _ = self.call("--ram", "--stages", "gameplay")
        self.assertEqual(code, 0)
        settings_path = self.worktree / ".cache/coa-verify/settings.ram.json"
        self.assertTrue(settings_path.is_file())
        self.assertTrue((self.worktree / "env/dist/etc/modules").is_dir())
        command = self.fake_run.commands[0]
        self.assertEqual(command[-4:], ["--stages", "gameplay", "--settings", str(settings_path)])

    def test_ram_does_not_override_explicit_settings(self):
        coa_verify.image_present = lambda image: True
        coa_verify.mysql_running = lambda container: True
        code, _, _ = self.call("--ram", "--settings", "custom.json")
        self.assertEqual(code, 0)
        command = self.fake_run.commands[0]
        self.assertEqual(command[-2:], ["--settings", "custom.json"])


if __name__ == "__main__":
    unittest.main()
