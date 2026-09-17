# Client issue agent: spike findings

Date: 2026-09-17
Plan: docs/superpowers/plans/2026-09-17-client-issue-agent-spike.md

## Setup

- Baseline of the user's client: 189 files under `WTF` and `Interface/AddOns` hashed into
  `~/CoaServer/client-lab-spike/checksums-user-client.txt`.
- Lab copies made with `cp -a --reflink=always`: `~/CoaServer/client-lab/ascension-lab` (from the 44G client) and
  `~/Games/umu/coa-client-lab` (from the 263M prefix). `df` free space on `/home` stayed at 183G.
- No symlink or `.reg` entry in the lab prefix points back to the user's prefix.

- Server: slot 3, `origin/main` d212cbdb0 deployed, `coa-slot preflight 3` PASS (368 of 368 client DBC tables
  identical). Lab client realmlist set to `127.0.0.1:3924` in `WTF/Config.wtf` and `Data/enUS/realmlist.wtf`,
  `Cache` deleted.
- Tools installed by the user: gamescope 3.16.28, xdotool 4.20260303.1.
- Test account: `labspike` (GM 3) created with the Ghost helpers `e2eharness.EnsureAccount` and `SetGM` from a
  scratch Go module (`replace` onto the Ghost checkout, nothing written there). Character `Labspike` (human
  warrior, guid 194) created by a Ghost `LoginBot` login: the client has no characters on a fresh account, and
  the CoA character creation screen is not worth driving by input.

## Q1. Does the client reach the world inside nested gamescope?
Result: **yes**

- Hyprland is 0.56.2 with a Lua config: `hyprctl dispatch exec "[workspace 9 silent] ..."` fails with a Lua
  syntax error. What works: `hyprctl eval "hl.exec_cmd([[<cmd>]], { workspace = \"9 silent\" })"`
  (`hl.exec_cmd(cmd, rules)` from `/usr/share/hypr/stubs/hl.meta.lua`; the `workspace = "... silent"` rule form is
  used by Omarchy's `apps/browser.lua`).
- Command: `bash -c 'cd <lab client> && exec env WINEPREFIX=<lab prefix> GAMEID=0 PROTONPATH=<GE-Proton11-6>
  WINEDLLOVERRIDES=divxtac=d gamescope -W 1280 -H 720 -w 1280 -h 720 -- umu-run Ascension.exe'`.
- The gamescope window opened on workspace 9 and the user's active window did not change.
- The Wine process shows as `X:\CoaServer\client-lab\ascension-lab\Ascension.exe`, so `coa-client --kill`
  (pattern `ascension-live\Ascension.exe`) cannot kill the lab client, and the reverse holds for a lab pattern.
- The client window inside gamescope is 800x600 (from the lab copy of the user's `Config.wtf`), gamescope
  Xwayland is `DISPLAY=:1` (host is `:0`).
- Login screen reached in under a minute; world (Northshire) reached with the DivxTac override, no freeze at
  100%. Timing not measured precisely.
- The lab copy of `Config.wtf` carried the user's remembered account name and password field; the automated
  login clears both fields first.

## Q2. Does injected keyboard input reach the client without taking the user's focus?
Result: **yes, keyboard; mouse clicks unreliable**

- `DISPLAY=:1 xdotool search --name '^Ascension$'` finds the client window; `xdotool key --window <id>` and
  `xdotool type --window <id> --delay 60` reach it.
- Host active window class was identical before and after every injection (`foot`): no focus change.
- Login: click account field, 20 `BackSpace`, type account, `Tab`, 20 `BackSpace`, type password, `Return`.
  The typed fields are visible on the screenshot, `Return` logs in.
- Kicked by the Ghost login ("You have been disconnected"): `Return` closes the dialog, remembered credentials
  log in again.
- Character screen: `Return` sent a few seconds after the list appears enters the world. A `Return` sent too
  early and a `xdotool mousemove --window <id> x y click 1` on "Enter World" did nothing. Mouse clicks inside
  gamescope are not proven to work: keep to keyboard input.
- Chat: `Return`, type `/say spike-input-ok`, `Return` shows `[Labspike] says: spike-input-ok` in the chat frame.
- Screenshots of the client work without the user's screen: `DISPLAY=:1 magick import -window <id> out.png`
  (800x600 PNG of the client window, readable by the agent). This answers part of Q5.

## Q3. Does a local addon load, and which channel hands data to the host?
Result: unverified

## Q4. Can the client be commanded without keyboard input (server message to the addon)?
Result: unverified

## Q5. In-client screenshot
Result: unverified

## User client untouched
Result: unverified

## Verdict and spec changes
Result: unverified
