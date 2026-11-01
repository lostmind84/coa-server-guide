# Lab state, slots and the memory tools

Reference for the `coa-client-check` skill, moved out of `SKILL.md` without changing its substance. The numbers in the headings (8a1, 8a5...) are the old item numbers.

## 6. Useful facts the client hides

Useful facts the client hides: the displayed bar is not always the resource a spell charges (`probe state`
reports mana, rage, focus, energy and runic power); `.gps` prints the position into the captured system
messages; `.go xyz X Y Z MAP O` takes the facing as its fifth number, which answers "Target needs to be in
front of you".
To stand next to a spawn from the database, use the core's own `.go creature id ENTRY`, `.go creature SPAWNGUID`,
`.go gameobject id ENTRY` or `.go gameobject SPAWNGUID` (`cs_go.cpp`) instead of typing coordinates by hand.

## 8a4. A dead gamescope

A `key` press, or nothing at all, has twice killed the lab's gamescope (`[gamescope_ei]
Unhandled libei event!`, `EI_EVENT_SYNC`, a Wayland broken pipe): a host-side crash, not reproducible on demand. Every
command then answers `lock present but gamescope is gone` with the recovery: `coa-client-lab stop`, `start N`,
`login CHARACTER`.

## 8a0. Modules that ship disabled

(`CoALegendaryItems.Enable`, `Ascension.Manastorm.Enable`): `coa-slot conf N KEY 1`
turns one on for the slot (private config, worldserver restart) and `coa-slot conf N KEY 0` restores it.

## 8a. Fresh client cache

Every `coa-client-lab start` deletes the lab client's `Cache` folder (WDB included), so
a check always runs with a fresh cache; there is no separate cache command. A WDB refresh only refetches the
server's templates (names, display ids): an icon or model that stays a red "?" with a fresh cache comes from the
client's own data (DBC, MPQ art), not from the cache.

## Loot checks

Mystic Scroll drops need `coa-slot classmodel N hero` (they are zeroed on a `coa` realm); restore
`coa` before `coa-slot release`.

## 8b. Time-gated mechanics

The slot containers run in UTC; a mechanic keyed to the local hour (Sun Cleric `Daytime()`)
strips a forced aura outside its window. `coa-slot tz N UTC-12` (or another POSIX zone) shifts the worldserver's
local time for the check and `coa-slot tz N off` restores it; verified 2026-11-01 with aura 707768 on a Sun Cleric.
`login` accepts the character name in any letter case (the server stores it title-cased).

## 9. Framing an object

`coa-client-lab goto-spawn gameobject|creature --entry ID|--guid ID --distance 8
--bearing 90` lands the character at that bearing and distance from a database spawn, facing it, instead of
inside its model (`.go gameobject GUID`); an underwater spawn needs a bearing toward the shore and `--dz`.
`coa-client-lab camera pitch up|down MS`, `yaw left|right MS` and `zoom in|out MS` then move the camera
around the character without turning it. The client applies pitch in bursts, so no timed move is
proportional: `camera status` prints the pitch (-89..89 degrees) and `camera reset` returns to the default
view; the angle is saved per character, so reset it at the start of a framing check. `goto-spawn` reads the
landing back with `.gps` and warns when Z differs from the request (snapped or fallen). `--items` must equip; put cache or consumable ids in `--bag-items`.
`coa-slot warden N off` makes any claimed slot 2-4 usable for `coa-lab-mem` (it restarts the worldserver).

## 10. Gameobject state

`coa-lab-mem gameobject ENTRY|0xGUID` prints the client's copy of the object's
`GAMEOBJECT_DYNAMIC` low word (`activate`, `sparkle`...), flags and state. The server sets `sparkle` per
player only for quest-objective gameobjects (`ActivateToQuest`, `GameObject.cpp` BuildValuesUpdate); a
quest-giver's `!` marker comes from the quest-giver status packet instead (`probe pkwatch`). The ENTRY form
reads the first matching object in view; use the GUID from `coa-lab-mem objects` for a specific one.

## 11. When the question is "is the Lua view wrong", not "what does the UI show"

`scripts/coa-lab-mem`
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
