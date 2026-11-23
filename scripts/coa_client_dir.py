#!/usr/bin/env python3
"""Find this machine's CoA client folder: the one shared setting of coa-client, coa-client-lab, coa-lab-mem and
coa-preflight.py (docs/adr/0020-one-per-machine-client-folder.md).

    python3 scripts/coa_client_dir.py      # print the folder, or stop with a message (exit 1)

Order, first match wins:
  1. the environment variable COA_CLIENT_DIR;
  2. the environment variable COA_USER_CLIENT (deprecated alias, prints a one-line warning);
  3. a COA_CLIENT_DIR=... line in ~/.config/coa/client.env (outside the repository, one file per machine).

There is no default folder. The folder must exist and hold a Data/ directory. The file holds KEY=value lines;
blank lines, lines starting with # and an optional leading `export ` are allowed, the value may be quoted and may
start with ~/. Other keys are ignored. The file is parsed, never executed.
"""
import os
import sys
from pathlib import Path
from typing import NamedTuple

VARIABLE = "COA_CLIENT_DIR"
DEPRECATED_VARIABLE = "COA_USER_CLIENT"
EXAMPLE_LINE = f"{VARIABLE}=/path/to/your/client"


class ClientDirError(Exception):
    pass


class ClientDir(NamedTuple):
    path: Path
    source: str


def config_file(home=None) -> Path:
    return Path(home if home is not None else Path.home()) / ".config/coa/client.env"


def _display(path: Path, home: Path) -> str:
    try:
        return "~/" + str(path.relative_to(home))
    except ValueError:
        return str(path)


def read_config(path: Path):
    """Return the COA_CLIENT_DIR value written in PATH, or None when the file or the key is absent."""
    try:
        text = path.read_text()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise ClientDirError(f"cannot read {path}: {error.strerror}") from None
    value = None
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, rest = line.partition("=")
        if not sep or not key.strip():
            raise ClientDirError(f"{path}:{number}: expected KEY=value, got {raw!r} (example: {EXAMPLE_LINE})")
        rest = rest.strip()
        if len(rest) >= 2 and rest[0] == rest[-1] and rest[0] in "\"'":
            rest = rest[1:-1]
        if key.strip() == VARIABLE:
            value = rest
    return value


def _not_set_message(file_shown: str) -> str:
    return (f"no client folder configured: {VARIABLE} is not set.\n"
            f"Write one line in {file_shown} (this machine only, outside the repository), for example:\n"
            f"  {EXAMPLE_LINE}\n"
            f"or export {VARIABLE} for one command. The folder is the one holding Ascension.exe and Data/.")


def resolve(environ=None, home=None, warn=None) -> ClientDir:
    """Return the configured client folder and where the setting came from; raise ClientDirError otherwise."""
    environ = os.environ if environ is None else environ
    home = Path(home if home is not None else Path.home())
    warn = warn or (lambda message: print(message, file=sys.stderr))
    file = config_file(home)
    file_shown = _display(file, home)

    if environ.get(VARIABLE):
        value, source = environ[VARIABLE], f"environment {VARIABLE}"
    elif environ.get(DEPRECATED_VARIABLE):
        warn(f"WARN: {DEPRECATED_VARIABLE} is deprecated, set {VARIABLE} instead (same value)")
        value, source = environ[DEPRECATED_VARIABLE], f"environment {DEPRECATED_VARIABLE}"
    else:
        value, source = read_config(file), file_shown
        if not value:
            raise ClientDirError(_not_set_message(file_shown))

    path = home / value[2:] if value == "~" or value.startswith("~/") else Path(value)
    if not path.is_absolute():
        raise ClientDirError(f"{VARIABLE}={value} (from {source}) is not an absolute path")
    if not path.is_dir():
        raise ClientDirError(f"{VARIABLE}={value} (from {source}) does not exist or is not a directory")
    if not (path / "Data").is_dir():
        raise ClientDirError(f"{VARIABLE}={value} (from {source}) has no Data/ directory: "
                             "is it the client folder (the one holding Ascension.exe)?")
    return ClientDir(path, source)


def main() -> int:
    try:
        print(resolve().path)
    except ClientDirError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
