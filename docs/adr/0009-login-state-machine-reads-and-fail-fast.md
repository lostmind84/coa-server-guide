# 0009. The client's own login state machine drives dialog dismissal and fail-fast, with two measured limits

- Status: accepted
- Date: 2026-10-27
- Extends: ADR 0007/0008's open items (the duplicate-session "disconnected" dialog, the kick's "empty
  output" symptom, the shared-account switch's "could not highlight" failure)

## Context

The controller's own reproduction at the start of this session (L11): after a server `.kick`, the lab client
sits on the account-login screen with a "You have been disconnected from the server" modal over the
Username field. `goto_login_screen_via_memory`'s entry branch (`current_screen == "login" && !in_world`)
returns success without ever checking for this dialog — it was only ever dismissed, unconditionally, right
after this script's own `kick_via_soap` succeeded (ADR 0007) — so a dialog from any other cause (a manual
`.kick`, as reproduced here) was typed into blindly. A second, separate symptom (ADR 0007/0008): `kick_via_soap`
occasionally returns empty output under back-to-back switches, with its stderr discarded, and the
"could not highlight CHARACTER" failure on the shared account (`Memdedi`/`Memtwo`, `Coalabshare`) was never
explained. The user's goal (verbatim, unchanged since L6): master every step of login/logout to switch
accounts or restart the client as fast as possible; memory writes are authorised, reads preferred — this
session only needed reads.

wowdecomp names `CGlueMgr`'s login state machine (`WoW/Source/Glue/CGlueMgr.h:55-70`): `m_loginResult`,
`m_loginState`, `m_lastLoginResult`, `m_lastLoginState`, `m_disconnectPending`, `m_reconnect`,
`m_accountName`, `m_displayingQueueDialog`, `m_showedDisconnect`, `m_serverAlert`. Every address is its own
`// STATIC: 0x...` comment in `WoW/Source/Glue/CGlueMgr.cpp`, immediately preceding the field's definition
(lines 103-257, cited exactly in `scripts/coa-lab-mem`'s own comment); `LOGIN_STATE`/`LOGIN_RESULT` enum
values are from `WoW/Source/WowServices/Types.h:30-71,75-94`, a file unrelated to `CGlueMgr.cpp`.

## What was found, live, slot 2, 2026-10-27

**The addresses are correct, and two independently-sourced enums decode live values exactly.** On the
brief's own reproduction (login screen, dialog visible, screenshot-confirmed), `m_loginState` read `5` and
`m_loginResult` read `21`; `WoW/Source/WowServices/Types.h` independently names `5` as
`LOGIN_STATE_FAILED` and `21` as `LOGIN_DISCONNECTED` — the exact state/result pair for that dialog. Every
new address is also internally consistent with the already-validated `GLUE_CURRENT_SCREEN` (0xB6A9E0,
char[64], ends exactly at the next static) and with itself (`m_accountName`'s declared 1280-byte span ends
exactly at the next static's own address).

**`login_state == LOGIN_STATE_FAILED` does not detect every instance of this dialog.** Also tried live, same
slot, same dialog (screenshot-confirmed both times): a `.kick` on an already-in-world client left
`login_state == 16` (`LOGIN_STATE_DISCONNECTED`, the value already held while legitimately in world) with
the dialog visible — and a client that reached a genuinely clean login screen through the existing
`/camp` + Back-click recovery (screenshot-confirmed: Username field visible, no dialog) read the identical
`16`. `disconnect_pending` and `showed_disconnect` both read `0` in the kicked-dialog case too
(edge-triggered, already consumed by the time the dialog renders). No field read this session distinguishes
a kick-caused dialog from a clean login screen reached the same way; flagged, not invented, for whoever
investigates the dialog's own Lua/FrameXML state next (likely a StaticPopup-style UI tracked outside
`CGlueMgr` entirely).

**`login_state` does not reset when the dialog is dismissed.** A screenshot taken immediately after a
successful Okay click showed a genuinely clean login screen (Username field visible, no dialog) while
`login_state` still read `5` — it only changes on the client's *next* real login/connect attempt. The first
implementation of this session's fix used `login_state != LOGIN_STATE_FAILED` as the post-click confirmation
and consequently reported "dialog still present" on every successful dismiss after the first failure;
corrected to confirm only `current_screen == "login"` afterward (the same bar the pre-L11 code already used
for its one unconditional dismiss), since no stronger memory-based confirmation exists.

**The kick's "empty output" symptom is the `.kick` command's own usage text, not an empty reply, and is a
real, reproducible server-side race.** `kick_via_soap`'s stderr was being discarded (`2>/dev/null`);
un-discarding it (this session) shows every "miss" under back-to-back switching is actually
`coa-lab-relay: Syntax: .kick [$charactername] [$reason]` — `HandleKickPlayerCommand`
(`src/server/scripts/Commands/cs_misc.cpp:1410-1418`) returns `false` with no message whenever the named
target does not resolve to a connected player, and AC's generic command dispatcher reports that as the
command's syntax help; `ns1__executeCommand` (`src/server/apps/worldserver/ACSoap/ACSoap.cpp:140-146`) turns
any `false` return into a SOAP fault carrying that same text. Reproduced reliably (7/8, then 8/8 of a
zero-gap switch run): a `.kick` issued immediately after the *target* character's own world entry fails this
way; the identical call, made again a few seconds later, always succeeded. Widening the retry from 1 (after
1s) to `COA_LAB_KICK_RETRY_ATTEMPTS` (4, 1s apart, both overridable) still did not close the window under
true zero-gap load in every run (observed failing 4/4 attempts at least once); the exact server-side
timing of the name/connected-flag registration this races against was not established further (time
budget; `Server.log` at its default level shows no network/session detail to confirm it from).

**The shared-account "could not highlight CHARACTER" failure has (at least) two real, different causes,
neither a navigation defect.** Reproduced live with a screenshot: in one case, the client was force-
disconnected back to the login screen (the same dialog) *while* `select_character_via_memory` was still
polling character-select, so the character list it kept reading went stale/empty mid-navigation — the same
server-side session instability as the kick race, surfacing mid-charselect instead of mid-login. In another
case, the separate `glue_state` usability check that gates `select_character_via_memory` vs. the
no-confirmation `select_character` fallback failed transiently at exactly that point, sending the switch to
the fallback, which **silently entered the world as the wrong character** (`Shareb` asked for, `Sharea`
entered) with only a `WARN`, not a failure — found via `coa-lab-mem player`, not the script's own output.

## Decision

1. **`coa-lab-mem glue`** gains all ten fields (read-only, `account_name`/`server_alert` included for
   completeness) and two `--until` states: `login-clean` (account-login screen, never yet recorded a failed
   login this session — documented as unreliable for confirming a *dismiss*, only a client that has never
   failed) and `login-settled` (character list loaded, or `login_state == LOGIN_STATE_FAILED`, whichever
   first — used for fail-fast).
2. **`login` dismisses the detectable dialog trigger before typing**, gated on `login_state ==
   LOGIN_STATE_FAILED` (`dismiss_login_dialog_via_memory`, confirmed afterward by `current_screen ==
   "login"`), and **the undetectable trigger unconditionally**, at the one place that already ran
   unconditionally before this session (`goto_login_screen_via_memory`'s entry and in-world-kick branches,
   `clear_login_dialog_unconditionally`) — never a *new* unconditional click at the riskier position next to
   the credential-typing click (ADR 0007's regression site).
3. **After submitting credentials, `login` polls `login-settled`** instead of a fixed `REALM_WAIT` sleep,
   and dies immediately with the client's own `login_result_name` on a recorded failure.
4. **`kick_via_soap` keeps its real answer** (stderr, not discarded) and retries up to
   `COA_LAB_KICK_RETRY_ATTEMPTS` instead of once.
5. **`select_character_via_memory` distinguishes "never matched" (return 1) from "disconnected mid-navigation"
   (return 2)**, checked every poll tick; `cmd_login` reports a different, accurate message for each.
6. **The `glue_state` usability gate before character selection retries** (`GLUE_STATE_RETRY_ATTEMPTS`, 3,
   1s apart) instead of falling back to the unconfirmed `select_character` path on a single transient miss.

No memory write was used or needed, per ADR 0001's limit and this session's own finding (every gap closed
this session needed only reads).

## Consequences

- **Fixed, proven live:** the brief's own reported bug (a leftover dialog typed into blindly after a
  manual `.kick`) — a manual kick followed by `login` now recovers in place, no restart, confirmed in world
  as the right character. A realistic ~2s-paced dedicated-account switch (`Coalabres`/`Labswitch`) now
  completes 8/8 consecutive runs with zero restarts (17-22s each, via the `/camp` fallback landing cleanly
  at this pace even when the kick itself still misses).
- **Not fixed, honestly reported:** true zero-gap (no pause at all) back-to-back switching remains
  unreliable for both account forms, and the shared account (`Coalabshare`) remains unreliable even at the
  ~2s pace (4/8 in the clean re-run) — both trace to the same server-side session-registration race this
  session diagnosed but did not resolve at its root. What changed is that every failure mode along this path
  now reports its real, distinguishing cause (`LOGIN_DISCONNECTED`, `disconnected during character
  selection`, a kick's own SOAP fault text) instead of a misleading generic symptom ("could not highlight",
  silent wrong character, empty output) — the brief's "target: no restart fallback" is met at a realistic
  pace for a dedicated account, not yet for zero-gap scripted load or for the shared account under sustained
  testing.
- `coa-lab-mem glue`'s `login-clean` state is now documented as unreliable for confirming a dismiss
  succeeded (only useful to confirm a client has never yet failed a login this session) — a correction to
  this session's own first implementation, not a pre-existing claim.
- New overridable constants: `COA_LAB_DIALOG_DISMISS_WAIT` (5s), `COA_LAB_KICK_RETRY_ATTEMPTS` (4),
  `COA_LAB_GLUE_STATE_RETRY_ATTEMPTS`/`_WAIT` (3, 1s).
