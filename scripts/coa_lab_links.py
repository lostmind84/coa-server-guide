#!/usr/bin/env python3
"""Reference the user's client from a lab client instead of copying it (docs/adr/0022-lab-references-the-client.md).

    python3 scripts/coa_lab_links.py select  USER_CLIENT                 # print the selected files
    python3 scripts/coa_lab_links.py sync    USER_CLIENT LAB_CLIENT      # make links and copies, write the manifest
    python3 scripts/coa_lab_links.py check   USER_CLIENT LAB_CLIENT      # what changed in the client since the sync
    python3 scripts/coa_lab_links.py convert USER_CLIENT LAB_CLIENT... [--dry-run]

Selection (which client files a lab references):
  1. the files listed in USER_CLIENT/.coa-launcher/state.json ("files"): what the CoA launcher installed and manages;
     third-party archives the user added by hand are not listed there and are never referenced;
  2. without state.json, the files matching COA_LAB_LINK_PATTERNS (space-separated, case-sensitive globs on the path
     relative to the client, `*` also matches `/`; default DEFAULT_PATTERNS).
  Then the files matching COA_LAB_LINK_EXCLUDE are dropped (default DEFAULT_EXCLUDE: the 64-bit client and the
  renderer files the launcher parks or restores with its DXVK setting; the lab runs Ascension.exe through its own
  Wine prefix). Paths the lab or the client write (PRIVATE_TREES, realmlist.wtf) are never selected.

How a selected file reaches the lab:
  - COA_LAB_COPY globs (default "*.exe *.dll") are private copies, replaced by `sync` when the client's file changes
    and the lab's copy is still the one `sync` wrote. coa-lab-mem identifies the lab client by the real path of its
    mapped Ascension.exe (/proc/PID/maps shows the link's target), so the executable cannot be a link.
  - every other selected file is an absolute symlink to the client's file.

The manifest LAB_CLIENT/.coa-lab-links.json records, per file, the client file's size, mtime and inode at the last
sync. `coa-client-lab start` syncs before launching, so `check` lists what the launcher replaced since the running
lab client started. `convert` turns a copied lab into a linked one: a lab file is replaced only when its size and
sha256 equal the client's; a file that differs is kept and reported.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import sys
import tempfile
import time
from pathlib import Path

MANIFEST = ".coa-lab-links.json"
LAUNCHER_STATE = ".coa-launcher/state.json"
DEFAULT_PATTERNS = "Ascension.exe Extensions.dll Data/*.MPQ Data/area-52/* Data/Content/*"
DEFAULT_EXCLUDE = "CoA64.exe x64/* d3d8.dll d3d9.dll d3d9.dll.DISABLED d3d10core.dll d3d11.dll dxgi.dll dxvk.conf"
DEFAULT_COPY = "*.exe *.dll"
# Lowercase prefixes the lab or the client write: never referenced, whatever a state file lists.
PRIVATE_TREES = ("wtf/", "cache/", "logs/", "dll_logs/", "errors/", "screenshots/", "interface/", ".coa-launcher/")
PRIVATE_NAMES = ("realmlist.wtf",)


class LinkError(Exception):
    pass


def _globs(variable, default):
    value = os.environ.get(variable)
    return (default if value is None else value).split()


def _matches(rel, globs):
    return any(fnmatch.fnmatchcase(rel, pattern) for pattern in globs)


def is_private(rel):
    lower = rel.lower()
    return lower.startswith(PRIVATE_TREES) or lower.rsplit("/", 1)[-1] in PRIVATE_NAMES


def _safe_rel(rel):
    rel = rel.replace("\\", "/")
    parts = rel.split("/")
    if not rel or rel.startswith("/") or any(part in ("", ".", "..") for part in parts):
        raise LinkError(f"unsafe path in the selection: {rel!r}")
    return rel


def _walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".coa-launcher"]
        for name in filenames:
            path = Path(dirpath) / name
            if path.is_file() and not path.is_symlink():
                yield path.relative_to(root).as_posix()


def select(user):
    """Return (source, selected rels, rels listed but absent from the client)."""
    state = user / LAUNCHER_STATE
    if state.is_file():
        try:
            listed = json.loads(state.read_text())["files"]
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise LinkError(f"cannot read {state}: {error}") from None
        source = str(state)
        candidates = [_safe_rel(rel) for rel in listed]
    else:
        patterns = _globs("COA_LAB_LINK_PATTERNS", DEFAULT_PATTERNS)
        source = "COA_LAB_LINK_PATTERNS " + " ".join(patterns)
        candidates = [rel for rel in _walk(user) if _matches(rel, patterns)]
    exclude = _globs("COA_LAB_LINK_EXCLUDE", DEFAULT_EXCLUDE)
    selected, absent = [], []
    for rel in sorted(set(candidates)):
        if is_private(rel) or _matches(rel, exclude):
            continue
        (selected if (user / rel).is_file() else absent).append(rel)
    return source, selected, absent


def _stat(path):
    st = path.stat()
    return {"size": st.st_size, "mtime_ns": st.st_mtime_ns, "ino": st.st_ino}


def sha256(path, cache=None):
    key = str(path)
    if cache is not None and key in cache:
        return cache[key]
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(4 << 20), b""):
            digest.update(block)
    value = digest.hexdigest()
    if cache is not None:
        cache[key] = value
    return value


def same_content(lab_file, user_file, cache):
    return lab_file.stat().st_size == user_file.stat().st_size and sha256(lab_file) == sha256(user_file, cache)


def load_manifest(lab):
    try:
        return json.loads((lab / MANIFEST).read_text())
    except FileNotFoundError:
        return None
    except ValueError as error:
        raise LinkError(f"{lab / MANIFEST} is not valid JSON: {error}") from None


def _copy(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".coa-lab-", dir=dst.parent)
    os.close(fd)
    try:
        with open(src, "rb") as reader, open(tmp, "wb") as writer:
            while block := reader.read(4 << 20):
                writer.write(block)
        st = src.stat()
        os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
        os.chmod(tmp, st.st_mode & 0o777)
        os.replace(tmp, dst)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def _link(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(f".coa-lab-link-{os.getpid()}-{dst.name}")
    tmp.unlink(missing_ok=True)
    tmp.symlink_to(src)
    os.replace(tmp, dst)


def _copy_is_ours(dst, entry):
    """The lab copy is still the file `sync` wrote (same size and mtime as recorded)."""
    if not entry or entry.get("mode") != "copy" or not dst.is_file() or dst.is_symlink():
        return False
    st = dst.stat()
    return st.st_size == entry["size"] and st.st_mtime_ns == entry["mtime_ns"]


def _points_into(path, user):
    if not path.is_symlink():
        return False
    target = Path(os.readlink(path))
    return target.is_absolute() and (target == user or user in target.parents)


def _check_paths(user, lab):
    u, l = user.resolve(), lab.resolve()
    if u == l or u in l.parents or l in u.parents:
        raise LinkError(f"lab path aliases the user's client: {l} vs {u}")


def sync(user, lab, out=print, cache=None):
    """Make LAB reference USER's selected files. Returns the number of private files kept in place of a reference."""
    user = Path(os.path.abspath(user))
    lab = Path(os.path.abspath(lab))
    _check_paths(user, lab)
    source, selected, absent = select(user)
    copy_globs = _globs("COA_LAB_COPY", DEFAULT_COPY)
    previous = (load_manifest(lab) or {}).get("files", {})
    files, counts, private = {}, {"linked": 0, "copied": 0, "unchanged": 0, "removed": 0}, []
    cache = {} if cache is None else cache
    for rel in selected:
        src, dst = user / rel, lab / rel
        mode = "copy" if _matches(rel, copy_globs) or _matches(rel.rsplit("/", 1)[-1], copy_globs) else "link"
        if mode == "link":
            if dst.is_symlink() and os.readlink(dst) == str(src):
                counts["unchanged"] += 1
            elif dst.is_symlink() or not dst.exists() or _copy_is_ours(dst, previous.get(rel)):
                _link(src, dst)
                counts["linked"] += 1
            else:
                private.append(rel)
                continue
        else:
            src_st = src.stat()
            if dst.is_file() and not dst.is_symlink() and dst.stat().st_size == src_st.st_size \
                    and dst.stat().st_mtime_ns == src_st.st_mtime_ns:
                counts["unchanged"] += 1
            elif dst.is_symlink() or not dst.exists() or _copy_is_ours(dst, previous.get(rel)) \
                    or same_content(dst, src, cache):
                _copy(src, dst)
                counts["copied"] += 1
            else:
                private.append(rel)
                continue
        files[rel] = {"mode": mode, **_stat(src)}
        if mode == "copy":
            st = dst.stat()
            files[rel].update(lab_size=st.st_size, lab_mtime_ns=st.st_mtime_ns)
    for rel, entry in previous.items():
        if rel in files:
            continue
        dst = lab / rel
        if _points_into(dst, user) or _copy_is_ours(dst, entry):
            dst.unlink()
            counts["removed"] += 1
    for dirpath, dirnames, filenames in os.walk(lab):
        for name in filenames + dirnames:
            path = Path(dirpath) / name
            rel = path.relative_to(lab).as_posix()
            if rel not in files and _points_into(path, user):
                path.unlink()
                counts["removed"] += 1
    manifest = {"source": str(user), "selection": source, "synced": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "files": files, "private": private}
    tmp = lab / (MANIFEST + ".tmp")
    tmp.write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, lab / MANIFEST)
    out(f"lab references {len(files)} client files from {user} (selection: {source}): "
        f"{counts['linked']} linked, {counts['copied']} copied, {counts['unchanged']} unchanged, "
        f"{counts['removed']} removed")
    for rel in absent:
        out(f"WARN listed but absent from the client, not referenced: {rel}")
    for rel in private:
        out(f"WARN the lab has its own {rel} (differs from the client's or was not written by sync): kept, "
            f"not referenced; `coa-client-lab convert-links` checks it")
    return len(private)


def check(user, lab, out=print):
    """Report the referenced files that changed since the last sync. Returns the number of findings."""
    user = Path(os.path.abspath(user))
    lab = Path(os.path.abspath(lab))
    manifest = load_manifest(lab)
    if manifest is None:
        raise LinkError(f"{lab} has no {MANIFEST}: it copies the client (coa-client-lab convert-links) "
                        "or was never synced (coa-client-lab start)")
    findings = []
    if manifest.get("source") != str(user):
        findings.append(f"SOURCE the lab references {manifest.get('source')}, the configured client is {user}")
    for rel, entry in sorted(manifest["files"].items()):
        src, dst = user / rel, lab / rel
        if not src.is_file():
            findings.append(f"MISSING {rel}: gone from the client")
            continue
        now = _stat(src)
        if (now["size"], now["mtime_ns"], now["ino"]) != (entry["size"], entry["mtime_ns"], entry["ino"]):
            findings.append(f"CHANGED {rel}: size {entry['size']} -> {now['size']}, replaced since the sync")
        if entry["mode"] == "link" and not (dst.is_symlink() and os.readlink(dst) == str(src)):
            findings.append(f"NOT-LINKED {rel}: the lab file is no longer the link to the client's")
        if entry["mode"] == "copy" and not (dst.is_file() and not dst.is_symlink()
                                            and dst.stat().st_size == entry.get("lab_size")
                                            and dst.stat().st_mtime_ns == entry.get("lab_mtime_ns")):
            findings.append(f"COPY-CHANGED {rel}: the lab copy was modified or removed since the sync")
    _, selected, _ = select(user)
    private = set(manifest.get("private", []))
    for rel in selected:
        if rel in private:
            findings.append(f"PRIVATE {rel}: the lab keeps its own file, not the client's (may be stale)")
        elif rel not in manifest["files"]:
            findings.append(f"NEW {rel}: selected now, not referenced at the last sync")
    for line in findings:
        out(line)
    out(f"{len(findings)} change(s) since the sync of {manifest.get('synced')} "
        f"({len(manifest['files'])} files referenced)")
    return len(findings)


def convert(user, labs, dry_run=False, out=print):
    """Replace each lab's copies of selected files by references when they equal the client's. Returns the number
    of files kept because they differ."""
    user = Path(os.path.abspath(user))
    cache, kept_total = {}, 0
    _, selected, _ = select(user)
    copy_globs = _globs("COA_LAB_COPY", DEFAULT_COPY)
    for lab in labs:
        lab = Path(os.path.abspath(lab))
        _check_paths(user, lab)
        if not lab.is_dir():
            raise LinkError(f"no lab client at {lab}")
        freed, replaced, kept = 0, 0, []
        for rel in selected:
            src, dst = user / rel, lab / rel
            if not dst.is_file() or dst.is_symlink():
                continue
            if dst.stat().st_size != src.stat().st_size:
                kept.append(f"{rel}: size {dst.stat().st_size} in the lab, {src.stat().st_size} in the client")
                continue
            if sha256(dst) != sha256(src, cache):
                kept.append(f"{rel}: same size, different sha256")
                continue
            if _matches(rel, copy_globs) or _matches(rel.rsplit("/", 1)[-1], copy_globs):
                continue
            freed += dst.stat().st_size
            replaced += 1
            if not dry_run:
                _link(src, dst)
        for line in kept:
            out(f"KEPT {lab}: {line}")
        verb = "would replace" if dry_run else "replaced"
        out(f"{lab}: {verb} {replaced} identical files by links ({freed / 2**30:.1f} GiB apparent), "
            f"kept {len(kept)} that differ")
        if not dry_run:
            sync(user, lab, out=out, cache=cache)
        kept_total += len(kept)
    return kept_total


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("select")
    p.add_argument("user", type=Path)
    for name in ("sync", "check"):
        p = sub.add_parser(name)
        p.add_argument("user", type=Path)
        p.add_argument("lab", type=Path)
    p = sub.add_parser("convert")
    p.add_argument("user", type=Path)
    p.add_argument("labs", type=Path, nargs="+")
    p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "select":
            source, selected, absent = select(Path(os.path.abspath(args.user)))
            print(f"# selection: {source}")
            for rel in selected:
                print(rel)
            for rel in absent:
                print(f"# absent: {rel}")
            return 0
        if args.command == "sync":
            sync(args.user, args.lab)
            return 0
        if args.command == "check":
            return 1 if check(args.user, args.lab) else 0
        return 1 if convert(args.user, args.labs, dry_run=args.dry_run) else 0
    except (LinkError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
