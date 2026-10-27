# 0012. `character --spec` writes `character_settings` directly; `login` verifies the in-world character

- Status: accepted (problem 3, the fresh-login retry, is addressed separately: see "Problem 3" below --
  not reproduced in this task's environment, so no fix was made)
- Date: 2026-10-27
- Context: server commit 2d13ffd73a (#5507, "talk to the client through native Extensions.dll packets
  only", `~/Projects/azerothcore-wotlk-coa`) removed `.localspec`/`.localtalent`/`.localspecstate` and every
  other `ASC_LOCAL_*` whisper; Ghost's `ScenarioBot.SetSpecialization` (`e2e/e2eharness/ascension.go`,
  `~/Projects/ConquestOfAzerothGhost`) still whispers `.localspec N`, so `coa-client-lab character --spec N`
  silently stopped doing anything (no error, `character_settings` unchanged). Reported from a "Fix Issues"
  session, batch 21, guide main `c7fa8cc`, server main `dcfa377561`, together with a character-select
  defect (`login` entering the world as the wrong character) and a flaky first-login failure.

## Problem 1: `character --spec`

### Decision

`setActiveSpecialization` (`scripts/lab-character/character_test.go`) replaces the `.localspec` whisper
with a direct `REPLACE INTO character_settings (guid, source, data) VALUES (?, 'core.ascension_active_spec',
'<spec> ')` -- the exact statement and wire format `CHAR_REP_CHAR_SETTINGS`
(`src/server/database/Database/Implementation/CharacterDatabase.cpp`) and
`PlayerSettingsStore::SerializeSettingsData` (`src/server/game/Entities/Player/PlayerSettings.cpp`) already
use. This is a path the server still honors today: `AscensionCompat.cpp`'s `OnPlayerLogin` reads this exact
setting (`ASCENSION_ACTIVE_SPEC_SETTING`) on every login, independent of the native CMSG 0x0727 upload
#5507 introduced, and uses it to populate the in-memory active-specialization map and grant the
specialization's automatic (identity) entries. The alternative considered and rejected was reconstructing a
native 0x0727 upload from the Go harness: it needs the target specialization's identity/signature entry ids
from `ChrSpecs.dbc`/`CharacterAdvancement.dbc`, which the harness has no catalog for (unlike the server's own
`AscensionCoATalentData`), and validates against budget/level rules a hand-built upload could not safely
satisfy for every call site's class/level/existing-build combination.

This only *stages* the switch: the actual spellbook sync (`SynchronizeAutomaticTalents`) happens at the
character's *next* login -- the lab client's own `coa-client-lab login`, not `character`'s own Ghost
session -- matching how `PlayerSettingsStore::UpdateSetting`'s own REPLACE-based design is meant to work for
an offline character.

### What was found live (slot 2, 2026-10-27) that changed the design

A first implementation wrote the setting mid-session (right after `SetLevel`, before `Learn`/`EquipEntry`)
and read it back immediately to confirm the write -- and it reliably reverted to `'0 '` by the time anything
else inspected it. Cause: the character's own `Player` object, created at login with `core.ascension_active_spec`
still `0`, is what actually gets saved -- by `bot.Save(t)` (`.save`), and again by any server-side save this
session still triggers before it disconnects, both using the *in-memory* settings map, not whatever this
helper had written directly to the row in between. `sess.World.Close()` (an abrupt disconnect, not a clean
logout) still triggers a save with that same stale value.

The fix moved the write to *after* an explicit, confirmed logout (`SendLogout` + `WaitForLogout`), on the
theory that `WorldSession::LogoutPlayer`'s `SaveToDB(false, true)` runs, and completes, before
`SMSG_LOGOUT_COMPLETE` is sent (`src/server/game/Server/WorldSession.cpp`, confirmed by reading the function
body: the save call precedes the packet send). This fixed the first character tried (guid 16, spec 34) but
not the next two (guids 17 and 18, spec 36): both read back `'0 '` a few seconds after their own write had
just confirmed the correct value. `SaveToDB` only *queues* the transaction onto `CharacterDatabase`'s async
worker connection; nothing in the client-visible protocol says when that queued write actually lands in
MySQL, so `WaitForLogout` (which only waits for the packet) does not rule out a race against it.

`setActiveSpecialization` now only proves the write landed *at that instant*; the caller
(`TestLabCharacterApply`) re-reads it (without rewriting) every second, and only accepts it once it holds
unchanged across 3 consecutive reads, re-writing and restarting the count on any read that still finds it
reverted, up to 10 attempts. Verified live: spec 36 took three rewrites (~5.1s total) to settle for guid 19,
and held stable 3s after on an independent read. Four further characters (guids 16-21, specs 34/36/34/35/35)
all settled and persisted, confirmed in the database directly (not just the test's own exit code).

### Proof

Four real characters created end-to-end through the fix, each read back from `character_settings` directly
(`docker exec ... mysql ... SELECT data FROM character_settings WHERE guid=? AND source='core.ascension_active_spec'`),
independent of the Go test's own exit status:

| guid | character     | requested spec | `character_settings.data` |
|------|---------------|-----------------|----------------------------|
| 16   | Coalabspecc   | 34              | `34 `                      |
| 19   | Coalabspecf   | 36              | `36 `                      |
| 20   | Coalabspecg   | 35              | `35 `                      |
| 21   | Coalabspech   | 35              | `35 `                      |

The client-shown half of this task's requested proof ("...and, if the client shows it, from a probe") --
logging in with the lab client and reading `coa-client-lab probe ca`'s `activeSpec` field -- was not run:
this task's `relay-setup` call on slot 2 was refused by the harness's own auto-mode classifier
("Modify Shared Resources"), because `relay.env` is a single file shared by every lab-client instance and
another session was actively using it for slot 4 at the time (see "Concerns" in the task report). The
database-level proof above is unaffected by that; it does not depend on the relay.

**Done in L14b** (2026-10-27, ADR 0013): with relay configuration moved to one file per slot, `relay-setup 2`
no longer touches slot 4's file at all, so the live client-probe proof ran: `character --spec 34` on
`COALABSHARE`'s `Sharea`, then `login`, then `probe ca` read `"activeSpec": 34` back.

## Problem 2: `login` entering the world as the wrong character

### Decision

`wait_ui_ready` (`scripts/coa-client-lab`), which every successful `login` already calls to confirm the
in-world UI is ready, now takes the requested character name and checks it against the `character` field
every relayed probe answer carries. `addons/CoaProbe/Relay.lua` already stamps every answer with
`answer.character = UnitName("player")` -- the in-world player's own name -- regardless of which character
name the ping was addressed to; this was already free ground truth, just never read by `login`. A mismatch
is a hard `die` (not swallowed by a caller's `wait_ui_ready || true`, since `die` calls `exit 1` directly); a
relay too old to carry the field only warns, so a plain `{"pong": true}` answer does not block a login that
cannot be verified in that direction. This reuses the same ping `wait_ui_ready` already sends instead of a
second relay round trip.

The alternative considered was a new, separate post-login verification step (and one was built first,
calling the relay a second time with its own `--timeout`). It was replaced because `wait_ui_ready` already
performs an equivalent ping for UI-readiness, and a second round trip through `.labprobe send CHARACTER ...`
(`CoAProbeRelay::FindLabPlayer`, `src/server/coa/CoAProbeRelay.cpp`, which looks the name up online by exact
match) duplicated work for no benefit, and also broke a pre-existing, otherwise-unrelated test (`scripts/tests/coa-client-lab.test.sh`'s "login with character exits 0") whose fixture `relay.env` leaked into later,
unrelated login tests once `write_descriptor`/`wait_ui_ready` started reacting to it.

### Proof

`scripts/tests/coa-client-lab.test.sh` gained two tests exercising `wait_ui_ready`'s new argument directly
against a fake relay: one where the relay confirms the requested character (`login` exits 0), one where it
reports a different one (`login` refuses, with a message naming both). Both pass; the full suite is back to
0 failures after the fix (it ran to 5 failures right after this change landed, from the `relay.env`-leak test
fixture gap described above -- not from the feature itself; fixed by scoping `relay.env` to the relay
sub-tests that already exist for it). Live end-to-end verification (an actual account with two characters,
alternating `login --account A C1`/`C2`) was not run, for the same `relay-setup` refusal as problem 1's
client-probe step.

**Done in L14b** (2026-10-27, ADR 0013): `COALABSHARE`'s `Sharea`/`Shareb` alternated 4 times each (8
switches), the in-world name confirmed correct every time by `probe ping`. The negative case (the check
itself failing loudly) was proven by calling `wait_ui_ready` directly with a wrong expected name against a
real, correctly in-world session, without provoking an actual bad login: it died with "logged in as the
wrong character: requested WrongCharacterName, the relay reports Sharea is in world".

## Problem 3: first-login retry ("account-login screen is not confirmed")

Not reproduced. Six fresh `stop; start 2; login` cycles (same account each time), headless mode
(`COA_LAB_DISPLAY=headless`, the only mode available in this task's environment -- the nested/visible mode
timed out after 120s with no window at all, consistent with no real desktop/compositor session being
available to this agent), all six reached `login sent` on the first attempt; none hit "account-login screen
is not confirmed". A second batch independently reported a related symptom from a different slot (4, same
guide commit `c7fa8cc`): a stale username left in the account field blocked `login` until cleared by hand.
Two further fresh `stop; start 2; login` cycles here, switching accounts each time (`Coalabspecb` then
`Coalabspecf`), both authenticated correctly as the account actually requested -- confirmed server-side
(`characters.online` and the matching `account` id for each guid, not just the script's own exit status),
so the account field was not left stale either time. No fix was made for either symptom: both are
unreproduced defects (`AGENTS.md`'s "Investigating reported defects": classify before changing gameplay or
behavior, and an unreproduced report is not grounds for a change). Possible explanations, not distinguished
further: the race is specific to the nested/visible rendering path this environment cannot run, or it
depends on real GPU/compositor frame timing headless mode (10fps, software) does not reproduce, or it was
already fixed by one of the base branch's own prior commits (`0568776`, `a62523f`, `1d5971e`, `be56a38`,
already present at `c7fa8cc`) before either report's session ran, or it needs a condition (prior client
state, a specific slot's load, timing between an earlier session's exit and this one's `start`) that eight
reproduction attempts across both batches did not happen to hit.

## Consequences

- `character --spec` and `login`'s character check are both pure additions to existing call sites
  (`setActiveSpecialization` is new, called where a dead `bot.SetSpecialization(t, spec.Spec)` used to be;
  `wait_ui_ready` keeps its existing zero-argument call sites working with the check as a no-op). No existing
  command line's documented behavior changed.
- `character --spec` can now take several extra seconds (observed up to ~5s) to settle on a lab environment
  under load, where it used to return in under a second (silently doing nothing). This is the cost of
  verifying the setting actually stuck, not a regression in what it does.
- Open item for whoever continues this: problem 3 stays open, unreproduced in this environment; a nested/
  visible-mode reproduction (or a real GPU-backed headless run) is needed before a state-based wait can be
  designed against an actual observed condition instead of a guess.
- Pre-merge review fixes: the in-world name check ignores case (`login wrkox` matches `Wrkox`), and on a
  mismatch `state/lab.json` is rewritten with the character actually in world before `login` fails, so the
  next switch's `kick_via_soap` targets the right name. `character` passes the account password to its
  request builder through the environment instead of the command line.
