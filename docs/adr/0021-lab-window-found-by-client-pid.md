# 0021. The lab client's window is found by its process, not by its title

- Status: accepted
- Date: 2026-11-23

## Context

`coa-client-lab start` looked for the client window with `xdotool search --name '^Ascension$'` on gamescope's
display. The current `Ascension.exe` titles its window "Descension", so `start` waited out
`COA_LAB_WINDOW_TIMEOUT`, reported "no client window" and every later command (`login` first) refused to run.

Measured on 2026-11-23 with the current client, headless gamescope, GE-Proton11-6, gamescope display `:1`:

- The game window: title `Descension`, `WM_CLASS` `steam_app_0`, `_NET_WM_PID` the host pid of the Wine process
  whose `argv[0]` is `X:\...\Ascension.exe` (`comm` `Ascension.exe`).
- The same pid owns two more windows, "Default IME" and an unnamed one; `xdotool search --onlyvisible --pid PID`
  returns only the game window.
- Every Proton window on that display has `WM_CLASS` `steam_app_0` (it follows `GAMEID=0`), so the class tells
  nothing about which window is the game.
- `umu.exe` and `proton` carry the `Ascension.exe` path only as a later argument; their `argv[0]` differs.

## Considered options

1. Accept a list of titles (`Ascension`, `Descension`).
2. Search by window class.
3. Search by the client process: the descendant of the lab's gamescope whose `argv[0]` ends in `Ascension.exe`,
   then `xdotool search --onlyvisible --pid`.

## Decision

Option 3 first, then option 1 as a fallback when no window of that process is visible yet, and an override:
`COA_LAB_WINDOW_NAME=REGEX` replaces both with one `xdotool search --name REGEX`. Option 2 is useless here (one
class for every window).

The search stays limited to gamescope's own display, read from the environment of gamescope's descendants as
before, so the user's own client is never a candidate.

## Consequences

- A client that renames its window again needs no change. One that renames its executable does: `CLIENT_EXE` in
  the script, which also names the executable `start` launches.
- The pid lookup depends on Wine setting `_NET_WM_PID` to the host pid. If a future Proton runs the game in its own
  pid namespace, the title fallback still finds "Ascension" or "Descension", and `COA_LAB_WINDOW_NAME` covers any
  other title.
- The "no client window" message names what was looked for.
