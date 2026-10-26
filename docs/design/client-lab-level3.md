# Client lab, level 3: headless instances probed through a server relay

Date: 2026-10-26
Status: built and measured on one workstation; numbers below are the only ones that count

## Design delta

The [client issue agent design](client-issue-agent.md) answers every probe through SavedVariables, which the client
writes on `/reload`: each answer costs a UI reload and clears the target. Level 3 removes that cost without touching
the client's code or memory:

- **Relay transport.** The worldserver (a CoA server script, `.labprobe` admin command reached over SOAP) whispers
  `CoaProbe\tQ:<req>:<command line>` to the lab character as an addon message, in the character's own name. The
  CoaProbe addon (`Relay.lua`) runs read-only commands only and whispers the JSON answer back to itself in chunks
  `R:<req>:<i>:<n>:<data>` (200 bytes of data, at most 64 chunks); the server swallows those whispers and
  reassembles them, and `coa-lab-relay probe` polls `.labprobe result`. No `/reload`, no SavedVariables write.
  Every answer carries a `loadId` that changes on each UI load.
- **Cheaper client.** `COA_LAB_PROFILE=minimal` writes an 800x600 window and low-cost CVars before every start;
  `COA_LAB_DISPLAY=headless` runs gamescope's headless backend (no window on the desktop, no Hyprland).
- **Instances.** `COA_LAB_INSTANCE=1..9` selects a reflinked copy of the lab client and prefix with its own state
  directory, so several lab clients can run side by side against one slot with different accounts.
- **New probes.** `frame <GlobalName>` (type, shown, visible, text) and `errors` (Lua errors seen by the addon's own
  error handler, chained to the previous handler). On this client the handler is replaced after login, so `errors`
  stays empty; error text is not captured (see "Lua errors" below).

Out of scope, by decision of 2026-10-25: injected or proxy DLLs, reading or writing client memory, lifting
protected Lua functions, anti-cheat or Warden changes, and building a client from decompiled sources. The relay
is ordinary addon-message traffic between the client and our own server.

## Server side

The relay lives in the server repository (`src/server/coa/CoAProbeRelay*`, documented in
`docs/coa/client-lab-probe-relay.md` there). It is off by default; `coa-client-lab relay-setup N` turns it and
SOAP on for one slot (SOAP listens on `0.0.0.0` inside the container, published on the host's `127.0.0.1` only).
Only accounts whose name starts with `COALAB` can be probed, and the relay and the addon each refuse anything
outside the read-only command list.

## Measurements

Filled in from the runs below; every figure names its command.

Setup for every row: slot 2, server `feat/client-lab-probe-relay` `19fc3ccd81` (server repo), `coa-client-lab
preflight 2` PASS (368 of 368 client tables identical), character `Coalabone` (Orc Barbarian, level 1, Valley of
Trials), host 32 threads / 125 GiB, NVIDIA RTX 5070 Ti, load average 5-20 during the runs (other agents were
compiling earlier). Memory from `coa-lab-footprint sample --seconds 60`: Pss and Rss summed over the gamescope tree
and every process of the lab prefix; CPU 100 % = one core. GPU memory from
`nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv`.

### Baseline (readable profile, nested 1920x1080, `/reload` probes)

| Measure | Value |
|---|---|
| `start 2` until the window is found | 10.0 s |
| `login` (fixed sleeps 20 + 25 + 45 s plus typing; not a readiness measure) | 105.5 s |
| `probe ping` on the `/reload` path, twice | 14.8 s, 14.9 s (includes `COA_LAB_RELOAD_WAIT=10`) |
| Login screen, 60 s | Pss 1,557,966 KiB, Rss 1,921,928 KiB, CPU 112.5 % |
| In world, idle, 60 s | Pss 1,974,678 KiB, Rss 2,338,488 KiB, CPU 49.7 % |
| GPU memory in world | Ascension.exe 627 MiB, gamescope 170 MiB |
| Relay `probe spell 501281` in the same session, three times | 428, 229, 242 ms |

### Minimal profile, nested 800x600

CVar check: `strings -n 4 Ascension.exe | grep -xF <name>` in the lab exe. Kept: `maxFPS` (10), `maxFPSBk` (5),
`groundEffectDensity` (16), `environmentDetail` (0.5), `particleDensity` (0.1), `weatherDensity` (0),
`spellEffectLevel` (0), `specular` (0), `projectedTextures` (0), `textureFilteringMode` (0), `baseMip` (1),
`ffxGlow` (0), `ffxDeath` (0), `showfootprints` (0), and `farclip` (177, already in the lab Config.wtf). Dropped:
`gxMultisample` (absent from the exe).

| Measure | Value |
|---|---|
| `start 2` until the window | 7.2 s |
| Login screen, 60 s | Pss 1,374,569 KiB, Rss 1,725,068 KiB, CPU 109.9 % |
| In world, idle, 60 s | Pss 1,806,198 KiB, Rss 2,158,680 KiB, CPU 13.5 % |
| GPU memory in world | Ascension.exe 235 MiB, gamescope 166 MiB |
| Relay `probe spell 501281`, three times | 463, 214, 221 ms |
| Largest process (from `/proc/<pid>/smaps_rollup`) | Ascension.exe Pss 1,304,308 KiB, of which anonymous 1,080,716 KiB |
| 640x480 (`COA_LAB_WIDTH=640 COA_LAB_HEIGHT=480`) | accepted: login screen rendered, screenshot 640x480 |

The login screen keeps a core busy in both profiles; `maxFPS` does not seem to apply there (not investigated).

### Headless + minimal (the level 3 milestone run)

`COA_LAB_PROFILE=minimal COA_LAB_DISPLAY=headless coa-client-lab start 2`, then
`coa-client-lab login COALAB1 <pw> Coalabone`, then `coa-lab-relay probe ...`. Raw answers:
`~/CoaServer/client-lab/evidence/level3-2026-10-26/milestone-1/` (outside git).

| Measure | Value |
|---|---|
| `start 2` until the window on gamescope's Xwayland display (`:1`) | 7.3 s; `hyprctl clients` lists no gamescope window |
| `login` with the default sleeps | returned after 112.8 s; first relay `ping` 0.3 s later, at the first attempt |
| `probe spell 501281`, three in a row | 243, 246, 249 ms; same `loadId` `1792972222-144495`; tooltip line 1 `Fel Fireball` |
| Server DBC `SpellName[enUS]` of 501281 (`coa-dbc-viewer record --id 501281` on a copy of `Spell.dbc`) | `Fel Fireball` |
| `WTF/Account/COALAB1/SavedVariables/CoaProbe.lua` mtime and size, before and after the three probes | `1792971706 856`, unchanged |
| `probe spell 999999999` | `error = "unknown spell 999999999"`, 239 ms |
| `.labprobe send Coalabone r1 eval 1` over SOAP | SOAP fault `not a read-only probe request` |
| In world, idle, 60 s | Pss 1,755,257 KiB, Rss 2,101,924 KiB, CPU 13.0 % |
| GPU memory | Ascension.exe 233 MiB, gamescope 68 MiB (the GPU is still used) |
| `screenshot` | 800x600 PNG, mean intensity 0.133 (not black) |
| `probe frame GameTooltip` | `exists, type GameTooltip, shown false, visible false` |
| `probe errors` after login, and after `chat "/run error('coaprobe-test')"` | `installed false, total 0` both times |

With shorter login sleeps (`COA_LAB_LOGIN_WAIT`, `COA_LAB_REALM_WAIT`, `COA_LAB_WORLD_WAIT`), time from `start`
to the first relay answer: 10/12/0 s → 45.0 s; 6/8/0 s → 36.9 s. Both logins worked at the first try; two runs
are not enough to change the defaults.

Lua errors: the addon's handler is replaced after login and stays replaced. `geterrorhandler()` differs from the
addon's handler while `issecurevariable("seterrorhandler")` and `issecurevariable("geterrorhandler")` are both 1
(read once through the `/reload` path's `eval`), so secure client code takes the handler; a post-hook on
`seterrorhandler` never fired, and both sessions that loaded it showed a "UI Error" line at login (the sessions
without it did not), so it was dropped. What does work: the
client's own reporter prints `|Huierror:|h ... UI Error: an interface error occured ...` as a system message, and
`probe log` captured it one second after `/run error('coaprobe-test')`. Lua errors are therefore detectable
(count and time), not readable (text).

### Three instances in parallel (headless + minimal, sleeps 6/8/0)

`COA_LAB_INSTANCE=1..3 coa-client-lab create-instance` (reflink, under a second each; `df` unchanged), accounts
`COALAB1..3` (characters `Coalabone`, `Coalabtwo`, `Coalabthree`), all started at the same moment.

| Measure | Value |
|---|---|
| Start to first relay answer | 38.8 s, 38.8 s, 38.8 s |
| `probe spell 501281` sent to the three at the same moment | 243, 252, 41 ms; each answer names its own character; tooltip line 1 `Fel Fireball` |
| Pss / CPU per instance in world, 60 s | 1,672,548 KiB / 15.8 %, 1,671,645 KiB / 15.5 %, 1,646,134 KiB / 16.2 % |
| Host `MemAvailable` before and after (`free -m`) | 73,538 → 68,328 MiB (−5,210 MiB for three; the first run: −5,269 MiB) |
| GPU memory | Ascension.exe 235 MiB and gamescope 68-72 MiB each |

The first parallel run showed the same `loadId` on all three clients (`1792972625-176494`): `math.random` repeats
across client processes (`176494` also appeared in two separate loads of one client). The id now adds
`GetTime()` milliseconds; the second run gave three different ids.

### Design targets

| Target | Result |
|---|---|
| Less than 1 GB of RAM per instance | **not met**: Pss 1.6-1.9 GiB per instance; the client's own heap (Ascension.exe anonymous memory, about 1.03 GiB) is the largest part, the Proton/gamescope/Xwayland processes about 0.5 GiB |
| No GPU | **not met** on this host: the headless backend still renders on the NVIDIA GPU. Software rendering needs `vulkan-swrast` (lavapipe) or `xorg-server-xvfb`, neither installed, by decision |
| Ready in game in less than 60 s | **met with shorter login sleeps**: 45.0 s (10/12/0) and 36.9-38.8 s (6/8/0: one single run, two runs of three clients); not met with the default sleeps (113 s) |
| At least 3 instances in parallel | **met** (three headless instances on one slot, simultaneous probes answered correctly) |

## Part 2: reading the lab client's own state

Date: 2026-10-26. Design: `.agents/plans/client-lab-memory-diagnostics/design.md` (server repository). ADR:
[`0001-lab-client-read-only-diagnostics.md`](../adr/0001-lab-client-read-only-diagnostics.md).

The baseline above left two things unreadable: Lua error text ("Lua errors are therefore detectable (count
and time), not readable (text)"), and anything the client's own engine holds that the Lua API does not
expose, such as the raw object manager or a fuller aura record. Three read-only tools close part of that,
each answering a different question:

| Tool | Reads | Answers |
|---|---|---|
| `coa-client-lab probe errors` (relay, CoaProbe `Commands.lua`) | `ERROR_HANDLER_DATABASE.errors.{current,previous}`, a plain Lua global the client's own `ErrorHandler.lua` already fills | what Lua error fired, with its message and stack, not just that one fired |
| [`scripts/coa-lab-mem`](../../scripts/coa-lab-mem) | the lab client's own process memory (`process_vm_readv`): object manager, unit/aura data, `g_spellDB` | what the client's engine holds, independent of what Lua reports |
| [`scripts/coa-lab-packets`](../../scripts/coa-lab-packets) | the worldserver's `PacketLogFile` (`.packetlog` over SOAP) | what the server actually sent, before compression and encryption |

None of the three replaces the others: a mismatch between what the server sent, what the client's engine
holds, and what the Lua API reports is itself the finding these tools exist to surface.

### `probe errors`

Supersedes the baseline's limit above. CoaProbe no longer tries to install its own error handler (dead code
on this client, since the CoA UI overwrites `seterrorhandler` with a no-op after login — see the ADR). It
reads the client's own error log directly: `coa-client-lab probe errors [N] [previous] [locals]` (or
`coa-lab-relay probe errors ...` on a relay-enabled slot) returns the newest `N` entries (default 5, max 20)
with `message`/`stack` (truncated to the relay's byte budget; `locals` opts in, left out by default). A
`/reload` empties `errors.current`; `previous` reads the array as it stood just before the last world entry,
so a reload does not erase the evidence of what happened right before it.

### `coa-lab-mem`

Guards before any read: the target process's executable is under `~/CoaServer/client-lab`; the lab lock
names a slot other than 1; that slot's `worldserver.conf` has `Warden.Enabled = 0`. `check`, `player`,
`unit player|target|0x<guid>` and `objects` read the object manager, active player, one unit or every object;
`spell-db`/`spell ID` read the client's loaded `Spell.dbc` row (record count, min/max id, and per spell: name,
rank, description, tooltip, school mask, duration index, power type, mana cost, icon, range index). The aura
list in every command's output holds only *active* slots (spell id != 0, with their own `slot` index), plus
`slots` (the array's total capacity) and `empty_slots`; a removed aura keeps its slot record internally with
spell id 0, which the tool filters out rather than reports as an aura. Every field carries its own
`"validated": true|false` (see the ADR); unvalidated fields are reported as a hypothesis, not a fact.

### `coa-lab-packets`

`on`/`off` toggle `.packetlog <character>` over SOAP; `list` prints one JSON object per packet (index, time,
direction, opcode name/number, size), filterable by direction, opcode or recency; `auras` decodes
`SMSG_AURA_UPDATE`/`SMSG_AURA_UPDATE_ALL` records (target GUID, spell id, flags, level, stack/charges, caster
GUID when not self-cast, duration when carried). Reads only the on-disk `.pkt` file; never types into the
client or touches the relay. `target_guid` is whatever unit the server sent an update about to this session,
not necessarily the lab character — filter with `--guid` using a GUID obtained elsewhere (`coa-lab-mem`,
`probe state`).

### Limits

- Lab only, one slot at a time, `Warden.Enabled = 0` required: this is a phase-1, lab-only diagnostic, not a
  general anti-cheat bypass (see the ADR for why each guard exists).
- `coa-lab-mem`'s offsets are specific to the validated client build; a silent field shift from a client
  update is why every value stays tied to an explicit `validated` flag rather than being reported on trust.
- `coa-lab-packets` proves what the server sent in one logged session, not what the client did with it.
- An addon's own `seterrorhandler` callback is still dead on this client; only the passive read of
  `ERROR_HANDLER_DATABASE` works.

## Addendum, 2026-10-26 (later session): login, relay-setup and the minimal profile's resolution

Three follow-ups from the batch 19/20 reports, fixed in `scripts/coa-client-lab`, kept here because they touch
numbers and assumptions this file states above rather than new design:

- `login` no longer assumes the account-login screen; see
  [ADR 0003](../adr/0003-login-trusts-only-provable-screen-state.md). The "Measurements" section's `login`
  timings above are unaffected on a fresh client (same typing path); a second `login` in the same session now
  behaves differently (originally: recovers from a proven in-world state, or refuses; see the next addendum
  for why that recovery was replaced) and was not separately re-measured for a fresh-client timing figure here.
- `relay-setup N` now creates or updates the SOAP account itself (`TestLabSoapAccount` in
  `scripts/lab-character`), at `SEC_ADMINISTRATOR`. Previously it only wrote `worldserver.conf`/`coa.conf` and
  `relay.env`; the account had to exist already in that slot's own auth DB (each slot has one), which is what
  left slot 4 answering 401 on `.labprobe` until an agent created `COALABSOAP` by hand.
- The minimal profile's default resolution is 1024x768, not 800x600 (above): at 800x600 the character pane's
  Ranged block runs off the bottom of the window. 1024x768 shows more without letterboxing (which a
  non-4:3 `COA_LAB_HEIGHT` does, confirmed live with 800x720); it is still not a complete fix, since the
  character pane's attribute list is a scrollable Blizzard frame that did not fit unscrolled even at 1280x1024
  with a smaller `/console uiScale`.

## Addendum, 2026-10-26 (follow-up session): login's in-world recovery replaced by a restart

The in-world recovery described in the addendum above (`/camp`, wait, click the character-select Back
button, pixel check) was driven end-to-end inside one `login` process and reproducibly did not reach the
login screen in 4/4 full runs (up to ~330s each); the same click performed as a separate manual step
immediately afterward succeeded in under 20s every time (3/3). The cause of the in-process failure was never
established (not verified) — click coordinates, click form, hover-state, rapid-repeat-click interference and
raw elapsed time were all ruled out live without explaining it.

`login` now restarts the lab client on the same slot (`restart_client` in `scripts/coa-client-lab`) whenever
it is not called on a client that is fresh since `start`, then takes the already-proven fresh-client path
(`LOGIN_WAIT`, pixel check, type). No relay probe ping is required for this any more. `CAMP_WAIT` and
`recover_to_login_screen` are removed. See [ADR 0003](../adr/0003-login-trusts-only-provable-screen-state.md)
for the updated decision and consequences.

## Addendum, 2026-10-26 (L5 session): `login` driven by the client's own glue screen state, read from memory

Addresses found in wowdecomp and validated live (slot 2): `CGlueMgr::m_currentScreen` (char[64], 0x00B6A9E0),
`CCharacterSelection::s_selectionIndex` (int32_t, 0x00AC436C) and `s_characterList`
(`TSGrowableArray<CharacterSelectionDisplay>`, 0x00B6B238; name at each entry's +0x08, entry stride 0x198).
Full file:line provenance and live-validation evidence is in the code comment at each constant in
`scripts/coa-lab-mem` and in [ADR 0004](../adr/0004-login-driven-by-memory-read-glue-state.md). New read-only
command: `coa-lab-mem glue` (`current_screen`, `in_world`, `selection_index`, `characters`). `in_world` comes
from the existing object-manager resolution (ADR 0001), not from the screen string: `m_currentScreen` is not
cleared on entering the world (validated live: it keeps reading the last glue screen's name, e.g.
`"charselect"`, well after the player is in world).

`login` (`scripts/coa-client-lab`) now uses this to: (1) confirm the account-login screen before typing, ahead
of the still-unconditional pixel check; (2) replace the fixed `LOGIN_WAIT`/`REALM_WAIT`/`WORLD_WAIT` sleeps
with bounded polls on the real state, capped at the same constants as upper bounds; (3) navigate the
character-select list to a named character (pressing Down, re-reading the highlighted name from memory until
it matches, bounded by the list's own length) when `login ACCOUNT PASSWORD CHARACTER` is used on a shared
account -- the "character-select navigation is not implemented yet" limitation from the first addendum above
is now implemented when memory is available, with the old client-default-highlight fallback kept for when it
is not.

An in-place recovery from in-world/character-select back to the login screen (`/camp`, then a click on the
character-select "Back" button, each step confirmed by a bounded poll instead of a fixed wait) was tried again
this session, after fixing a real bug (`glue_field` printed Python's `"True"`/`"False"` instead of JSON's
`"true"`/`"false"`, so the in-world branch never matched and the click was attempted from inside the world,
before `/camp`). With the bug fixed, `/camp` reliably reached character-select (2/2), but the Back click still
did not reach the login screen within a 30s bounded poll either time, even though the identical click run as a
separate external command against the same window succeeded instantly both times it was tried standalone --
the same 4/4-in-process-failure, 3/3-standalone-success split the first addendum above already documented, for
a cause this session did not establish either. `login` therefore still restarts for every state memory cannot
already confirm is the login screen (unchanged from the addendum above), but now reaches that restart
immediately instead of spending a further 30s on a transition already shown not to complete in-process.

Measured live, slot 2, 2026-10-26, `COA_LAB_PROFILE=minimal`: a restart-based switch between two dedicated,
already-created, in-world characters took 42.9-49.6s end to end across 6 separate live runs (3 repeated
switches, one fresh start, two shared-account selections by name), each confirmed by a relay probe ping naming
the expected character -- down from 178-228s measured earlier the same session with the fixed sleeps (and the
boolean bug) still in place.

## Addendum (L6, 2026-10-26): the in-place recovery click works as XTEST, not XSendEvent

A later session on the same date (user goal: master every login/logout step to restart or switch accounts as
fast as possible, memory writes authorised but reads preferred; no write was needed) found the in-process click
unreliability above was specific to how the click was delivered, not the click itself. Two candidates were
tried at character-select, live, slot 2:

- **Escape**: sends the key, but `current_screen`/`in_world` never change (5 polls over 5s, before and after).
  A screenshot showed Escape instead opens the client's own Game Menu overlay (Options/Video/Sound/Manage
  Account/Change Realm/Logout/Exit Game/Close) on top of the current glue screen -- not a glue transition.
  Dropped.
- **The same "Back" click, as XTEST fake input** (`xdotool windowactivate --sync "$WINDOW"`, then `mousemove
  --sync X Y` / `click` with **no** `--window`) instead of XSendEvent (`mousemove --window "$WINDOW" ... click
  1`, the form that failed in-process 4/4 in L3/ADR 0003 and 2/2 in L5/ADR 0004): reached the login screen
  **4/4**, driven end to end inside `coa-client-lab login`'s own process -- the exact failure mode the earlier
  sessions hit. See [ADR 0005](adr/0005-in-place-login-recovery-via-xtest-click.md) for the live table, the
  1s-resolution phase breakdown, and why this is shipped even though the measured wall-clock times (43.4-46.0s,
  in-place) landed in the same band as the restart path's own 42.9-49.6s rather than a clear win.

`login` now recovers in place for every state except when the recovery's own bounded polls (`/camp` ->
character-select, 15s cap; the XTEST click -> login screen, 10s cap) do not confirm their result, or memory is
unusable at all -- `restart_client` is unchanged as that fallback.
