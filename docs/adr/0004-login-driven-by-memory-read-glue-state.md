# 0004. `login` is driven by the client's own screen state, read from memory

- Status: accepted
- Date: 2026-10-26

## Context

ADR 0003 made `login` safe: it never types credentials onto an unproven screen, and recovers from any non-fresh
state by restarting the lab client, since the only in-process recovery tried (`/camp` + click the
character-select "Back" button) failed 4/4 driven end-to-end inside one `login` process, for a cause never
established.

This session (L5) had read-only access to the lab client's own process memory
(`scripts/coa-lab-mem`, ADR 0001), already used to read in-world unit/spell state. wowdecomp
(`~/Projects/external/wowdecomp`, no licence: addresses and layouts read, no code copied) names the glue screen
state directly:

- `CGlueMgr::m_currentScreen` (`WoW/Source/Glue/CGlueMgr.h:55`, address `WoW/Source/Glue/CGlueMgr.cpp:152`
  `// STATIC: 0x00B6A9E0`): the current glue screen's name (`"login"`, `"charselect"`, ...), set by
  `CGlueMgr::SetScreen` on every glue transition.
- `CCharacterSelection::s_selectionIndex` and `s_characterList`
  (`WoW/Source/Glue/CharacterSelection.h:17-18`, addresses `WoW/Source/Glue/CharacterSelection.cpp:47,62`
  `// STATIC: 0x00AC436C` / `0x00B6B238`): the character-select screen's highlighted index and the loaded
  character list (`TSGrowableArray<CharacterSelectionDisplay>`; name at `CHARACTER_INFO::m_name`,
  `WoW/Source/WowServices/RealmConnection.h:19`, `+0x08` of each `0x198`-byte entry).
- "In world" is not a glue address at all: `m_currentScreen` is **not** cleared or updated on entering the
  world (validated live: it keeps reading `"charselect"` well after the player is in world). The existing
  object-manager resolution (`coa-lab-mem`'s `check`/`player`/`unit`/`objects`, ADR 0001) already answers this:
  it only resolves while a world object manager exists.

Every address above was validated live (screenshot-confirmed at each glue screen, and against an arrow-key
press moving the highlight) before `coa-lab-mem glue` was written against it; see the code comment at each
constant in `scripts/coa-lab-mem` and the session's progress log for the live evidence.

## Options considered

1. Keep ADR 0003 exactly as is (restart on every non-fresh `login`, fixed `LOGIN_WAIT`/`REALM_WAIT`/`WORLD_WAIT`
   sleeps, no character-select navigation by name).
2. Add memory, and use it to **drive** every recovery step in place (the `/camp` + click "Back" transition ADR
   0003 gave up on), replacing the restart entirely.
3. Add memory for what it can prove cheaply and safely, keep the restart where in-place recovery is not proven
   reliable, and use memory to replace every fixed sleep with a bounded poll on the real state.

## Decision

Option 3.

**What memory now does, proven live (slot 2, 2026-10-26):**

- `coa-lab-mem glue` (new command): read-only JSON of `current_screen`, `in_world`, `selection_index` and
  `characters`, built on the addresses above.
- `login` no longer restarts unconditionally on every non-fresh call: `goto_login_screen_via_memory` checks
  whether memory already confirms the account-login screen right now; only if it does not (in world,
  character-select, or memory unusable at all) does it restart, exactly as ADR 0003's restart already did.
- Every fixed sleep (`LOGIN_WAIT`, `REALM_WAIT`, `WORLD_WAIT`) is now a bounded poll (`wait_or_sleep`) on the
  real state memory can see (login screen reached, character-select loaded with its list, in world), capped at
  the same constant as before so the worst case (memory unusable) costs no more than ADR 0003 did. Measured
  live this session: a restart-based switch between two in-world characters dropped from 178-228s (ADR 0003's
  fixed sleeps, after a real bug below was fixed) to **42.9-49.6s** across 6 separate live runs (3 repeated
  switches between two dedicated accounts, one fresh start, two shared-account by-name selections) — close to
  4x faster, with every run confirmed in world by a relay probe ping naming the expected character.
- At character-select, `select_character_via_memory` presses Down and re-reads `selection_index` /
  `characters[selection_index]` from memory until the highlighted name matches the one `login ACCOUNT PASSWORD
  CHARACTER` asked for, bounded by the list's own length; it refuses by name (dies) rather than entering the
  world as an unconfirmed character if it never matches. Proven live on a 2-character shared account
  (`COALABMEMDEDI`): selecting the first character needed no navigation (46s), selecting the second needed one
  Down press and matched by name both times (47s) — the long-standing "character-select navigation is not
  implemented yet" limitation (`select_character`, kept as the fallback when memory is unavailable) is now
  implemented for every session where memory can read the client.

**What memory does not do, and why (tried, not proven, not shipped):**

`goto_login_screen_via_memory` **also tried**, at first, to drive the in-place transition ADR 0003 gave up on
(`/camp` to character-select, click the character-select "Back" button, confirmed by a bounded poll instead of
ADR 0003's fixed waits) before falling back to a restart. A real bug was found and fixed first: `glue_field`
printed Python's capitalized `"True"`/`"False"` for the `in_world` boolean instead of JSON's `"true"`/`"false"`,
so every comparison against those literals silently failed — the in-world branch was skipped, and the stale
`current_screen` value (see above: not cleared on entering the world) coincidentally matched the
character-select branch, so the Back click was being attempted from inside the world, before `/camp` was ever
sent. Fixing the bug made `/camp` run correctly and reliably reach character-select (confirmed live, 2/2 after
the fix, matching every other live `/camp` call this session). The Back click itself still did not reach the
login screen within a 30s bounded poll in either of those 2 full attempts, even though the exact same
`xdotool mousemove --window "$WINDOW" ... click 1` call, run as a separate, external command immediately
afterward against the same window, succeeded instantly every time it was tried standalone this session (as it
also did in the prior L3 session for the same click) — this matches ADR 0003's original 4/4-in-process-failure,
3/3-standalone-success finding exactly, for a cause this session did not establish either (not verified): the
candidates named for a follow-up (a different input delivery than `xdotool ... --window ... click`, a
server-side `.kick` over the lab's SOAP relay instead of a client click, hard-killing the lab client instead of
`cmd_stop`'s graceful shutdown) were not tested, for lack of remaining session time, not because they were
ruled out. `goto_login_screen_via_memory` was simplified to only ever *check* whether the login screen is
already current, never to drive a transition there in place; `click_charselect_back` is kept, unused, as a
documented, working building block for whoever investigates the click's in-process unreliability next.

**Memory writes.** Not used. Every `coa-lab-mem` command, including the new `glue`, stays `process_vm_readv`
read-only, per the mission's hard limit (ADR 0001) and the brief that started this session. A later message in
this session proposed authorizing a memory write if a measured read-only path could not do a step; no step in
this session's scope reached that point (the restart fallback always completes the step; see "what memory does
not do" above), so no write was attempted, and this ADR does not change ADR 0001's read-only decision. A
write-capable approach to the click's in-process unreliability, if ever pursued, needs its own ADR and the
project owner's explicit sign-off before any write syscall is added to `coa-lab-mem` or any other lab tool.

## Consequences

- `login`'s core safety property (ADR 0003: never type credentials onto an unproven screen) is unchanged and,
  if anything, strengthened: memory gives it a second, independent confirmation ahead of the pixel check, which
  still runs unconditionally because it alone also catches a leftover modal dialog layered over a screen whose
  `current_screen` memory value is indistinguishable from the clean case.
- Every repeat login is close to 4x faster than ADR 0003 left it (42.9-49.6s vs. 178-228s measured live this
  session), without reintroducing ADR 0003's original defect (typing onto an unproven screen) and without
  depending on the in-process click this ADR could not make reliable.
- `login CHARACTER` on a shared, multi-character account can now select any character by name when memory is
  available (previously: only the client's own default-highlighted character, with a warning).
- When `coa-lab-mem` cannot run at all (guard refusal, no python3, an address that stops validating against a
  future client build), `login` falls back to exactly ADR 0003's prior behavior: unconditional restart on any
  non-fresh call, fixed sleeps, no navigation by name. This is the same safety net ADR 0003 already was.
- The restart-vs-in-place question ADR 0003 left open is answered the same way for now: still restart, because
  the only in-place transition this session (and L3's before it) tried to drive from inside the script remains
  unproven there, even after fixing a real bug that was contributing to the failure. The candidates this ADR
  lists as not yet tried are the natural next step for whoever picks this up.
