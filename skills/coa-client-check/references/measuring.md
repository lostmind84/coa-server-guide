# Timing, combat events, performance and movement

Reference for the `coa-client-check` skill, moved out of `SKILL.md` without changing its substance. The numbers in the headings (8a1, 8a5...) are the old item numbers.

## 3b. Timing of log entries

Log entries carry `time` (one second) and `clock`, the client's `GetTime()` in milliseconds, so two
entries of one session can be ordered and spaced to the millisecond. The log keeps `cast`, `cast_failed` and
`cast_interrupted` by default; `probe evwatch UNIT_SPELLCAST_START` (also `UNIT_SPELLCAST_CHANNEL_START`,
`UNIT_SPELLCAST_CHANNEL_STOP`...) adds the starts. Lua has no world position: `.gps` (one line per call) is the
client-side read; for movement at 100 ms spacing use a Ghost or `coa-gameplay-test` step on the server side.

## 8a3. Observing a miss or a parry

`probe evwatch COMBAT_LOG_EVENT_UNFILTERED` (one reload), then `.npc add 32666`,
`.npc set level N`, `/target Training Dummy`, `/startattack`, wait, and `probe log 200`: every entry is
`kind` event with `args` = timestamp, subevent, source guid, name, flags, destination guid, name, flags, then the
subevent's own fields. A miss is `SWING_MISSED` or `SPELL_MISSED` ending with the miss type (`MISS`, `PARRY`,
`DODGE`, ...). Verified 2026-11-01: a level 20 Barbarian auto-attacking a level 23 dummy logged 8 of 8 swings as
`SWING_MISSED`, one `PARRY` and the others `MISS` (one run, not a hit-rate). The log keeps 200 entries and a
fight fills it, so read it soon after.

## 8a3b. Hitches and frame time

`probe perf start [MS]` arms a client-side timer (kept across reloads, no reload after
the first call): every frame of MS milliseconds or more (default 250) writes a `hitch` log entry with `ms`, and a
`perf` entry every 5 s with `frames`, `fps` and `worstMs`; read them with `probe log 100` (relay, no reload), each
carrying the millisecond `clock`, then `probe perf stop`. Arm it, cast, read the log: a client freeze shows as a
`hitch` entry whose `clock` sits at the cast. The `minimal` profile caps the client at 10 fps, so a frame is 100 ms
and anything under about 250 ms is invisible; start the client with another profile for finer resolution.
Verified 2026-11-01: a 700 ms busy loop logged `hitch` 706, summaries read 10 fps, and the watch survived a reload.
It measures the client's frame time, not the server's: a hitch from a server stall shows as a frame gap only
if the client waits on it.

## 8a6. Speed while swimming or moving under a buff

`probe state` reports the player's `movement`: `speed.current` (yards
per second, from `GetUnitSpeed`), `swimming`, `falling`, `flying`, `mounted`. This client's `GetUnitSpeed` returns
one value, the speed right now, so it reads 0 while standing still: send the probe while a key is held, e.g.
`coa-client-lab hold w 3000 & sleep 1.5; coa-client-lab probe state; wait` (`hold` blocks for its duration; the relay
probe does not reload, so it can run during the hold). Recipe for a swim buff: put the character in water, check
`swimming` true, read the speed moving, apply the buff, read it moving again. Verified 2026-11-01 in Baradin Bay
(map 0, `.go xyz -2538 -1632 8 0`, found by trying offsets around the `game_tele` row `BaradinBay`; `.tele NAME` itself
answers "Command 'tele' is ambiguous" in this client's chat, so use `.go xyz`): swimming forward 4.72, then 9.44 after `.aura 7840` (Swim Speed Potion). A
`.go xyz` over open ground with Z 0 makes the character fall and die: `revive`.
Measuring a dash or any short speed burst: `speed.current` sampled every 0.3 s misses it. Compare the distance over a
fixed `hold w 3000` instead, from `.gps` lines in `probe log` before and after, restarting each run from the same
`.go xyz X Y Z MAP O` (control run without the action, then with it; land 3 s gave 20.1 yd, swimming 14.2 yd, repeatable
to 0.5 yd).
Caveat: a chat-typed `/cast` takes about 1.5 s, so its moment inside the hold is loose. The Chaos Rush check (#10310)
read 0 yd gained while moving on land this way, while another run (hold 2 s, cast fired during the hold, X delta
against a no-cast control) measured +6.4 yd on land, +6.7 on the water surface and about 0 underwater on the same
build. The cause of the difference was not established; prefer the second protocol and confirm a "no effect" reading
with a positive control before trusting it.
