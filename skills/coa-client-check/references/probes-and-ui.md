# Probes, frames and the UI

Reference for the `coa-client-check` skill, moved out of `SKILL.md` without changing its substance. The numbers in the headings (8a1, 8a5...) are the old item numbers.

## Errors, and effects too brief for a screenshot

`probe errors [N] [previous] [locals]` reads the client's own `ERROR_HANDLER_DATABASE` directly (no handler
install) and returns the Lua error text and stack, not just the system line `probe log` already captures; a
`/reload` empties the table, so read `previous` for the errors seen just before the last world entry. Still
cannot observe: action-bar contents, 3D models, animations, anything purely visual. That is different from
the red on-screen UI errors, which `probe log` does capture (`SKILL.md` section 4). A single `screenshot` can miss
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

## 8. Buffs render left of the minimap, not below it

The stock 3.3.5a `BuffFrame` is anchored top right,
to the left of the minimap (verified 2026-10-31: the permanent "PvE Mode" icon sits there). Crop that
corner before concluding a buff is invisible; `probe frame BuffButton1` returns `shown`/`visible`, and
`probe eval` reads `BuffButton1Icon:GetTexture()`. `eval` takes an expression (it prepends `return`;
wrap statements in `(function() ... end)()`), no `|`, and stays under the 255-character chat limit.

## 8a1. Reading frames and action bars

`probe frame NAME` returns `shown`, `visible`, the `parents` chain (`Name:1` shown,
`Name:0` hidden) and the `rect`: `visible` is false whenever an ancestor is hidden. This client's character pane
is on screen while the stock `CharacterFrame` is hidden (`PaperDollFrame` reports `shown` true, `visible` false,
`parents` `CharacterFrame:0,UIParent:1`, rect 384x512 at the top left, verified 2026-11-01): trust the rect and a
screenshot, not `visible`. `probe actionbar` lists every filled action slot (`slot`, `type`, `id`, `texture`,
`cooldown`) and the bar buttons with the slot each carries and whether it is shown, so a spell dragged to "the
fifth button" is found by slot id instead of by counting pixels. `frame` goes through the relay; `actionbar`
is a reload-path probe (see `SKILL.md` point 4b).

## 8a2. Latency of reload-path probes

`eval`, `actionbar`, `pksend` and the watches reload the UI: allow 10 to 60 s per
call under load (the default `COA_LAB_PROBE_TIMEOUT` is 30 s; raise it, and wrap a scripted loop's calls in at
least 60 s). One `eval` that scans many slots beats a loop of calls, and the `no CoaProbe answer` error only says the
answer did not arrive yet: read it again before concluding.

## 8a5. "The chest or sack opens empty": is the looted item known to the server?

`probe item ID` answers `cached`
(the client holds the item: `name`, `link`, `quality`), `retrieving` (the tooltip is still "Retrieving item
information") and the tooltip lines. The first probe of an item the client has never seen always answers
`cached` false, `retrieving` true: the client asks the server and the answer lands a few seconds later. Probe
twice, about 5 s apart (verified 2026-11-01: item 400002 `retrieving` then, 6 s later, `cached` true with its
name and tooltip). An id that stays `cached` false and `retrieving` true on the second and third probe was not
answered with an item, which is what a missing `item_template` row looks like (verified with id 9999999, which has
no row: still `retrieving` after several probes). The client cannot tell "the server said unknown" from "no
answer yet": confirm in the database (`select entry from item_template where entry = ID`) before calling it a
missing template, and a `cached` true item whose chest is still empty is a loot-table problem instead.
