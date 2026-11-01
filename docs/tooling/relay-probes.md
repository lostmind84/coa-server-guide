# Headless lab, relay probes and CoaProbe

Part of the contributor tooling of the CoA server guide (see the [README](../../README.md#part-2-contributor-tooling)). Builds on [client-lab.md](client-lab.md).

## Headless lab with relay probes

The lab can also run without a window and answer probes in a quarter of a second, through the server instead of
`/reload`. The slot must run a server with the CoA probe relay (`CoA.ProbeRelay.Enable`, in the server repository's
`src/server/coa/CoAProbeRelay*`) and an admin account for SOAP, here `COALABSOAP`, whose password sits in a mode-600
file. Lab accounts must start with `COALAB`. `relay-setup` creates or updates that account itself (each slot has its
own auth DB, so an account made on one slot does not exist on another): it drives the same
[`scripts/lab-character`](../../scripts/lab-character) Go module `character` uses, at `SEC_ADMINISTRATOR`
(`src/common/Common.h:60` in the server repo; `CoAProbeRelay.cpp` registers `.labprobe`'s `send`/`result` at that
level), with no character created — SOAP only checks the account's username, password and GM level.

```bash
coa-client-lab relay-setup 2 --soap-account COALABSOAP --soap-password-file ~/CoaServer/client-lab/secrets/coalabsoap.password
coa-slot compose 2 restart ac-worldserver   # SOAP and the relay are read at startup
coa-lab-relay soap ".server info"           # checks SOAP before any login
coa-client-lab preflight 2                  # also records pass/fail for the lab descriptor
COA_LAB_PROFILE=minimal coa-client-lab start 2               # 1024x768, low-cost settings, gamescope headless
coa-client-lab login COALAB1 <password> Coalabone            # CHARACTER writes state/lab.json
coa-client-lab probe spell 501281           # now goes through the relay: no /reload, the target is kept
coa-lab-relay probe frame GameTooltip       # the same, directly
coa-client-lab probe errors 5               # the client's own Lua error text and stack (ERROR_HANDLER_DATABASE);
                                            #   a /reload empties it: pass `previous` to read the errors from before the last one
coa-lab-footprint sample --seconds 60       # memory (Rss/Pss) and CPU of this lab client and its wineserver
coa-lab-mem check                           # read-only process-memory diagnostics: object manager, unit/aura state, spell rows
coa-lab-mem glue                            # glue screen state: current screen, in-world flag, char-select index/names;
                                            #   `login` reads this itself (see above) -- useful standalone for debugging it
coa-lab-mem glue --until in-world --timeout 45  # one process polls internally (0.1s) until STATE holds or the
                                            #   timeout; `login`'s own waits use this (see ADR 0006), not a shell loop
coa-lab-mem gameobject ENTRY|0xGUID         # a gameobject's flags, GAMEOBJECT_DYNAMIC (activate/sparkle/...) and state as the
                                            #   client holds them for this player (offsets from UpdateFields.h, validated live 2026-10-31)
coa-client-lab revive [CHARACTER]           # revive a dead/ghost lab character over SOAP (.revive): the client's chat box
                                            #   refuses all input, GM commands included, while dead. Default: last logged-in character
coa-client-lab probe perf start 250|stop    # client-side frame timer: `hitch` entries (ms) and 5 s `perf` summaries in `probe log`
coa-client-lab probe item ID                 # name/link/quality, cached (client holds it) and retrieving (still waiting for the server);
                                            #   probe twice ~5 s apart: an id that stays retrieving has no server item_template
coa-client-lab probe state                  # also the player's movement: speed.current (yd/s, read while a key is held), swimming, falling, mounted
coa-client-lab probe actionbar               # every filled action slot (id, spell, cooldown) and the bar buttons with their slot
                                            #   (reload path); `probe frame NAME` also lists the hidden parents and the rect
coa-client-lab goto-spawn gameobject|creature --entry ID|--guid ID [--distance YD] [--bearing DEG] [--dz YD]
                                            # stand next to a spawn read from the slot database, facing it (`.go gameobject`
                                            #   lands inside the model); bearing 0 = east, 90 = north
coa-client-lab camera status|reset|pitch up|down MS  # also yaw left|right and zoom in|out: move the third-person camera on
                                            #   its own; every move prints the pitch (-89..89 degrees, applied in bursts: converge
                                            #   by reading it); the angle is saved per character and survives relogs, `reset` undoes it
                                            #   (an underwater or elevated object can then be framed)
coa-client-lab erase CHARACTER [--account A] [--slot N] # delete a throwaway lab character over SOAP (in-game GMs lack the RBAC
                                            #   permission); without --account also its dedicated COALAB account and password file
coa-lab-packets on && coa-lab-packets auras # the server's own packet log: `.packetlog` over SOAP, decoded aura updates
```

- **Relay configuration is per slot (L14b, 2026-10-27).** `relay-setup N` used to write one file,
  `~/CoaServer/client-lab/relay.env`, shared by every slot and every lab instance; a `relay-setup` on one
  slot silently broke another session's relay on a different slot, because the next read anywhere just
  took whatever slot that single file last named. `relay-setup N` now writes
  `~/CoaServer/client-lab/relay/slotN.env` instead, one file per slot, and never touches a pre-existing
  shared `relay.env` -- every reader (`grant_instant_logout_rbac`, `kick_via_soap`, `write_descriptor`,
  `coa-lab-relay soap`) resolves its own slot's file first and falls back to the legacy shared `relay.env`,
  read only, only when that file's own `SLOT` line still matches. An old setup that never reruns
  `relay-setup` keeps working through that fallback; a setup rerun on the new code gets its own file and
  stops competing with every other slot's. See [ADR 0013](../../docs/adr/0013-per-slot-relay-configuration.md).
- `COA_LAB_PROFILE=minimal` writes `gxResolution` and low-cost CVars (`maxFPS`, `farclip`, `baseMip`, ...) before
  every start and defaults to `COA_LAB_DISPLAY=headless` (gamescope `--backend headless`: no Hyprland window;
  `screenshot` and keyboard input still work). `COA_LAB_DISPLAY=nested` shows it on the workspace again.
  `COA_LAB_WIDTH`/`COA_LAB_HEIGHT` change the size (640x480 was accepted). The default is 1024x768, not 800x600:
  at 800x600 the character pane's Ranged block runs off the bottom of the window (confirmed live, slot 2,
  2026-10-26, level 20 character, `C` key); 1024x768 shows more of it, though the attribute list is a scrollable
  Blizzard frame and even 1280x1024 with a smaller `/console uiScale` did not fit all of it unscrolled (a mouse
  wheel reaches the rest at any resolution). Keep `COA_LAB_WIDTH`/`COA_LAB_HEIGHT` at the same 4:3 ratio: a
  taller-than-4:3 pair (800x720 was tried) letterboxes the whole client, including the login-screen pixel check
  `login` now does (next paragraph).
- Only read-only commands go through the relay (`ping spell item auras spellbook known log state ca frame
  errors`); every relay answer carries `loadId` (changes on each UI load) and the answering `character`.
  **Everything else reloads the UI** — `eval`, `pksend`, `pkwatch`/`pkmeta`/`pkfind`/`evwatch`/`evunwatch` (the
  watches), and any command at all once `COA_LAB_TRANSPORT=reload` forces that path (useful to debug a relay
  answer against the `/reload` one for the same request). This is by design, not an oversight: the relay only
  runs read-only commands (ADR 0006), so `eval` (it can run arbitrary Lua, not read-only) and the watches (they
  install persistent hooks a stateless relay request cannot set up) stay on `/reload`.
  **A `/reload` always costs the client's current UI state** — it tears down and rebuilds every Lua frame:
  an open Spellbook, Character pane or any other frame under test closes, the current target is cleared, and
  the chat window's scrollback is gone (L16, 2026-10-27: a `probe eval` mid-test closed an open Spellbook frame
  the test still needed). None of that is restored afterward. Read UI state you still need with a relay probe
  (`frame`, `ca`, `state`, `spellbook`, `auras`) **before** any `eval`/`pksend`/watch call in the same test, not
  after — there is no "undo" for what the reload just closed.
- `login` waits up to 20 + 25 + 45 s by default (`COA_LAB_LOGIN_WAIT`, `COA_LAB_REALM_WAIT`,
  `COA_LAB_WORLD_WAIT`, each an upper bound, not a fixed sleep: each wait is one `coa-lab-mem glue --until`
  call that ends as soon as memory confirms the real state, or at the bound if memory cannot confirm it).
  Before [ADR 0006](../../docs/adr/0006-glue-polling-cost-was-the-scripts-own-overhead.md) each wait polled by
  shelling out to a fresh `coa-lab-mem glue` (plus extra `python3` field-parses) every `GLUE_POLL_INTERVAL`
  (2s) tick, and six post-login `/console` sound commands added ~12s more; a fresh client + login measured
  36.5s, an in-world account switch 42.9-49.6s (slot 2, 2026-10-26, see ADR 0004/0005). After ADR 0006 (same
  slot, same profile, 2026-10-26): a fresh client + login measured 17.0s, a successful in-world switch
  8.6-14.9s. Sound is now silenced through `Config.wtf` at every `start`, not through post-login chat;
  `click_charselect_back_xtest`'s pre-existing unreliability (ADR 0005) is unchanged -- a failed click still
  falls back to `restart_client`, whose cost is the client's own relaunch, not glue polling.
- `login CHARACTER` (and `login --account A C`) now confirms CHARACTER is the one actually in world, not just
  that *a* character-select navigation ran (L14, 2026-10-27): `login --account COALABKOX Wrkox` once entered
  the world as the account's other character, Hfkox, with nothing noticing -- `select_character_via_memory`
  already guarded against a *mis-highlight* inside the list, but nothing after it checked the eventual
  in-world name. `wait_ui_ready` (which every successful `login` already calls to confirm the UI is ready)
  now also checks the `character` field every relayed probe answer carries (`addons/CoaProbe/Relay.lua`
  stamps it with the in-world player's own name, independent of whichever name the ping was addressed to) and
  dies if it does not match CHARACTER -- reusing that same ping instead of a second relay round trip. Only
  runs when a relay is configured for this slot (`coa-client-lab relay-setup N`): without one there is no
  reliable, non-visual way to read the in-world name back, same as `write_descriptor` already requires.
  Live end-to-end (L14b, 2026-10-27, slot 2, shared account `COALABSHARE`, characters Sharea/Shareb):
  `login --account COALABSHARE Shareb` / `Sharea` alternated 4 times each (8 switches total), the in-world
  name confirmed correct every time by `probe ping`'s own `character` field. The negative case (the check
  itself failing loudly) was proven without provoking an actual bad login: calling `wait_ui_ready` directly
  with a wrong expected name against a real, correctly in-world session died with `logged in as the wrong
  character: requested WrongCharacterName, the relay reports Sharea is in world`.
- Several lab clients: `COA_LAB_INSTANCE=1 coa-client-lab create-instance` (reflink copy of the base lab and
  prefix), then the same commands with `COA_LAB_INSTANCE=1..9`, one account each. `destroy-instance --yes` removes
  one. Three headless instances ran side by side against one slot.
- Measured footprint and design notes: [`docs/design/client-lab-level3.md`](../../docs/design/client-lab-level3.md).
- [`scripts/coa-lab-mem`](../../scripts/coa-lab-mem) and [`scripts/coa-lab-packets`](../../scripts/coa-lab-packets) read the
  lab client's own process memory and the worldserver's packet log, read only, lab only, and only on a slot with
  `Warden.Enabled = 0` — see [Part 2, "reading the lab client's own state"](../../docs/design/client-lab-level3.md#part-2-reading-the-lab-clients-own-state)
  and [ADR 0001](../../docs/adr/0001-lab-client-read-only-diagnostics.md).

## CoaProbe on its own

The probe addon does not need the lab client, the slots or Linux: it answers in any 3.3.5 client, typed by hand.

1. Copy [`addons/CoaProbe`](../../addons/CoaProbe) (without `tests/`) into `Interface/AddOns/CoaProbe` of your client
   and start the client (an addon folder added while it runs is not loaded by `/reload`).
2. In game, type a request with an id of your choice:
   `/coaprobe r1 spell 706240`, `/coaprobe r2 item 6948`, `/coaprobe r3 auras target`, `/coaprobe r4 spellbook`,
   `/coaprobe r5 known 78`, `/coaprobe r6 log 20`, `/coaprobe r7 state`, `/coaprobe r8 errors 5`. The chat answers
   `COAPROBE r1 ok`.
3. Type `/reload`: the client writes the answers to
   `WTF/Account/<ACCOUNT>/SavedVariables/CoaProbe.lua` (`WTF\Account\<ACCOUNT>\SavedVariables\CoaProbe.lua` on
   Windows).
4. Read one answer as JSON: `python3 scripts/coa-probe-read.py <that file> r1`.

Answers are JSON: `spell` gives name, rank, icon, cost, cast time, range, whether the character knows it and the
tooltip lines; `item` gives the tooltip lines; `auras` gives name, spell id, count, duration, expirationTime, caster
and whether it is harmful for every aura on the unit; `spellbook` lists the known spells with their ids; `known`
answers one spell id; `log` returns the addon's own continuous capture (see below); `state` snapshots the player
and target together; `errors [N] [previous] [locals]` reads the client's own Lua error log
(`ERROR_HANDLER_DATABASE`) directly, no handler install — on this path a `/reload` is also what rotates
`errors.current` into `.previous`, so `errors` and `errors previous` in the same `/reload` describe the errors
from right before and right after it. The addon keeps the last 50 answers and never talks to the server, so it
is safe on a live realm. Limits: it cannot read action bars or 3D models, and a request must not contain `|`.

Installing the addon adds a second SavedVariable, `CoaProbeLog`, written into the same `CoaProbe.lua` file: the
addon continuously captures UI errors ("Not enough rage"), system messages and the player's own casts (with their
failure reason) as they happen, capped at the last 200 entries, independently of any `/coaprobe` request. The `log`
command reads it back the same way as any other answer.
