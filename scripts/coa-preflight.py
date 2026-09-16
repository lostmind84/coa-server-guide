#!/usr/bin/env python3
"""Check that the local CoA workstation is in a state where a test result means something.

Run it before reproducing an issue, and again after every rebuild, restart or client patch.
Every check below caught a real false result on 2026-09-16:

  git     the checkout contains every commit on origin/main (29 were missing; two "bugs" were already fixed)
  server  the running worldserver was built from the checked-out commit and finished starting
  db      every SQL update shipped by the checkout is recorded as applied (a missing module migration
          put the worldserver in a restart loop)
  dbc     each DBC the server loads is byte-identical to the copy the client actually uses
          (the client Spell.dbc was ahead of the server's by 559 texts and 10 numeric records)

Differences that belong to work in progress are declared in an expectations file, one per line:

  <dbc file>  <record id or *>  <note>
  Spell.dbc   804216            #391 client GCD patch; the server applies it in AscensionFelswornContracts

An expected difference that is absent is reported too: it usually means a patch was not installed.

Exit status: 0 when nothing failed, 1 otherwise. Needs git, docker and smpq (AUR package `smpq`).
Reads only: it never changes the repository, the databases, the server data or the client.
"""

import argparse
import hashlib
import shutil
import struct
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

HOME = Path.home()

# Archive names shipped with the stock 3.3.5a (12340) enUS client. Everything else in Data/ is treated as
# CoA content. A DBC carried by CoA content must match the server exactly; one carried only by stock
# archives only has to match one stock copy, because the stock load order is not verified here.
STOCK_ARCHIVES = {
    "common.MPQ", "common-2.MPQ", "expansion.MPQ", "lichking.MPQ", "patch.MPQ", "patch-2.MPQ", "patch-3.MPQ",
    "enUS/locale-enUS.MPQ", "enUS/speech-enUS.MPQ", "enUS/expansion-locale-enUS.MPQ",
    "enUS/expansion-speech-enUS.MPQ", "enUS/lichking-locale-enUS.MPQ", "enUS/lichking-speech-enUS.MPQ",
    "enUS/patch-enUS.MPQ", "enUS/patch-enUS-2.MPQ", "enUS/patch-enUS-3.MPQ", "enUS/base-enUS.MPQ",
    "enUS/backup-enUS.MPQ",
}

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
    logs = subprocess.run(["docker", "logs", "--since", started, container], capture_output=True).stdout
    text = logs.decode("utf-8", "replace")
    revisions = [l.split("rev.")[1].split()[0] for l in text.splitlines() if "AzerothCore rev." in l]
    if "ready..." not in text:
        report.line("FAIL", "server", f"{container} started at {started} but has not reported ready")
    if not revisions:
        report.line("FAIL", "server", "no revision line in the current run's log")
        return
    built = revisions[-1].rstrip("+")
    if not head.startswith(built):
        report.line("FAIL", "server", f"worldserver built from {built}, checkout is at {head[:12]}: rebuild and restart")
    else:
        report.line("PASS", "server", f"worldserver built from the checked-out commit {built}")


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


def hash_members(archive, names, workdir):
    """Extract every candidate DBC from one archive, return {lowercase name: (sha256, size)} and clean up."""
    target = Path(tempfile.mkdtemp(dir=workdir))
    try:
        subprocess.run(["smpq", "-x", "-q", str(archive)] + [f"DBFilesClient\\{n}" for n in names],
                       cwd=target, capture_output=True)
        found = {}
        for path in target.rglob("*"):
            if path.is_file():
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                found[path.name.lower()] = (digest, path.stat().st_size)
        return found
    finally:
        shutil.rmtree(target, ignore_errors=True)


def extract_one(archive, name, workdir):
    target = Path(tempfile.mkdtemp(dir=workdir))
    subprocess.run(["smpq", "-x", "-q", str(archive), f"DBFilesClient\\{name}"], cwd=target, capture_output=True)
    files = [p for p in target.rglob("*") if p.is_file()]
    return files[0].read_bytes() if files else None


def wdbc_records(raw):
    magic, count, fields, size, strings_size = struct.unpack_from("<4s4I", raw)
    if magic != b"WDBC":
        return None
    records = {struct.unpack_from("<I", raw, 20 + i * size)[0]: raw[20 + i * size:20 + (i + 1) * size]
               for i in range(count)}
    return records, 20 + count * size, fields


def describe_drift(name, client, server):
    """Return {record id: kind} for records that differ, kind being added/removed/text/numeric/changed."""
    c, s = wdbc_records(client), wdbc_records(server)
    if c is None or s is None:
        return {"*": "not a WDBC file"}
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


def check_dbc(report, client_data, server_dbc, expectations):
    names = sorted(p.name for p in server_dbc.glob("*.dbc"))
    archives = sorted(client_data.glob("*.MPQ")) + sorted(client_data.glob("*/*.MPQ"))
    with tempfile.TemporaryDirectory(prefix="coa-preflight-") as workdir:
        carriers = defaultdict(list)  # dbc -> [(archive, relative name, sha256)]
        for archive in archives:
            rel = str(archive.relative_to(client_data))
            for name, (digest, _) in hash_members(archive, names, workdir).items():
                carriers[name].append((archive, rel, digest))

        for name in names:
            server_raw = (server_dbc / name).read_bytes()
            server_digest = hashlib.sha256(server_raw).hexdigest()
            copies = carriers.get(name.lower(), [])
            custom = [c for c in copies if c[1] not in STOCK_ARCHIVES]
            expected = expectations.get(name.lower(), {})

            if not copies:
                report.line("WARN", "dbc", f"{name}: loaded by the server but not found in any client archive")
                continue
            if not custom:
                if any(d == server_digest for _, _, d in copies):
                    continue  # matches a stock copy; stock DBCs are silent when fine
                report.line("FAIL", "dbc", f"{name}: server copy matches none of the stock client copies")
                continue
            if len({d for _, _, d in custom}) > 1:
                report.line("FAIL", "dbc", f"{name}: carried with different content by "
                            + ", ".join(rel for _, rel, _ in custom) + "; resolve which archive the client loads")
                continue

            archive, rel, digest = custom[0]
            if digest == server_digest:
                if expected:
                    report.line("WARN", "dbc", f"{name}: identical in {rel}, yet differences are expected for "
                                + ", ".join(f"{k} ({v})" for k, v in expected.items()) + " — patch not installed?")
                else:
                    report.line("PASS", "dbc", f"{name}: identical to the client copy in {rel}")
                continue

            drift = describe_drift(name, extract_one(archive, name, workdir), server_raw)
            if "*" in expected:
                report.line("PASS", "dbc", f"{name}: differs from {rel} as expected ({expected['*']})")
                continue
            unexpected = {i: k for i, k in drift.items() if str(i) not in expected}
            absent = [k for k in expected if k.isdigit() and int(k) not in drift]
            for key in absent:
                report.line("WARN", "dbc", f"{name}: record {key} expected to differ ({expected[key]}) but does not")
            if not unexpected:
                report.line("PASS", "dbc", f"{name}: differs from {rel} only on expected record(s) "
                            + ", ".join(sorted(expected)))
                continue
            kinds = defaultdict(list)
            for i, kind in unexpected.items():
                kinds[kind].append(i)
            summary = "; ".join(f"{len(ids)} {kind}: " + ", ".join(map(str, sorted(ids)[:10]))
                                + (" ..." if len(ids) > 10 else "") for kind, ids in sorted(kinds.items()))
            report.line("FAIL", "dbc", f"{name}: server copy is out of sync with {rel} — {summary}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=HOME / "Projects/azerothcore-wotlk-coa")
    parser.add_argument("--client-data", type=Path, default=HOME / "CoaServer/client/ascension-live/Data")
    parser.add_argument("--server-dbc", type=Path, default=Path("/srv/coa/server-data/dbc"))
    parser.add_argument("--expected", type=Path, default=HOME / "CoaServer/preflight-expected.txt")
    parser.add_argument("--worldserver", default="ac-worldserver")
    parser.add_argument("--database", default="ac-database")
    parser.add_argument("--skip-dbc", action="store_true", help="skip the DBC comparison (about a minute)")
    args = parser.parse_args()

    report = Report()
    try:
        head = check_git(report, args.repo)
        check_server(report, head, args.worldserver)
        check_db(report, args.repo, args.database)
        if args.skip_dbc:
            report.line("WARN", "dbc", "skipped: client/server data equality not verified")
        elif shutil.which("smpq") is None:
            report.line("FAIL", "dbc", "smpq not installed (AUR package smpq): client data cannot be verified")
        else:
            check_dbc(report, args.client_data, args.server_dbc, read_expectations(args.expected))
    except (RuntimeError, ValueError, OSError) as error:
        report.line("FAIL", "setup", str(error))

    print("\nRESULT: " + ("FAIL — do not trust test results until this is fixed" if report.failed else "PASS"))
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main())
