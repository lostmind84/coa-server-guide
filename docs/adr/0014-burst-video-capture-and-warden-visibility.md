# 0014. Burst/video capture in `screenshot`; Warden visibility in `preflight`/`start`

- Status: accepted
- Date: 2026-10-27
- Context: reported from a "Fix Issues" session, batch 22, issue #5797 (Spirit Glaive, slot 4, guide
  `c7fa8cc`): (1) `coa-client-lab screenshot` could not catch a sub-second effect (spell 680906, speed 32,
  5-40yd, airborne roughly 0.15-1.3s; 9 attempts never caught it) -- calls were roughly 2s apart with over
  0.5s dispatch jitter, and a second command dispatch always sat between the action that triggers an effect
  and the capture of it; (2) slot 4 had `Warden.Enabled = 1`, so `coa-lab-mem` and `coa-lab-packets` were
  refused, and the agent only learned this once a tool call had already failed.

## Problem 1: sub-second capture

### Decision

`cmd_screenshot` (`scripts/coa-client-lab`) gains two new forms, both triggered from the same call that can
fire the triggering action, so no second dispatch sits between the action and the first frame:

- `screenshot --burst N [--interval-ms MS] [--dir DIR] [--chat TEXT | --key KEY...]` -- `N` discrete frames
  via `magick import` in a loop, timed against the elapsed time of the previous frame so the requested
  interval is only ever approached, never guaranteed, when the capture tool itself is fast enough.
- `screenshot --video-seconds S [--fps N] [--dir DIR] [--chat TEXT | --key KEY...]` -- one continuous clip
  via `ffmpeg -f x11grab -window_id "$WINDOW" -framerate N -i "$DISPLAY" -t S`, with `-window_id` selecting
  the lab window within the display given as `-i` (ffmpeg's own x11grab demuxer convention: the window id
  alone is not a valid input).

Both write `DIR/timing.tsv` (nanoseconds since epoch): the trigger action's own timestamp, a
`capture_start_ns` line for `--video-seconds` (stamped immediately before the `ffmpeg` call), and, for
`--burst`, every frame's start/end. The legacy `screenshot [PATH]` form (a single PNG, no flags) is
unchanged; the two forms are mutually exclusive (`--burst`/`--video-seconds` together is refused), and
neither accepts a plain `PATH` (they write a directory).

### What was found live (slot 2, 2026-10-27) that changed the design

The original brief's framing assumed the fault was dispatch overhead between separate `screenshot` calls.
Measuring the first implementation's `--burst` mode (12 frames, `--interval-ms 90`, against a real character
casting "Lichfrost" on this same lab setup) found the opposite: `magick import` itself took roughly 2.5s per
frame on this environment's nested gamescope display (1920x1080) -- two orders of magnitude slower than the
`<=100ms` target, and far slower than the dispatch overhead the brief suspected. `--interval-ms`'s
elapsed-time accounting correctly computed zero remaining sleep every time (the capture itself already
exceeded the interval), so the loop ran as fast as `magick import` allowed, and that was still roughly
2.56s between frame starts (measured: min 2533ms, max 2598ms over 11 gaps). **`--burst` cannot reach
sub-second spacing in this environment**, regardless of `--interval-ms`; it remains useful for several
*regular* screenshots (seconds apart) in one dispatch, or where `ffmpeg`/x11grab is unavailable, but the
README and the `coa-client-check` skill now say so plainly instead of implying it meets the brief's original
target.

`--video-seconds` was added as the actual fix, and needed one correction after its own first live attempt:
`-f x11grab -window_id "$WINDOW" -framerate N -t S output` fails outright (`ffmpeg`: "Requested output format
'x11grab' is not known" -- `-f` with no `-i` before it was being read as the *output* format), because
`-window_id` is an x11grab *input* option and needs the display passed as `-i`, which the first version
omitted entirely. With `-i "$DISPLAY"` added, a live capture (triggering "Raise: Lesser Skeletal Warrior",
spell 500970, a self-cast with no target needed -- the first candidate tried, "Lichfrost" rank 1, needed an
enemy target and failed "Target not in line of sight" against the nearby hostile found) produced a 3s clip
`ffprobe` confirmed at a true, evenly spaced 20fps (`r_frame_rate=20/1`, `nb_frames=60` over an exact
`duration=3.000000`) -- 50ms/frame, well inside the brief's `<=100ms`. `capture_start_ns` landed roughly
1.6ms after the trigger action's own timestamp (the gap between two `date +%s%N` calls with nothing but the
`ffmpeg` invocation itself in between); the first frame follows within roughly one frame interval of that.
Extracted frames (`ffmpeg -i clip.mp4 frame-%03d.png`) show the caster's hands glowing green from
roughly frame 0 through roughly frame 40 (the 0-2s region of the 3s clip, matching the spell's own cast
time) and gone by frame 45 -- the transient effect this was built to catch, caught. Evidence kept under
`~/CoaServer/client-lab/evidence/l15/` (the working video capture's `timing.tsv`, `ffmpeg.log` and a sample
of extracted frames; `--burst`'s own slow-frame `timing.tsv` from the Lichfrost attempt, kept as the
measurement that drove this decision).

### Alternatives considered

- Speeding up `magick import` itself (e.g. a smaller capture region) was not pursued: the brief already
  pointed at ffmpeg/x11grab as a known-installed alternative, and a 2.5s cost is intrinsic to invoking a
  separate `import` process per frame against this display, not a tunable flag.
- A second, parallel capture command (a long-running `screenshot --watch` daemon) was rejected as unneeded
  complexity: a single foreground `ffmpeg` call for a bounded duration already satisfies "start in the same
  command as the action", and keeps `cmd_screenshot` a single synchronous call like every other command in
  this script.

## Problem 2: Warden visibility

### Decision

`coa-lab-mem` gains `warden-status --slot N`, reusing `check_warden_disabled` directly (no second
`Warden.Enabled` parser) and needing no running lab client, lock file or pid -- unlike every other
`coa-lab-mem` command, it must work *before* `start` (i.e. from `preflight`), when no lab instance exists
yet for this slot. It prints `{"slot": N, "warden_enabled": true|false, "detail": "..."}` and always exits 0
(the on/off state is the answer, not a failure).

`coa-client-lab`'s new `warden_status_line` (called from both `cmd_preflight` and `cmd_start`, after the
slot number is known) calls it and prints one line: `warden: off on slot N (coa-lab-mem and coa-lab-packets
usable)`, or a `WARN:` naming both tools and the specific risk each faces (`coa-lab-mem`'s own hard guard;
`coa-lab-packets`' dependence on the lab character staying connected, which Warden's anti-cheat scanning
also puts at risk). This is advisory only -- `warden_status_line` never returns non-zero, and neither
`preflight` nor `start` is blocked by a Warden-on slot, matching the brief ("warning only, never blocking
`start`"); Warden is the slot's own configuration, reported here, not changed by this tool.

`coa-lab-packets` itself carries no `Warden.Enabled` check in its own source (grepped; none found), and
nothing in the server's `PacketLog.cpp`/`cs_misc.cpp` `HandlePacketLog` ties packet logging to Warden
either -- unlike `coa-lab-mem`'s guard, which is explicit and confirmed. The brief's report that
`coa-lab-packets` was also refused on the Warden-on slot is taken as given (that session's own finding, not
re-investigated here: out of this task's scope and time budget), and the warning names the plausible
mechanism available from what was read this session -- the packet-log toggle needs the lab character online,
and Warden's anti-cheat scanning is the one thing in this picture that can take a client offline on its
own -- without asserting it as a proven cause. If a future session traces the actual failure mode, this
message should be corrected to match it.

### Proof

Both messages shown in the bash test suite against a fake `worldserver.conf` (never a real slot's
configuration, per `AGENTS.md`): `warden_status_line` sourced directly, `Warden.Enabled = 0` prints the
`off`/usable line and exits 0; `Warden.Enabled = 1` prints the `WARN:` line (naming both tools) and still
exits 0. `test_coa_lab_mem.py` covers `check_warden_disabled`/`warden-status` in isolation (off, on, and a
missing-line conf, all via a mocked `slot_worldserver_conf`) and confirms `warden-status` never calls
`run_guards` (no lock/pid needed). Live on slot 2 (Warden off, the only state available this session without
touching a real slot's configuration): both `preflight 2` and `start 2` printed
`warden: off on slot 2 (coa-lab-mem and coa-lab-packets usable)`.

## Consequences

- `--video-seconds` is now the documented way to catch a sub-second client-visible effect; `--burst`'s own
  real-world frame cost is documented instead of left to be discovered by a failed attempt, as this task's
  own brief was.
- A Warden-on slot is now visible from `preflight`/`start` output alone, before either affected tool is
  tried; the exact failure mode for `coa-lab-packets` under Warden remains unconfirmed and is flagged as
  such in the warning's own wording and here.
