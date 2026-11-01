---
name: coa-client-check
description: >-
  Check a CoA issue whose symptom is only visible in the game client (tooltip text or values, auras shown on the
  wrong unit, missing icon or model, broken UI) by driving the lab client with coa-client-lab and CoaProbe, and
  return reproduced / not reproduced / inconclusive with evidence. Use for client-side symptoms; server-side
  behaviour belongs to the Ghost e2e harness.
---

# CoA client check

One issue, one check, one verdict. The check is only worth what its expectation is worth: write the expectation
before touching the client, and never soften it afterwards.

Machine details (slots, paths, harness pitfalls) live in the `coa-ghost-harness` skill; the scripts are documented
in the public guide (https://github.com/lostmind84/coa-server-guide, Part 2).

## Not this skill

- A server value (damage, cost, cast time, cooldown, aura amount, loot, quest step): a `coa-gameplay-test`
  scenario proves it without a client and stays committed as a regression test.
- Anything a real session receives but does not render (packets, experience, movement, relogs, duels, several
  actors): a Ghost e2e test.
- Use this skill when the question is what the player *sees*, or when the server and the client disagree.

## Verdicts

- **reproduced**: the expectation failed exactly as the issue describes.
- **not reproduced**: the expectation held.
- **inconclusive**: anything else — red preflight, client or addon failure, an issue too vague to turn into an
  expectation, a symptom the tools cannot observe.

A technical failure is never "not reproduced": closing a real issue costs more than one more run.

## 1. Preconditions

1. `coa-slot list`, then `coa-slot claim N "<issue> client check"`; `coa-slot claim-issues N <issue>`.
2. The slot runs the revision the check needs (`coa-slot deploy N origin/main`, or the fix branch in verify mode).
   A deploy takes 2 to 5 minutes in the foreground: give the tool a timeout of 10 minutes, or background it and
   wait; the harness's default 2 minute timeout silently moves it to the background. `coa-slot list` shows
   `[held N min]` on every claim: a claim is live until its owner runs `coa-slot release`.
3. `coa-client-lab preflight N` must be PASS. A FAIL stops the check with **inconclusive**, naming the failing line.
   A slot merely behind origin/main only WARNs on the `git` line and lists the missing commits: read them and
   continue when none touches the code or data under test.
   It skips the gameplay-test `harness` image line (a stale harness image never blocks a client check); a bare
   `coa-slot preflight N` still checks it.
4. The lab client exists (`coa-client-lab create` once) and no other check holds it (`coa-client-lab status`).

## 2. Expectation

Read the issue, then write one or more checkable expectations in `.agents/plans/<issue>/client/expectation.md`:
what will be observed, with which probe, and which result means the issue is reproduced. Examples:

- `probe spell 706240` — tooltip line 1 is the spell name and the description says the debuff lands on the target.
- `probe auras target` after casting 706240 — the aura is on the target, not on the player.
- `probe item 6948` — the tooltip has a "Use:" line.

If the issue cannot be turned into an expectation (no spell id, no reproduction path, a symptom nobody can see
twice), ask the question in the issue and stop with **inconclusive**.

`probe errors [N] [previous] [locals]` reads the client's own `ERROR_HANDLER_DATABASE` directly (no handler
install) and returns the Lua error text and stack, not just the system line `probe log` already captures; a
`/reload` empties the table, so read `previous` for the errors seen just before the last world entry. Still
cannot observe: action-bar contents, 3D models, animations, anything purely visual. That is different from
the red on-screen UI errors, which `probe log` does capture (section 4 below). A single `screenshot` can miss
a sub-second effect (a projectile, a brief cast glow) between its own dispatch and the next one; for that,
`screenshot --burst N --interval-ms MS [--chat TEXT|--key KEY...]` or `screenshot --video-seconds S [--fps N]
[--chat TEXT|--key KEY...]` fire the triggering action and start capturing in the same call (L15,
2026-10-27). `--burst` uses `magick import` per frame, measured at roughly 2.5s/frame on this environment's
nested gamescope display (1920x1080) -- far above its own `--interval-ms` request, so it does not actually
reach sub-second spacing; `--video-seconds` (ffmpeg x11grab) does: measured a true, evenly spaced 20fps
(50ms/frame) over a 3s clip, first frame within roughly its own frame interval of the action. Prefer
`--video-seconds` for anything sub-second; extract frames from the clip (`ffmpeg -i clip.mp4 frame-%03d.png`)
to inspect one. Pure visuals too brief or ambiguous even for that are judged "visual, needs user
confirmation"; the rest is **inconclusive** with the missing capability named.

## 3. Setup and action: Ghost first

The Ghost e2e harness builds a character in seconds (race and class at login, `SetLevel`, `Learn`,
`AddItem`/`EquipEntry`, `Teleport`, `Spawn` for a fixture target) and can cast the spell itself, checking both
the server's aura list and the one the client receives. Typing GM commands into the lab client is slower,
blind and fails silently: use it only for a last tweak. Ghost's own `SetSpecialization` still whispers
`.localspec`, which server commit 2d13ffd73a (#5507, "talk to the client through native Extensions.dll
packets only") removed along with every other `ASC_LOCAL_*` chat command; the whisper is now silently
ignored, so that helper no longer does anything. For the lab client, use `coa-client-lab character --spec ID`
below instead: it writes the `core.ascension_active_spec` character_settings row the server's own
`OnPlayerLogin` still reads, which the character's next login then applies.

For the lab client specifically, do this setup with one command instead of an ad hoc Ghost module:
`coa-client-lab character --slot N --character C --race R --class K [--level N] [--spec ID]
[--learn ID,ID,...] [--items ID,ID,...] [--bag-items ID,ID,...]` (guide README, "Client lab for agents"). It works on any slot and refuses
to silently change an existing character's class; by default it makes a dedicated account for C alone, so
`coa-client-lab login C` logs straight into it. Pass `--account A` instead only when the check is itself about
a shared account (bank, account-bound items, char-select screen) or needs a second character alongside it on
the same account.

Split the work:

1. **Ghost** does the setup: account, character of the right race, class and level, spec, spells, equipment,
   position, and the target creature. It also performs the action (cast, use, pull) whenever the check is about
   values or about which unit carries an aura, and reports what the server and the packets say.
2. **The lab client** logs in afterwards on the same character and only observes what is *displayed*: tooltip
   text, aura on the unit frame, icon, model. It acts only when the action itself is a UI interaction that Ghost
   cannot perform.

A Ghost run that already contradicts the issue is a finding on its own: say so and check the display only if the
issue is about the display.

Record what you ran: the scenario or test name, the GM commands, the character. Everything lands in the evidence
folder.

## 4. Observe

1. `coa-client-lab start N`, then `coa-client-lab login <character>` (about 90 s) for a character made with
   `character`'s default dedicated account, or `coa-client-lab login --account <account> <character>` for a
   shared one (its password is generated/reused the same way as a dedicated account's — never type or pass one
   on the command line). `coa-client-lab login <account> <password> [<character>]` still works for a password
   held another way. On a slot prepared with `coa-client-lab relay-setup N` (guide README, "Headless lab with relay
   probes"), prefer `COA_LAB_PROFILE=minimal coa-client-lab start N`: with CHARACTER given either way, read-only
   probes then go through the server relay in a fraction of a second, without `/reload`.
2. Drive the client with `chat` (slash and GM commands), `key`, `hold KEY MS` (walk with `w`/`s`, turn with
   `Left`/`Right`) and `screenshot`. Typed text must not contain `|`.
3. **Read what the screen forgets.** `coa-client-lab probe log [n]` returns the addon's capture of UI errors
   ("Target too close", "Not enough rage"), system messages and the player's casts with their failure reason.
   Nothing else shows why an action did not happen: the red error text fades and `/reload` clears the chat.
   Read the log after every action that could fail, before concluding anything.
3b. **Timing.** Log entries carry `time` (one second) and `clock`, the client's `GetTime()` in milliseconds, so two
    entries of one session can be ordered and spaced to the millisecond. The log keeps `cast`, `cast_failed` and
    `cast_interrupted` by default; `probe evwatch UNIT_SPELLCAST_START` (also `UNIT_SPELLCAST_CHANNEL_START`,
    `UNIT_SPELLCAST_CHANNEL_STOP`...) adds the starts. Lua has no world position: `.gps` (one line per call) is the
    client-side read; for movement at 100 ms spacing use a Ghost or `coa-gameplay-test` step on the server side.
4. **One request per moment (reload path).** `coa-client-lab probe state` snapshots the player and the current
   target together (name, level, health, every power index the client exposes, auras). A probe on the `/reload`
   path writes its answer through `/reload`, which clears the target selection, so two such probes never describe
   the same situation. Relay probes keep the target and the chat: several of them can describe one moment, and
   answers with the same `loadId` prove no reload happened between them.
4b. **`eval`, `pksend`, the watches (`pkwatch`/`pkmeta`/`pkfind`/`evwatch`/`evunwatch`), and any probe forced
    through `COA_LAB_TRANSPORT=reload`, always reload the UI** — by design, not a bug: the relay only runs
    read-only commands (guide ADR 0006), and these either run arbitrary Lua or install persistent hooks a
    stateless relay request cannot. A `/reload` tears down and rebuilds every Lua frame: it closes whatever
    frame is open under test (Spellbook, Character pane, ...), clears the target (point 4 above) and empties
    the chat (point 3 above) — `probe eval` closing an open Spellbook frame mid-test (L16, 2026-10-27) is this,
    not a defect in `eval` itself. Read every piece of UI state the test still needs with a relay probe
    (`frame`, `ca`, `state`, `spellbook`, `auras`) **before** calling `eval`/`pksend`/a watch, not after: there
    is no way to recover what the reload just closed.
5. **Snapshot inside the effect window.** Many auras last seconds: send the probe immediately after the action,
   without waiting. An empty aura list after a finished cast proves nothing.
6. Useful facts the client hides: the displayed bar is not always the resource a spell charges (`probe state`
   reports mana, rage, focus, energy and runic power); `.gps` prints the position into the captured system
   messages; `.go xyz X Y Z MAP O` takes the facing as its fifth number, which answers "Target needs to be in
   front of you".
   To stand next to a spawn from the database, use the core's own `.go creature id ENTRY`, `.go creature SPAWNGUID`,
   `.go gameobject id ENTRY` or `.go gameobject SPAWNGUID` (`cs_go.cpp`) instead of typing coordinates by hand.
7. **A dead or ghost character cannot chat at all** ("You can't chat when you're dead!", GM `.` commands
   included), and `.go xyz` typed then is silently lost. Recover with `coa-client-lab revive [CHARACTER]` (server-side
   `.revive` over the SOAP relay; needs `relay-setup`): when the character is still dead it releases the spirit
   (CMSG_REPOP_REQUEST) and revives again by itself. `goto-spawn` revives first, and again if the landing killed
   the character (a tight cave spawn can). Do not abandon the character.
8. **Buffs render left of the minimap, not below it.** The stock 3.3.5a `BuffFrame` is anchored top right,
   to the left of the minimap (verified 2026-10-31: the permanent "PvE Mode" icon sits there). Crop that
   corner before concluding a buff is invisible; `probe frame BuffButton1` returns `shown`/`visible`, and
   `probe eval` reads `BuffButton1Icon:GetTexture()`. `eval` takes an expression (it prepends `return`;
   wrap statements in `(function() ... end)()`), no `|`, and stays under the 255-character chat limit.
8b. **Time-gated mechanics.** The slot containers run in UTC; a mechanic keyed to the local hour (Sun Cleric `Daytime()`)
    strips a forced aura outside its window. `coa-slot tz N UTC-12` (or another POSIX zone) shifts the worldserver's
    local time for the check and `coa-slot tz N off` restores it; verified 2026-11-01 with aura 707768 on a Sun Cleric.
    `login` accepts the character name in any letter case (the server stores it title-cased).
9. **Framing an object.** `coa-client-lab goto-spawn gameobject|creature --entry ID|--guid ID --distance 8
   --bearing 90` lands the character at that bearing and distance from a database spawn, facing it, instead of
   inside its model (`.go gameobject GUID`); an underwater spawn needs a bearing toward the shore and `--dz`.
   `coa-client-lab camera pitch up|down MS`, `yaw left|right MS` and `zoom in|out MS` then move the camera
   around the character without turning it. The client applies pitch in bursts, so no timed move is
   proportional: `camera status` prints the pitch (-89..89 degrees) and `camera reset` returns to the default
   view; the angle is saved per character, so reset it at the start of a framing check. `goto-spawn` reads the
   landing back with `.gps` and warns when Z differs from the request (snapped or fallen). `--items` must equip; put cache or consumable ids in `--bag-items`.
   `coa-slot warden N off` makes any claimed slot 2-4 usable for `coa-lab-mem` (it restarts the worldserver).
10. **Gameobject state.** `coa-lab-mem gameobject ENTRY|0xGUID` prints the client's copy of the object's
   `GAMEOBJECT_DYNAMIC` low word (`activate`, `sparkle`...), flags and state. The server sets `sparkle` per
   player only for quest-objective gameobjects (`ActivateToQuest`, `GameObject.cpp` BuildValuesUpdate); a
   quest-giver's `!` marker comes from the quest-giver status packet instead (`probe pkwatch`). The ENTRY form
   reads the first matching object in view; use the GUID from `coa-lab-mem objects` for a specific one.
11. **When the question is "is the Lua view wrong", not "what does the UI show".** `scripts/coa-lab-mem`
   (guide, part 2) reads the lab client's own process memory (object manager, unit/aura data, loaded
   `Spell.dbc` row) independently of the addon API, so it can show that the engine disagrees with
   `probe state`/`probe auras` themselves. `scripts/coa-lab-packets` reads the worldserver's packet log to
   show what the server actually sent. Both are read-only, lab-only, and need a slot with
   `Warden.Enabled = 0`; neither substitutes for a Ghost scenario or for `probe state`/`probe auras`, and
   both are a last resort when the display and the Lua view already disagree and the cause matters.
   `coa-client-lab preflight N`/`start N` print the slot's Warden state up front (L15, 2026-10-27) --
   `warden: off on slot N (coa-lab-mem and coa-lab-packets usable)`, or a `WARN:` naming both tools when it
   is on -- so a Warden-on slot is known before either tool is tried, not from the first refusal.
   Totem checks: `coa-lab-packets on`, cast, then `coa-lab-packets list --opcode SMSG_TOTEM_CREATED` shows whether
   the server sent the totem-bar packet (the packet log holds every packet, both directions).

## Getting the state you need, shortest route first

Waiting for the game to produce a condition rarely converges: rage decays out of combat, cooldowns return,
fixtures wander. Set the state instead, and record what you set.

- Resources: select the character (`/target <name>`) then `.modify rage 1000` (or `mana`, `energy`,
  `runicpower`). `.modify` acts on the selected *player*: with a creature selected it answers "No character
  selected."
- Fixture target: a training dummy at the character's own level (`.npc add 32666` then `.npc set level <level>`)
  never fights back, and the level gap does not distort hit or resist. Leave it at its default faction until a
  refusal proves a hostile one is needed.
- GM cheats (`.cheat god|power|cooldown`) change how the game behaves, so they are a last resort: use one only
  when a captured error proves it is the blocker, and write in the report which one and why. A dummy that cannot
  kill you removes the need for `god`; `.modify` removes the need for `power`.
- Prefer the normal player path for what the check is about: level, `coa-client-lab character --spec ID` for a
  specialization. Neither `.localspec` nor `.localtalent <entry> <rank>` exists any more (server commit
  2d13ffd73a, #5507): a specialization switch now has the DB-write path above, but a single talent rank has
  no chat command or lab-level equivalent at all — only the native CMSG 0x0727 upload the client itself sends
  (`.agents/docs/systems/ascension-talents.md` in the server repo). If a forced `.learn` was used and the
  issue does not reproduce, redo it through the talent path before concluding: the acquisition method can be
  the difference. Talent entry ids come from
  `/srv/coa/server-data/dbc/CharacterAdvancement.dbc` (field layout in
  `modules/mod-ascension-compat/src/AscensionCoATalentData.cpp`).

## 5. Verdict and evidence

`.agents/plans/<issue>/client/` holds `expectation.md`, `answers/`, `screenshots/` and `context.txt` with the
slot number, the deployed commit, the preflight result and the account and character used.

State the verdict with the fact that produced it, quoting the probe answer. If the observed value differs from the
issue's claim, report what you saw: the issue may be right about the symptom and wrong about the cause.

## 6. Verify mode: the same expectation after a fix

A fix is verified only against a check that failed first. Reuse the repro run's `expectation.md` word for word.

1. Deploy the fix branch to the slot (`coa-slot deploy N <branch>`) and run `coa-client-lab preflight N` again. A
   data-only fix still needs the deploy: the slot database applies the migration there.
2. Rebuild the character with the same setup run, so nothing but the fix differs.
3. Repeat the same probes, in the same effect window, and save them next to the repro answers
   (`answers/verify-*.json`).
4. The fix passes only if the expectation now holds where it failed. Quote both answers side by side in the
   report; "it looks right now" is not a result.

Worked example (#3935): repro showed `Arbalest Mastery (706241)` with 3 stacks as **HARMFUL** on the caster; after
one `spell_custom_attr` row marking the aura positive, the same probe showed the same 3 stacks as **HELPFUL**.

## 7. Reporting

Propose a 1 to 3 line comment (the `coa-fix-issues` format) with the decisive answer quoted, and the screenshot
when the interface itself is the evidence — make the interface legible first (the spell on the action bar, the
frames visible), a bare screenshot proves nothing. Post only after the user agrees.

Name the ids and their names together: a human reads `706241 "Arbalest Mastery"`, not a bare number.

When the check contradicts the report, say what you saw rather than what was claimed, and look for the mechanism:
for #3935 the client classified a positive stacking effect as harmful, which is why the reporter called it a
debuff on themselves.

This check is a step of `coa-fix-issues`, not a workflow of its own: the issue claim, the branch, the commit, the
PR and the issue comment stay that skill's job; this one only produces the verdict and its evidence.

## Errors

| Situation | Verdict |
|---|---|
| Preflight FAIL, or the slot is not the revision under test | inconclusive, quote the failing line |
| The client does not reach the world | inconclusive, keep `~/CoaServer/client-lab/state/client.log` |
| A probe times out (`no CoaProbe answer`) | one retry, then inconclusive |
| A probe answer has an `error` field | inconclusive unless the error itself is the finding |
| The client crashes or freezes | `coa-client-lab stop`, inconclusive; a reproducible crash is a finding |
| The symptom needs a capability the tools lack | inconclusive, name the capability |

Always finish with `coa-client-lab stop` and `coa-slot release N`, even after a failure. Delete throwaway
characters with `coa-client-lab erase CHARACTER` (relay-based: `.character erase` and `.account delete` are
not grantable to in-game GMs).
