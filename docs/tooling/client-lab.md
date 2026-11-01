# Client lab for agents

Part of the contributor tooling of the CoA server guide (see the [README](../../README.md#part-2-contributor-tooling)). The headless relay mode is in [relay-probes.md](relay-probes.md).


[`scripts/coa-client-lab`](../../scripts/coa-client-lab) runs a separate copy
of the client so an agent can reproduce client-side issues without touching your client. The lab client runs in a
nested gamescope window (1920x1080) on Hyprland workspace 9; you can watch it there. Keyboard input and screenshots
go through gamescope's own X display, so your focus and mouse are never used. One lab client runs at a time.

```bash
coa-client-lab create                      # once: reflink copy of the client and prefix (near-zero disk space)
coa-slot claim 2 "client check"            # the lab client talks to a claimed slot
coa-client-lab character --slot 2 --character Coalabnecro --race 5 --class 23 \
    --level 20 --learn 704723 --items 9701803   # creates/updates its own dedicated account; prints JSON
coa-client-lab preflight 2                 # server and lab client data must match
coa-client-lab start 2
coa-client-lab login Coalabnecro           # resolves the dedicated account and its password itself
coa-client-lab chat "/say hello"
coa-client-lab screenshot                  # prints the PNG path
coa-client-lab hold w 300                  # hold a key down for milliseconds (walk with w/s, turn with Left/Right)
coa-client-lab mute                        # mute this lab client's audio streams by pid (start does it too)
coa-client-lab probe spell 501281          # ask the CoaProbe addon; prints JSON (ping, spell, item, auras, spellbook, known)
coa-client-lab probe log 20                # the addon's capture of UI errors, system messages and casts
coa-client-lab probe state                 # snapshot of the player and current target together
coa-client-lab probe pkwatch 1618 48       # log the next packets with that opcode (48 bytes each) -- survives /reload
                                           #   replaces the client's own handler for that opcode until the client restarts
coa-client-lab probe pksend 1617 u32:1     # build a packet with the client's own CreatePacket/Put*/Send and send it
coa-client-lab probe pkfind                # where CreatePacket, RegisterPacket, Send and ClearPacket live; pkmeta lists the methods
coa-client-lab probe eval GetRealmName()   # evaluate any Lua expression in the client; values as JSON
coa-client-lab probe evwatch ASCENSION_KNOWN_ENTRY_UPDATED   # log that game event's arguments from now on; survives /reload
coa-client-lab stop                        # warns if your own client changed meanwhile
```

**Sub-second capture (L15, 2026-10-27).** A single `screenshot` call is too coarse for an effect that is
airborne or visible for well under a second (a projectile, a brief cast glow): each call is a fresh dispatch,
and whatever drives this script pays its own overhead between two of them. `screenshot --burst N
[--interval-ms MS] [--dir DIR] [--chat TEXT | --key KEY...]` and `screenshot --video-seconds S [--fps N]
[--dir DIR] [--chat TEXT | --key KEY...]` capture several frames (or a short clip) inside *one* call;
`--chat`/`--key` fire the triggering action first, in that same call, so no second dispatch sits between the
action and the first frame. Both print the output directory (or the clip path) and write `DIR/timing.tsv`
(nanoseconds since epoch: the action, and -- for `--burst` -- every frame's start/end).

```bash
coa-client-lab screenshot --video-seconds 3 --fps 20 --chat "/cast Fireball"   # prints DIR/clip.mp4
coa-client-lab screenshot --burst 10 --interval-ms 100 --key 1                 # prints DIR with frame-000.png...
```

Measured live (slot 2, 2026-10-27, nested gamescope at 1920x1080): `--video-seconds` (ffmpeg x11grab) held a
true, evenly spaced 20fps (50ms/frame, `ffprobe` confirmed `nb_frames=60` over an exact 3.000000s) with the
action-to-capture-start gap around 1.6ms -- well inside the `<=100ms` this was built for. `--burst`
(`magick import` per frame) did not: each frame took roughly 2.5s on this same display, regardless of
`--interval-ms`, so **`--burst` cannot reach sub-second spacing here** -- use `--video-seconds` for that and
extract frames from the clip (`ffmpeg -i clip.mp4 frame-%03d.png`) to inspect one. `--burst` still has a use:
several *regular* screenshots (seconds apart is fine) in one dispatch, or environments where ffmpeg/x11grab
is unavailable. Evidence: `~/CoaServer/client-lab/evidence/l15/` (a caster's hands glowing green through
"Raise: Lesser Skeletal Warrior" (spell 500970), caught across roughly 40 of 60 frames; `--burst`'s own
~2.5s/frame timing from a separate run).

**Warden visibility (L15, 2026-10-27).** `coa-lab-mem`'s own guard (`check_warden_disabled`) hard-refuses
every memory read while a slot's `worldserver.conf` does not have `Warden.Enabled = 0`. `coa-lab-packets`
reads the server's own packet log (`.packetlog` over SOAP) and has no Warden check. A prior session only
learned a slot had Warden on once a `coa-lab-mem` call had already failed. `coa-client-lab preflight N` and `start N` now print the slot's Warden state up front
(`coa-lab-mem warden-status --slot N`, reusing `check_warden_disabled` directly instead of a second parser),
and never block on it -- Warden is the slot's own configuration, reported here, not changed by this tool:

```
warden: off on slot 2 (coa-lab-mem usable)
WARN: slot 4 has Warden.Enabled != 0: coa-lab-mem refuses every memory read on this slot's client (its own
guard, see scripts/coa-lab-mem's docstring) until Warden is off. coa-lab-packets reads the server's own packet
log and has no Warden check.
```

The lab copy drops your accounts, remembered login and caches. After a client patch, recreate it:
`coa-client-lab destroy --yes && coa-client-lab create`. The lab client needs an account and a character on the
slot; `coa-client-lab character` (above) creates or updates one through the Ghost e2e harness in one command
(race/class/level/spec/spells/items) on any slot and refuses to change an existing character's class.
It needs [`scripts/lab-character`](../../scripts/lab-character) (a Go module driven as `go test`, since the Ghost
harness is built around `*testing.T`) and a Ghost checkout (`COA_GHOST_REPO`, default
`~/Projects/ConquestOfAzerothGhost`); the checkout path is supplied through a generated `go.work` `replace`
at run time, so `scripts/lab-character/go.mod` never hard-codes one user's home.

**`--spec ID` (L14, 2026-10-27).** Ghost's own `SetSpecialization` whispers `.localspec`, which server
commit 2d13ffd73a (#5507, "talk to the client through native Extensions.dll packets only") removed along
with every other `ASC_LOCAL_*` chat command; the whisper is now silently ignored, so that path stopped doing
anything with no error at all. `--spec` instead writes the character's `character_settings` row for
`core.ascension_active_spec` directly (`setActiveSpecialization`, `scripts/lab-character/character_test.go`)
-- the same setting `AscensionCompat.cpp`'s `OnPlayerLogin` still reads on every login to populate the active
specialization and grant its automatic (identity) entries, independent of the native 0x0727 packet #5507
replaced the whisper with. This only *stages* the switch: the actual spellbook sync happens at the
character's next login (the lab client's own `coa-client-lab login`, not `character`'s own session), exactly
like `PlayerSettingsStore::UpdateSetting`'s own REPLACE-based design, which is meant to work for an offline
character. Writing it only once was not enough in practice: `WorldSession::LogoutPlayer`'s own `SaveToDB`
only *queues* a save onto `CharacterDatabase`'s async worker before sending `SMSG_LOGOUT_COMPLETE`, so a
write made right after that packet arrives can still lose a race against that still-pending save and read
back reverted a few seconds later (reproduced live, slot 2, 2026-10-27: one of three characters in a row).
`--spec` logs the session out, then re-writes and re-reads the row until it holds across several checks in a
row before giving up, instead of trusting a single read-back. Read the setting back from
`character_settings` (or, once logged in through the lab client, `coa-client-lab probe ca`'s `activeSpec`
field) to confirm it took -- there is no chat command any more to confirm it the way `.localspec` itself once
did. The client-shown half (`probe ca`'s `activeSpec`) ran live for the first time in L14b (2026-10-27,
slot 2): `character --spec 34` on a shared account's character, then `login`, then `probe ca` --
`activeSpec` read back `34`, through the slot's own per-slot relay file (below).

Without `--account`, `character` derives a dedicated account for that one character: `COALAB` plus the
upper-cased character name, truncated to `MAX_ACCOUNT_STR` (17; `src/server/game/Accounts/AccountMgr.h:34`
in the server repo) — `DeriveAccount` in `scripts/lab-character`. The `COALAB` prefix matches the relay's
own `CoA.ProbeRelay.AccountPrefix` default, below, so a dedicated account can be probed too. Its password
is generated once with
`openssl rand -hex 16` and kept at `~/CoaServer/client-lab/secrets/<account lower>.password` (mode 600,
reused on later calls, never printed); `login CHARACTER` reads the same account and password back, so
there is never a character list to pick from. The account refuses to pick up a second, differently named
character (a real second character, or a name collision after truncation) — delete it or use a different
name. Pass `--account NAME` to keep a shared account instead, e.g. for account-wide issues (bank,
account-bound items, collections, the char-select screen itself): `character` then warns, but does not
refuse, once that account holds 2+ characters, since character-select navigation by name only works when
lab-client memory is usable this session (next paragraph). A shared account gets the same password
treatment as a dedicated one (L9): its password is generated once and kept at
`~/CoaServer/client-lab/secrets/<account lower>.password` too, and every `character --account NAME ...`
call re-applies it to the account's real DB password (`e2eharness.EnsureAccount` always rewrites
salt/verifier, even for an account that already existed under a different password), so the secret and the
server never drift apart. `login --account NAME CHARACTER` reads that secret back the same way `login
CHARACTER` does for a dedicated account — no password ever appears on a command line. The older
`login ACCOUNT PASSWORD CHARACTER` form still works for any caller that already has the password another
way.

`login` only ever types credentials onto a screen it has just confirmed is the account-login screen: when
`coa-lab-mem glue` (below) is usable, a read-only memory check of `CGlueMgr::m_currentScreen`; the
pixel-brightness check of the logo area still always runs too, since memory alone cannot tell a clean login
screen from a leftover error dialog layered over it. On a fresh client (nothing attempted since `start`) it
waits (now a bounded poll on memory, capped by `COA_LAB_LOGIN_WAIT`, falling back to the old fixed sleep when
memory is unusable) and checks directly.

On any other state, `login` now recovers **in place**, without restarting the client. In world, it first
tries `kick_via_soap` (`.kick CHARACTER` over the lab SOAP relay, `coa-lab-relay soap`, reading `CHARACTER`
from this session's own `state/lab.json`): confirmed live, slot 2, 2026-10-26, this lands directly on the
login screen (no character-select leg) within `COA_LAB_KICK_WAIT` (8s cap, measured ~3-5s), dismissed by one
XTEST click at the account field's own position (`click_login_dialog_dismiss`) for the resulting "disconnected"
dialog. One retry after `COA_LAB_KICK_RETRY_WAIT` (1s) covers a brief registration race right at the
world-entry boundary; any other kick failure (no SOAP relay set up for this slot, unknown character, SOAP
fault) falls back to the older path: `/camp` (confirmed by a bounded poll for character-select,
`COA_LAB_CAMP_WAIT`, 15s cap), then the character-select "Back" button via XTEST fake input (`xdotool
windowactivate --sync`, then `mousemove --sync` / `click` with no `--window`), confirmed by a bounded poll for
the login screen (`COA_LAB_CHARSELECT_BACK_WAIT`, 10s cap). This is the XTEST form of the click — an earlier
XSendEvent form (`xdotool mousemove --window "$WINDOW" ... click 1`) was tried twice, in two separate
sessions, and failed to reach the login screen when driven inside one `login` process both times (4/4, then
2/2 after fixing a real bug in the second attempt — see
[ADR 0004](../../docs/adr/0004-login-driven-by-memory-read-glue-state.md)), even though the exact same XSendEvent
click succeeded every time it was run as a separate, external command against the same window. The XTEST form
reached the login screen 4/4 driven in-process in that session (XSendEvent's own exact failure mode) — see
[ADR 0005](../../docs/adr/0005-in-place-login-recovery-via-xtest-click.md). `restart_client` (stop then start on the
same slot, same instance/profile/resolution) is kept as the final fallback whenever none of the above confirms
its result within its bound, or memory is unusable at all — unchanged from
[ADR 0003](../../docs/adr/0003-login-trusts-only-provable-screen-state.md); `coa-client-lab stop && start N` still
reaches the same clean state manually, if needed. Measured live, slot 2, 2026-10-26: in-place switches between
two in-world dedicated accounts landed the kick 13.5-13.8s whenever it confirmed (repeatedly reproduced);
`/camp`'s own completion time varied widely under this task's heavy test load (2.6s, ADR 0005, up to 60s+
observed once), so a kick miss falls through to the same ~42-46s band the restart path has always measured —
see [ADR 0007](../../docs/adr/0007-soap-kick-replaces-camp-for-in-world-recovery.md) for the full investigation,
including the earlier `/camp`-timeout misdiagnosis and the shared-account (`Memdedi`/`Memtwo`) defect this task
could not fix (blocked by the agent sandbox, not a code gap).

**The client's own login state machine (L11, 2026-10-27).** `coa-lab-mem glue` also reads ten
`CGlueMgr` statics (`m_loginResult`, `m_loginState`, `m_lastLoginResult`, `m_lastLoginState`,
`m_disconnectPending`, `m_reconnect`, `m_accountName`, `m_displayingQueueDialog`, `m_showedDisconnect`,
`m_serverAlert`; addresses and the `LOGIN_STATE`/`LOGIN_RESULT` enum names are wowdecomp file:line citations
in `scripts/coa-lab-mem`'s own comment) and two new `--until` states, `login-clean` and `login-settled`. Two
real, live-measured limits, not fixed by this session (documented honestly rather than papered over):
`login_state == LOGIN_STATE_FAILED` (5) reliably detects only one of the two triggers for the "You have been
disconnected from the server" dialog — the client's own login attempt rejected (wrong password, already
online, a duplicate-session disconnect during realm-connect) — not the other (an already-in-world client
kicked, by this script or anyone else: measured `login_state == 16` on both a kicked-and-dialog-showing
client and a genuinely clean login screen reached by `/camp` + Back, identically); and `login_state` is
sticky, not reset by dismissing the dialog, so it cannot confirm a dismiss succeeded either (only
`current_screen == "login"` can, the same bar the pre-L11 code already used). `login` dismisses the
detectable case before typing (`dismiss_login_dialog_via_memory`) and the undetectable one unconditionally,
reconfirmed by memory afterward, at the one place that already needed to run unconditionally
(`goto_login_screen_via_memory`'s own entry and in-world-kick branches — `clear_login_dialog_unconditionally`,
proven harmless on a dialog-free screen); after submitting credentials it polls `login-settled` and fails
fast with the client's own `login_result_name` (`LOGIN_DISCONNECTED`, `LOGIN_INCORRECT_PASSWORD`, ...)
instead of waiting out `COA_LAB_REALM_WAIT` on every failure.

`kick_via_soap`'s stderr is no longer discarded, and retries widened from 1 to `COA_LAB_KICK_RETRY_ATTEMPTS`
(4, 1s apart): under a true zero-gap switch this now surfaces the kick's real answer — the `.kick` command's
own usage/syntax text, from `HandleKickPlayerCommand` (`src/server/scripts/Commands/cs_misc.cpp:1410-1418`)
returning `false` with no message when the target does not resolve to a connected player, which
`ns1__executeCommand` (`src/server/apps/worldserver/ACSoap/ACSoap.cpp:140-146`) turns into a SOAP fault
carrying that text — not empty output as reports/l8/l10 described (their own call discarded stderr). This
reads as a short-lived server-side name/connected-flag registration race in the ~1-2s right after the
*target* character's own world entry; the same call always succeeded a few seconds later in every
reproduction this session. Widening the retry closed it at a realistic ~2s operator pace (dedicated-account
proof: 8/8 consecutive switches, 0 restarts) but not under true zero-gap scripted load, where it can persist
well past 4 attempts and, once one login is rejected (`LOGIN_DISCONNECTED`), every subsequent attempt on the
same client connection fails the same way — even for an unrelated account — until the client is restarted;
not established further at the worldserver/socket level (time budget).

`select_character_via_memory` now tells a genuine "never matched while still on character-select" apart from
"the client was disconnected back to the login screen mid-navigation" (return 1 vs. 2, checked each poll
tick): live-reproduced, slot 2, a shared-account switch under sustained load hit the latter (screenshot:
the "disconnected" dialog, mid-`Down`-press) and the pre-L11 code reported the misleading "could not
highlight CHARACTER" either way. `cmd_login` also retries the (separate, expensive) `glue_state` usability
check up to `COA_LAB_GLUE_STATE_RETRY_ATTEMPTS` (3, 1s apart) before falling back to `select_character`
(no name confirmation): live-reproduced once, a single transient `glue_state` miss at this exact point sent
a switch to that fallback, which silently entered the world as the wrong character (asked for `Shareb`, got
`Sharea`) with only a `WARN`, not a failure.

`login`'s CHARACTER argument (both forms) picks that character on the character-select screen by name when
`coa-lab-mem glue` is usable: `select_character_via_memory` presses Down and re-reads the highlighted name from
memory until it matches, bounded by the list's own length, and refuses (dies) rather than entering the world as
an unconfirmed character if it never matches. Proven live on a 2-character shared account: the first character
needed no navigation, the second needed one Down press and matched both times. When memory is unavailable, the
previous behavior is unchanged: the lookup still reports the character's index, but navigation itself falls
back to whatever the client already has highlighted (live on slot 2 the list wraps circularly instead of
clamping at the top, so a fixed Up-then-Down sequence without reading the result back is not reliable; see the
comment on `select_character` in `scripts/coa-client-lab`). This is moot for a dedicated account (nothing to
pick between).

**`RBAC_PERM_INSTANT_LOGOUT` and the same-account in-place switch (L12, 2026-10-27).** `character` now grants
RBAC permission 1 (`src/server/game/Accounts/RBAC.h:52`) to the account it just created or re-applied a password
to, over the lab SOAP relay (`.rbac account grant ACCOUNT 1`); `rbac-grant --account NAME` is the same grant as
a standalone, idempotent command for an account created before this change. Both refuse (warn, not die, for
`character`'s own call; die for the standalone command) any account name that does not start with `COALAB`
— this grant is scoped to lab accounts and never reaches a real player account. Grepping every
`RBAC_PERM_INSTANT_LOGOUT`/`HasPermission(1` use confirmed this permission has exactly one effect:
`HandleLogoutRequestOpcode` (`MiscHandler.cpp:535-536`) calls `LogoutPlayer(true)` immediately instead of
arming the normal 20s delay. `login`'s same-account character switch (new character shares the account
already logged in this session) uses this to skip the login screen entirely: `goto_charselect_via_memory`
logs out to character-select via `/camp` (confirmed by a bounded poll, `COA_LAB_INSTANT_LOGOUT_WAIT`, 8s cap)
without ever reaching the login screen, then `select_character_via_memory` picks the new character by name —
no credential retype, no account-field click, no realm-connect round trip. Any failure along this path (the
account differs from the one already logged in, the logout does not confirm in time, the name is never
highlighted) falls through to the full different-account recovery below exactly as if this had not run.

Measured live, slot 2, 2026-10-27, `Coalabshare`'s `Sharea`/`Shareb`: this path never failed the overall switch
(15/15 live attempts across this session succeeded, whether via the fast path or its fallback) and reached
6.3-8.6s when the fast path landed, against the ~18-37s a full relogin costs. It did not land reliably,
though: only 1 fast switch in roughly every 7-9 attempts. The cause was the previous `login` returning at the
memory `in_world` signal, about 9 s before the in-world UI takes input, so the next `/camp` was typed into the
loading screen and lost. `login` now returns only once the addon answers a relay ping (`COA_LAB_UI_READY_WAIT`,
30 s): zero-gap same-account switches then took the fast path 5/5, 14-15 s each (ADR 0010, addendum).

A zero-gap switch back to a shared account is sometimes disconnected by the server while the character list is
shown (about 1 in 10; cause open). `login` then restarts the client and logs in once more
(`COA_LAB_LOGIN_ATTEMPTS`, default 2): 15/15 mixed switches reached the right character, 13-23 s each, one at
73 s through that retry. After a `.kick`, `login` also waits for the "disconnected" dialog, found by the
colour of its Okay button since memory does not show it, and dismisses it before typing: from a fresh start,
16/16 mixed zero-gap switches, 15 at 14-26 s (ADR 0011, addendum).

A second idea tried and reverted: making the same instant `/camp` the *primary* recovery for a **different**
-account world switch too (ahead of `kick_via_soap`), reasoning that a graceful instant logout would avoid
`kick_via_soap`'s own server-side registration race (previous paragraph). Live, slot 2: `/camp` did reach
character-select quickly (confirmed even with a generous 25s bound, ruling out a mere timeout), but the
Back-click + different-account relogin that follows it then reliably failed (`login_state`
5/`LOGIN_DISCONNECTED`) on every attempt tried — zero gap, a 2s pace, and a ~15s real gap alike; a settle sleep
before the Back click did not fix it. `kick_via_soap`'s own path (straight to the login screen, no
character-select/Back leg) kept working immediately after, in the same session. Root cause not established
(not verified further). Reverted: `goto_login_screen_via_memory`'s world-recovery order is unchanged from L11
(`kick_via_soap` first, old full-length `/camp` as fallback) — the instant permission's only proven, tested use
stays the same-account path above, which never reaches the login screen or clicks Back at all.

**Two more dialogs and a field-clearing bug (L13, 2026-10-27).** Live, slot 2, reproducing a fast different-
account switch sequence (`--account Coalabshare Sharea`, `Coalabres`, `--account Coalabshare Shareb`,
zero-gap): worldserver logs (`Logger.network.kick=4`, `Logger.network=5`, slot 2 only, restored afterward)
showed every switch completing a normal `WorldSocket::HandleAuthSession ... authenticated successfully` then
exactly one `.kick`-driven `kicked with reason: Unknown reason` (`WorldSession.h:562`'s no-reason overload,
reached through the SOAP `.kick` command) — never once the `AddSession_`/`PlayerLoading` same-account refusal
(`WorldSessionMgr.cpp:328`) this had previously been suspected to be. Two client-side bugs, not a server race,
explained what was actually observed:
- A second, custom "Project Descension - Connection Help" popup (this client's own addon, not a Blizzard
  `StaticPopup`) appears on a genuine drop and shares `current_screen == "login"` with a clean screen, same as
  the dialog `click_login_dialog_dismiss` already targets — but it is much larger and its own Okay button sits
  at about (0.697, 0.792) of the window, well outside that point (measured live, 1024x768: (714, 608)), so the
  existing click landed in its body text and never closed it; every later `login` call then degraded or failed
  until it was cleared by hand. `clear_login_dialog_unconditionally` now also clicks this point
  (`click_connection_help_dismiss`); same harmlessness precedent as the first click (confirmed live against a
  dialog-free login screenshot: this point sits in empty background between the Login and Quit buttons).
- `cmd_login` cleared the Username/Password fields with a fixed run of 20 `BackSpace` keys, which does not
  reliably clear a field still holding a *different*, differently-sized account's text from a fast previous
  switch: reproduced live (screen-check.png) as `COALABCOALABRESLABS` after `Coalabres -> Labswitch` — the old
  account's text untouched with the new one's tail appended — an unrecognized account the server/client reject
  outright (`LOGIN_DISCONNECTED` with no corresponding `WorldSocket::HandleAuthSession` line at all, since the
  client never gets that far). Both fields are now cleared with `ctrl+a` then `Delete` instead, which clears
  regardless of the field's prior length or the click's exact cursor position.

Both fixes measurably improved, but did not eliminate, zero-gap different-account switch reliability in this
session: before them, the exact sequence above failed at its very first different-account step; after them,
three full zero-gap reps (9 switches) ran clean before a `kick_via_soap` retry-cadence flake (documented
above: the SOAP relay's own reply can be its usage/syntax text instead of a real kick, on no fixed schedule)
produced another `LOGIN_DISCONNECTED`, this time with no field-clearing or dialog symptom at all — a
pre-existing, already-documented limitation, not newly introduced, and not re-diagnosed further within this
task's time budget. Root cause of the very first disconnect that triggers either popup in the first place
remains unestablished: Server.log and Auth.log carry no timestamps, so a specific failing attempt cannot be
matched to a specific log line among many textually-identical cycles.

Tests: `scripts/tests/coa-client-lab.test.sh`, `python3 -m unittest discover -s scripts/tests -p
'test_*.py'` (covers `coa-lab-mem glue`) and, for the Go module, `go vet ./...` plus the DB-free tests
(`go test -run '^(TestValidateClass|TestCharacterListOrder|TestDeriveAccount|TestDedicatedAccountConflict)$'`).
Design and spike results: [`docs/design/`](../../docs/design/).

`start` installs the CoaProbe addon ([`addons/CoaProbe`](../../addons/CoaProbe)) into the lab client. A probe types
`/coaprobe`, then `/reload` so the client writes the answer to its SavedVariables, which
[`scripts/coa-probe-read.py`](../../scripts/coa-probe-read.py) reads; each probe takes a reload (about 15 seconds,
including a 10-second wait so the reloaded interface accepts input again). Tests:
`lua5.1 addons/CoaProbe/tests/run.lua` and `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`
(`scripts/tests/coa-client-lab.test.sh` needs `python3`).
