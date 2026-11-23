import importlib.machinery
import importlib.util
import tempfile
import unittest
import unittest.mock
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("coa_client_dir", SCRIPTS / "coa_client_dir.py")
cd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cd)

loader = importlib.machinery.SourceFileLoader("coa_preflight", str(SCRIPTS / "coa-preflight.py"))
pf_spec = importlib.util.spec_from_loader("coa_preflight", loader)
preflight = importlib.util.module_from_spec(pf_spec)
loader.exec_module(preflight)


class ResolveTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.client = self.root / "client"
        (self.client / "Data").mkdir(parents=True)
        self.warnings = []

    def tearDown(self):
        self._tmp.cleanup()

    def resolve(self, environ):
        return cd.resolve(environ=environ, home=self.home, warn=self.warnings.append)

    def write_config(self, text):
        path = self.home / ".config/coa/client.env"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_unset_everywhere_stops_with_variable_file_and_example(self):
        with self.assertRaises(cd.ClientDirError) as caught:
            self.resolve({})
        message = str(caught.exception)
        self.assertIn("COA_CLIENT_DIR is not set", message)
        self.assertIn("~/.config/coa/client.env", message)
        self.assertIn("COA_CLIENT_DIR=/path/to/your/client", message)

    def test_environment_variable(self):
        found = self.resolve({"COA_CLIENT_DIR": str(self.client)})
        self.assertEqual(found, cd.ClientDir(self.client, "environment COA_CLIENT_DIR"))
        self.assertEqual(self.warnings, [])

    def test_empty_environment_variable_counts_as_unset(self):
        with self.assertRaises(cd.ClientDirError):
            self.resolve({"COA_CLIENT_DIR": ""})

    def test_config_file(self):
        self.write_config(f"# this machine\n\nCOA_CLIENT_DIR={self.client}\n")
        found = self.resolve({})
        self.assertEqual(found, cd.ClientDir(self.client, "~/.config/coa/client.env"))

    def test_config_file_accepts_export_quotes_tilde_and_other_keys(self):
        client = self.home / "Games/my client"
        (client / "Data").mkdir(parents=True)
        self.write_config('OTHER=1\nexport COA_CLIENT_DIR="~/Games/my client"\n')
        self.assertEqual(self.resolve({}).path, client)

    def test_environment_wins_over_file(self):
        self.write_config(f"COA_CLIENT_DIR={self.root / 'elsewhere'}\n")
        self.assertEqual(self.resolve({"COA_CLIENT_DIR": str(self.client)}).path, self.client)

    def test_deprecated_alias_warns_once_and_wins_over_file(self):
        self.write_config(f"COA_CLIENT_DIR={self.root / 'elsewhere'}\n")
        found = self.resolve({"COA_USER_CLIENT": str(self.client)})
        self.assertEqual(found, cd.ClientDir(self.client, "environment COA_USER_CLIENT"))
        self.assertEqual(len(self.warnings), 1)
        self.assertIn("COA_USER_CLIENT is deprecated", self.warnings[0])

    def test_new_variable_wins_over_alias_without_warning(self):
        found = self.resolve({"COA_CLIENT_DIR": str(self.client), "COA_USER_CLIENT": "/nowhere"})
        self.assertEqual(found.path, self.client)
        self.assertEqual(self.warnings, [])

    def test_missing_folder_stops(self):
        with self.assertRaises(cd.ClientDirError) as caught:
            self.resolve({"COA_CLIENT_DIR": str(self.root / "missing")})
        self.assertIn("does not exist", str(caught.exception))

    def test_folder_without_data_stops(self):
        bare = self.root / "bare"
        bare.mkdir()
        with self.assertRaises(cd.ClientDirError) as caught:
            self.resolve({"COA_CLIENT_DIR": str(bare)})
        self.assertIn("has no Data/ directory", str(caught.exception))

    def test_relative_path_stops(self):
        with self.assertRaises(cd.ClientDirError) as caught:
            self.resolve({"COA_CLIENT_DIR": "client"})
        self.assertIn("not an absolute path", str(caught.exception))

    def test_malformed_config_line_stops_with_its_number(self):
        path = self.write_config("# ok\nCOA_CLIENT_DIR\n")
        with self.assertRaises(cd.ClientDirError) as caught:
            self.resolve({})
        self.assertIn(f"{path}:2", str(caught.exception))

    def test_config_file_without_the_key_counts_as_unset(self):
        self.write_config("OTHER=1\n")
        with self.assertRaises(cd.ClientDirError) as caught:
            self.resolve({})
        self.assertIn("COA_CLIENT_DIR is not set", str(caught.exception))


class PreflightClientDataTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_explicit_client_data_is_used_as_is(self):
        data = self.root / "Data"
        data.mkdir()
        self.assertEqual(preflight.resolve_client_data(data), (data, "--client-data"))

    def test_explicit_client_data_must_exist(self):
        with self.assertRaises(ValueError) as caught:
            preflight.resolve_client_data(self.root / "missing")
        self.assertIn("--client-data", str(caught.exception))

    def test_default_is_the_configured_folder_data(self):
        client = self.root / "client"
        (client / "Data").mkdir(parents=True)
        with unittest.mock.patch.dict("os.environ", {"COA_CLIENT_DIR": str(client)}):
            self.assertEqual(preflight.resolve_client_data(None),
                             (client / "Data", "environment COA_CLIENT_DIR"))

    def test_unset_stops_and_names_the_overrides(self):
        home = self.root / "home"
        home.mkdir()
        env = {"HOME": str(home)}
        with unittest.mock.patch.dict("os.environ", env, clear=True):
            with self.assertRaises(ValueError) as caught:
                preflight.resolve_client_data(None)
        message = str(caught.exception)
        self.assertIn("COA_CLIENT_DIR is not set", message)
        self.assertIn("--skip-dbc", message)


if __name__ == "__main__":
    unittest.main()
