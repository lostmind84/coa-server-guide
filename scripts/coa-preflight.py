#!/usr/bin/env python3
"""Check that the local CoA workstation is in a state where a test result means something.

Run it before reproducing an issue, and again after every rebuild, restart, client patch or DBC install.
Every check below caught a real false result on 2026-09-16:

  git     the checkout contains every commit on origin/main (29 were missing; two "bugs" were already fixed)
  server  the running worldserver was built from the checked-out commit and finished starting
  db      every SQL update shipped by the checkout is recorded as applied (a missing module migration
          put the worldserver in a restart loop)
  client  archives the launcher keeps a NAME.ORIGINAL copy of are reported when a local patch replaced them
  dbc     the server's DataDir/dbc loads with the checkout's formats and holds, byte for byte, the DBC set the
          installed client loads (the client Spell.dbc was once ahead of the server's by 559 texts)

Since jealous-sound/azerothcore-wotlk-coa#1498 the server loads the CoA client's own DBC set. The checkout's
apps/coa-dbc/client_dbc.py defines that set (archive load order, table names) and its format check; this script
imports it from --repo, so it always follows the rules of the code under test.

Differences that belong to work in progress are declared in an expectations file, one per line:

  <dbc file>  <record id or *>  <note>
  Spell.dbc   804216            #391 client GCD patch; the server applies it in AscensionFelswornContracts

An expected difference that is absent is reported too: it usually means a patch was not installed.

Exit status: 0 when nothing failed, 1 otherwise. Needs git, docker and mpqcli
(https://github.com/TheGrayDot/mpqcli). Reads only: it never changes the repository, the databases, the server
data or the client.
"""

import argparse
import hashlib
import importlib.util
import shutil
import struct
import subprocess
import time
from datetime import datetime, timezone
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

HOME = Path.home()

# Spell.dbc string offsets: name, rank, description and tooltip for 16 locales. The locale masks at 152, 169,
# 186 and 203 are plain integers. Used only to tell text drift from numeric drift in the report.
SPELL_STRING_FIELDS = set(range(136, 152)) | set(range(153, 169)) | set(range(170, 186)) | set(range(187, 203))
SPELL_ENUS_STRINGS = (136, 153, 170, 187)

DATABASES = {"world": "acore_world", "characters": "acore_characters", "auth": "acore_auth"}


class Report:
    def __init__(self):
        self.failed = False

    def line(self, level, area, message):
        if level == "FAIL":
            self.failed = True
        print(f"{level:4}  {area:6}  {message}")


WORLDSERVER_BIN = "/azerothcore/env/dist/bin/worldserver"
READY_TIMEOUT = 120


def run(cmd, cwd=None, check=True):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def check_git(report, repo):
    run(["git", "fetch", "origin", "--quiet"], cwd=repo)
    head = run(["git", "rev-parse", "HEAD"], cwd=repo).strip()
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=repo).strip()
    behind = int(run(["git", "rev-list", "--count", "HEAD..origin/main"], cwd=repo))
    ahead = int(run(["git", "rev-list", "--count", "origin/main..HEAD"], cwd=repo))
    if behind:
        report.line("FAIL", "git", f"{branch} is missing {behind} commit(s) from origin/main: rebase or merge first")
    else:
        report.line("PASS", "git", f"{branch} contains origin/main ({ahead} local commit(s) on top)")
    dirty = [l for l in run(["git", "status", "--porcelain"], cwd=repo).splitlines() if not l.startswith("??")]
    if dirty:
        report.line("WARN", "git", f"{len(dirty)} tracked file(s) modified and uncommitted: the binary may not match them")
    return head


def check_server(report, head, container):
    state = run(["docker", "inspect", container, "--format",
                 "{{.State.Running}} {{.State.Restarting}} {{.State.StartedAt}}"], check=False).split()
    if len(state) != 3:
        report.line("FAIL", "server", f"container {container} not found")
        return
    running, restarting, started = state
    if running != "true" or restarting == "true":
        report.line("FAIL", "server", f"{container} is not running cleanly (running={running}, restarting={restarting})")
        return
    # coa-slot start returns before the worldserver has finished loading, so a preflight run right after it
    # would report a red that clears itself seconds later. Wait for the ready line before deciding.
    # Only worth waiting while the container is still young enough to be loading; an older one whose log no
    # longer carries the line will never produce it, and waiting would just add two minutes to a red run.
    age = datetime.now(timezone.utc) - datetime.fromisoformat(started.replace("Z", "+00:00"))
    waited = age.total_seconds() < READY_TIMEOUT
    deadline = time.monotonic() + (READY_TIMEOUT if waited else 0)
    while True:
        logs = subprocess.run(["docker", "logs", "--since", started, container], capture_output=True).stdout
        text = logs.decode("utf-8", "replace")
        if "ready..." in text or time.monotonic() >= deadline:
            break
        time.sleep(3)
    revisions = [l.split("rev.")[1].split()[0] for l in text.splitlines() if "AzerothCore rev." in l]
    if "ready..." not in text:
        report.line("FAIL", "server", f"{container} started at {started} and has not reported ready"
                    + (f" within {READY_TIMEOUT}s" if waited else "; its log carries no ready line"))
    if not revisions:
        report.line("FAIL", "server", "no revision line in the current run's log")
        return
    built = revisions[-1].rstrip("+")
    if not head.startswith(built):
        report.line("FAIL", "server", f"worldserver built from {built}, checkout is at {head[:12]}: rebuild and restart")
    else:
        report.line("PASS", "server", f"worldserver built from the checked-out commit {built}")


def check_harness_image(report, head, container):
    """The coa-gameplay-test image is built FROM the worldserver image, so it bakes its own copy of the
    binary. Rebuilding the worldserver leaves it behind, and scenarios then run the older code while
    everything else here passes. Ask the baked binary what it is rather than comparing image dates: that
    also catches a harness rebuilt from a worldserver image which was itself stale."""
    image = run(["docker", "inspect", container, "--format", "{{.Config.Image}}"], check=False).strip()
    harness = image.replace("ac-wotlk-worldserver", "ac-wotlk-gameplay-test")
    if not image or harness == image:
        report.line("WARN", "harness", f"cannot derive the gameplay-test image from {image or container}")
        return
    if not run(["docker", "image", "inspect", harness, "--format", "{{.Id}}"], check=False).strip():
        report.line("WARN", "harness", f"{harness} does not exist: build it before running scenarios")
        return
    out = run(["docker", "run", "--rm", "--entrypoint", WORLDSERVER_BIN, harness, "--version"], check=False)
    revisions = [l.split("rev.")[1].split()[0] for l in out.splitlines() if "AzerothCore rev." in l]
    if not revisions:
        report.line("WARN", "harness", f"{harness} reported no revision: what it bakes cannot be verified")
        return
    built = revisions[0].rstrip("+")
    if not head.startswith(built):
        report.line("FAIL", "harness", f"{harness} bakes {built}, checkout is at {head[:12]}: scenarios would run "
                    "that binary, not yours. Rebuild it: coa-slot compose N -f "
                    "\"$CLONE/apps/coa-gameplay-test/docker/compose.yml\" --profile tests build ac-gameplay-test")
    else:
        report.line("PASS", "harness", f"gameplay-test image bakes the checked-out commit {built}")


def applied_updates(db_container, schema):
    query = f"SELECT name FROM {schema}.updates"
    out = run(["docker", "exec", db_container, "sh", "-c",
               f'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "{query}" 2>/dev/null'])
    return set(out.split())


def check_db(report, repo, db_container):
    for short, schema in DATABASES.items():
        shipped = {}
        for folder in (f"data/sql/updates/db_{short}", f"data/sql/updates/pending_db_{short}"):
            for path in (repo / folder).glob("*.sql"):
                shipped[path.name] = path.relative_to(repo)
        for path in repo.glob(f"modules/*/data/sql/db-{short}/**/*.sql"):
            shipped[path.name] = path.relative_to(repo)
        missing = sorted(set(shipped) - applied_updates(db_container, schema))
        if missing:
            report.line("FAIL", "db", f"{schema}: {len(missing)} shipped update(s) not applied, run ac-db-import: "
                        + ", ".join(str(shipped[name]) for name in missing[:5]) + (" ..." if len(missing) > 5 else ""))
        else:
            report.line("PASS", "db", f"{schema}: all {len(shipped)} shipped update(s) applied")


def read_expectations(path):
    expected = defaultdict(dict)
    if not path or not path.exists():
        return expected
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 2)
        if len(parts) < 2:
            raise ValueError(f"{path}: expected '<dbc> <id|*> <note>', got {raw!r}")
        expected[parts[0].lower()][parts[1]] = parts[2] if len(parts) > 2 else ""
    return expected


def wdbc_records(raw):
    if raw is None or len(raw) < 20:
        return None
    magic, count, fields, size, strings_size = struct.unpack_from("<4s4I", raw)
    # Records shorter than an id cannot be matched by id: CharBaseInfo.dbc stores two bytes (race, class).
    if magic != b"WDBC" or size < 4 or len(raw) != 20 + count * size + strings_size:
        return None
    records = {struct.unpack_from("<I", raw, 20 + i * size)[0]: raw[20 + i * size:20 + (i + 1) * size]
               for i in range(count)}
    return records, 20 + count * size, fields


def describe_drift(name, client, server):
    """Return {record id: kind} for records that differ, kind being client only/server only/text/numeric/changed.

    An empty result for files whose bytes differ means the records are equal and only the string block or
    its offsets moved; the caller reports that as a layout difference.
    """
    c, s = wdbc_records(client), wdbc_records(server)
    if c is None or s is None:
        return {"*": "not comparable record by record (incomplete file, or records without an id)"}
    (crec, cstr, cfields), (srec, sstr, sfields) = c, s
    drift = {i: "client only" for i in set(crec) - set(srec)}
    drift.update({i: "server only" for i in set(srec) - set(crec)})
    is_spell = name.lower() == "spell.dbc" and cfields == sfields == 234

    def string_at(raw, base, offset):
        end = raw.find(b"\0", base + offset)
        return raw[base + offset:end]

    for i in set(crec) & set(srec):
        if crec[i] == srec[i]:
            continue
        if not is_spell:
            drift[i] = "changed"
            continue
        cr, sr = struct.unpack("<234I", crec[i]), struct.unpack("<234I", srec[i])
        if any(cr[f] != sr[f] for f in range(234) if f not in SPELL_STRING_FIELDS):
            drift[i] = "numeric"
        elif any(string_at(client, cstr, cr[f]) != string_at(server, sstr, sr[f]) for f in SPELL_ENUS_STRINGS):
            drift[i] = "text"
        # otherwise only string offsets moved: same content, not drift
    return drift



def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def load_client_dbc_tool(repo):
    path = repo / "apps/coa-dbc/client_dbc.py"
    if not path.exists():
        raise RuntimeError(f"{path} not found: the checkout predates the client DBC set (#1498)")
    spec = importlib.util.spec_from_file_location("client_dbc", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_client(report, client_data, mpqcli):
    """Report archives a local patch replaced: the launcher keeps the untouched copy as NAME.ORIGINAL."""
    for original in sorted(client_data.rglob("*.ORIGINAL")):
        installed = original.with_name(original.name[:-len(".ORIGINAL")])
        rel = installed.relative_to(client_data)
        if not installed.exists():
            report.line("FAIL", "client", f"{rel} is missing (only {original.name} is present)")
        elif sha256_file(installed) == sha256_file(original):
            report.line("PASS", "client", f"{rel} is the launcher's original")
        else:
            members = subprocess.run([mpqcli, "list", str(installed)], capture_output=True, text=True).stdout
            dbcs = [m for m in members.splitlines() if m.strip().lower().endswith(".dbc")]
            if dbcs:
                report.line("WARN", "client", f"{rel} is a local patch carrying {len(dbcs)} DBC file(s); the DBC "
                            "check below compares the server with what this client loads")
            else:
                report.line("PASS", "client", f"{rel} is a local patch without DBC files")


def check_dbc(report, repo, client_data, server_dbc, expectations, mpqcli):
    tool = load_client_dbc_tool(repo)
    problems, notes = tool.check(server_dbc, root=repo)
    for problem in problems:
        report.line("FAIL", "dbc", f"server set cannot be loaded by this checkout: {problem}")
    if not problems:
        report.line("PASS", "dbc", f"server set passes client_dbc.py check ({len(notes)} note(s))")

    with tempfile.TemporaryDirectory(prefix="coa-preflight-") as workdir:
        client_set = Path(workdir) / "client-dbc"
        # Without --original: the set this installed client really loads, local patches included.
        manifest = tool.extract(client_data, client_set, tool.MpqCli(mpqcli), log=lambda _: None, root=repo)
        identical, archives = 0, defaultdict(int)
        for name, entry in sorted(manifest["files"].items()):
            expected = expectations.get(name.lower(), {})
            server_path = server_dbc / name
            if not server_path.exists():
                report.line("FAIL", "dbc", f"{name}: loaded by the client from {entry['archive']}, missing on the "
                            "server (install the client DBC set)")
                continue
            client_raw, server_raw = (client_set / name).read_bytes(), server_path.read_bytes()
            if client_raw == server_raw:
                if expected:
                    report.line("WARN", "dbc", f"{name}: identical to the client, yet differences are expected for "
                                + ", ".join(f"{k} ({v})" for k, v in expected.items()) + " — patch not installed?")
                identical += 1
                archives[entry["archive"]] += 1
                continue
            rel = entry["archive"]
            if "*" in expected:
                report.line("PASS", "dbc", f"{name}: differs from {rel} as expected ({expected['*']})")
                continue
            drift = describe_drift(name, client_raw, server_raw)
            if not drift:
                report.line("FAIL", "dbc", f"{name}: bytes differ from {rel} although every record is equal "
                            "(string block or layout)")
                continue
            unexpected = {i: k for i, k in drift.items() if str(i) not in expected}
            for key in (k for k in expected if k.isdigit() and int(k) not in drift):
                report.line("WARN", "dbc", f"{name}: record {key} expected to differ ({expected[key]}) but does not")
            if not unexpected:
                matched = sorted((k for k in expected if k.isdigit() and int(k) in drift), key=int)
                report.line("PASS", "dbc", f"{name}: differs from {rel} only on {len(matched)} expected record(s): "
                            + ", ".join(matched[:10]) + (" ..." if len(matched) > 10 else ""))
                continue
            kinds = defaultdict(list)
            for i, kind in unexpected.items():
                kinds[kind].append(i)
            summary = "; ".join(f"{len(ids)} {kind}: " + ", ".join(map(str, sorted(ids, key=str)[:10]))
                                + (" ..." if len(ids) > 10 else "") for kind, ids in sorted(kinds.items()))
            report.line("FAIL", "dbc", f"{name}: server copy differs from the client's ({rel}) — {summary}")
        report.line("PASS", "dbc", f"{identical} of {len(manifest['files'])} client table(s) identical on the server ("
                    + ", ".join(f"{a}: {n}" for a, n in sorted(archives.items(), key=lambda kv: -kv[1])) + ")")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=HOME / "Projects/azerothcore-wotlk-coa")
    parser.add_argument("--client-data", type=Path, default=HOME / "CoaServer/client/ascension-live/Data")
    parser.add_argument("--server-dbc", type=Path, default=Path("/srv/coa/server-data/dbc"))
    parser.add_argument("--expected", type=Path, default=HOME / "CoaServer/preflight-expected.txt")
    parser.add_argument("--worldserver", default="ac-worldserver")
    parser.add_argument("--database", default="ac-database")
    parser.add_argument("--skip-dbc", action="store_true", help="skip the client and DBC checks (about a minute)")
    args = parser.parse_args()

    report = Report()
    try:
        head = check_git(report, args.repo)
        check_server(report, head, args.worldserver)
        check_harness_image(report, head, args.worldserver)
        check_db(report, args.repo, args.database)
        mpqcli = shutil.which("mpqcli")
        if args.skip_dbc:
            report.line("WARN", "dbc", "skipped: client/server data equality not verified")
        elif mpqcli is None:
            report.line("FAIL", "dbc", "mpqcli not installed (github.com/TheGrayDot/mpqcli): client data cannot be "
                        "verified")
        else:
            check_client(report, args.client_data, mpqcli)
            check_dbc(report, args.repo, args.client_data, args.server_dbc, read_expectations(args.expected), mpqcli)
    except (RuntimeError, ValueError, OSError) as error:
        report.line("FAIL", "setup", str(error))

    print("\nRESULT: " + ("FAIL — do not trust test results until this is fixed" if report.failed else "PASS"))
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main())
