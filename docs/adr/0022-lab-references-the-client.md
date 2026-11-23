# 0022. The lab client references the user's client instead of copying it

- Status: accepted
- Date: 2026-11-23

## Context

`coa-client-lab create` reflink-copied the whole client folder into `$COA_LAB_ROOT/ascension-lab`, and
`create-instance` reflink-copied that copy. When the client sits on another filesystem (here `/mnt/steam`, the lab
on `/home`), the first copy is a full copy: measured with `btrfs filesystem du` on 2026-11-23, the lab root holds
229.6 GiB of apparent size, 43.6 GiB of shared extents and 1.1 GiB exclusive. The copy also went stale: the lab ran
an older `Extensions.dll` and older patch archives than the client (sizes on 2026-11-23: `Data/patch-B.MPQ` in the
base lab; `patch-B`, `patch-M`, `patch-S`, `patch-T`, `patch-ZG` and `Extensions.dll` in each of the four
instances), which voided a tooltip check. The owner wants one client install to maintain: `COA_CLIENT_DIR`
([ADR 0020](0020-one-per-machine-client-folder.md)).

What was established before choosing:

- What the lab and the client write, from `scripts/coa-client-lab` and the files of the live lab modified after its
  last start: `WTF/` (Config.wtf at every start, SavedVariables), `Data/enUS/realmlist.wtf` (written with `>`, which
  would follow a link into the user's client), `Cache/` (removed at every start), `Interface/AddOns/CoaProbe`,
  `Logs/`, `DLL_Logs/`, `MemoryBridge.log`; the user's client also has `Errors/`, `Screenshots/` and a
  `*.dxvk-cache`.
- What the launcher manages: `.coa-launcher/state.json` lists every file it installed (205 here: executables,
  DLLs, `Data/**`, cinematics, `x64/`) with size and checksum. The third-party HD-mod archives the user added
  (`patch-AAP`, `AAS`, `ZZA`... `ZZZ`) are not in it. Its Repair sweep keeps `WTF/Account`, `Interface/AddOns`,
  `Screenshots`, `WTF/Config.wtf` and any `realmlist.wtf` (CoaLauncher `src-tauri/src/patcher/sweep.rs`).
- How the launcher updates a file: it downloads to a `.part` and renames it over the target
  (`replace_file` in `src-tauri/src/patcher/download.rs`). Its DXVK setting renames `d3d9.dll` to
  `d3d9.dll.DISABLED` and back (`src-tauri/src/dxvk.rs`).
- Wine reads through a link: with GE-Proton11-6's `wine`, `cmd /c copy /b` of a symlinked 3 MB archive produced a
  byte-identical file and `dir` showed its size. A full client launch on a linked lab was not run (the machine's
  shared data switch was in progress).
- `coa-lab-mem` refuses to read a process unless the `Ascension.exe` mapped in `/proc/PID/maps` resolves under the
  lab root. The kernel shows the link's target there (checked with an mmap through a symlink), so a linked
  `Ascension.exe` would make every memory read refuse.

## Considered options

1. Keep copying, and re-copy at every start. Still one duplicate per filesystem, and minutes per start.
2. Hard links. Impossible across filesystems, and the launcher's rename leaves the lab on the old inode: stale again.
3. Symlink the whole client folder or `Data/`. The lab would write `realmlist.wtf`, `Cache` and the addon into the
   user's client.
4. Symlink each launcher-managed file, keep everything written private, copy the executables.

## Decision

Option 4, implemented in `scripts/coa_lab_links.py` and called by `create`, `create-instance` and `start`:

- Selection: the `files` of `.coa-launcher/state.json`; without it, `COA_LAB_LINK_PATTERNS` (an allow-list of
  case-sensitive globs). Then `COA_LAB_LINK_EXCLUDE` (default: `CoA64.exe`, `x64/*` and the DXVK renderer files;
  the owner ruled `Ascension.exe` the reference executable and the HD mods of no interest for the lab). Paths under
  `WTF/`, `Cache/`, `Logs/`, `DLL_Logs/`, `Errors/`, `Screenshots/`, `Interface/`, `.coa-launcher/` and any
  `realmlist.wtf` are never selected.
- `*.exe` and `*.dll` (`COA_LAB_COPY`) are private copies, every other selected file an absolute symlink.
- `start` syncs first: links new files, removes links the launcher dropped, refreshes copies the sync wrote. A file
  the lab has that differs from the client's and was not written by the sync is kept and reported.
- `.coa-lab-links.json` records each client file's size, mtime and inode at the sync; `links-check` reports what
  changed since.
- `convert-links` converts an old copied lab (base and instances): a file is replaced by a link only when its size
  and sha256 equal the client's; a differing one is kept and reported.

## Consequences

- One client to update. The lab's disk use is its private files, the executables (about 20 MB) and the prefix.
- A lab client started after a launcher update uses the new files. A running one keeps the files it opened (the
  launcher renames over them), except files it opens later, such as cinematics; `links-check` lists the changes.
- The lab no longer gets the user's loose `Interface/` files (third-party addons, the `Interface/GLUES` overlay):
  they are not launcher-managed. A converted lab keeps the ones it already had.
- A local patch to a lab file (the old `*.ORIGINAL` workflow) still works: the patched file is private and
  reported as `PRIVATE` by `links-check`, never overwritten.
- If `COA_CLIENT_DIR` is unmounted, `start` stops with the sync error instead of launching a broken lab.
- The lab follows the user's launcher branch and HD setting (`patch-4`, `5`, `Q`, `R`, `U`, `V`, `X`, `Z` are the
  launcher's own HD archives and are in `state.json` when the user enabled them).
