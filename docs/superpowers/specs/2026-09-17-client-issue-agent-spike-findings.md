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
Result: **yes; SavedVariables is the working channel**

- The addon lives in `Interface/AddOns/CoaProbeSpike/` (`## Interface: 30300`). An addon folder added while the
  client runs is **not** picked up by `/reload` (`/cps` was unknown); after a client restart it loads. Neither
  load is logged in `Logs/FrameXML.log` (that log only lists the client's own `Ascension_*` load-on-demand
  addons). The user's client has no local addons, so the lab copy starts clean.
- `/cps a1 501281` printed `COAPROBE a1 501281 Fel Fireball | 35 Energy | 2 sec cast | Generates 1 Felfury ...
  dealing 35 Fire damage. | Usable while moving.`: `GameTooltip:SetHyperlink("spell:<id>")` returns the client
  tooltip text, including the CoA description line.
- **SavedVariables**: after `/reload`, `WTF/Account/LABSPIKE/SavedVariables/CoaProbeSpike.lua` was rewritten
  within 1 s and held the full entry (`req`, `spell`, `time`, `lines`). Lines keep colour codes (`|cff32cd32...|r`)
  and `\r\n` inside a line: the reader must strip or keep them on purpose.
- **Chat log**: `/chatlog` answers "Chat being logged to Logs\WoWChatLog.txt". `print` output never reaches the
  file; a real `/say` creates `Logs/WoWChatLog.txt`, but it stayed **empty** for over a minute (buffered; when it
  is flushed is unverified). Not usable as a live channel.
- `Logs/LUA.txt` only logs the `FrameXML.toc Loaded` markers, not `print` output.
- The lab login shows existing CoA UI errors (`Ascension_CharacterAdvancement`, `GetLearnedAE: Invalid argument
  type`) in `Logs/Error.txt`; they come from the client's own addons, not from the probe.

## Q4. Can the client be commanded without keyboard input (server message to the addon)?
Result: **yes**

- A second GM account `labsender` (character `Labsender`) logged in through Ghost `LoginBot` and sent
  `SendGMCommand(".announce COAPROBE-CMD c1 501281")`.
- The lab client received it as `[SERVER] [SERVER] COAPROBE-CMD c1 501281` on `CHAT_MSG_SYSTEM`; the unanchored
  Lua pattern matched and the probe ran (`COAPROBE c1 501281 Fel Fireball | ...` printed).
- Caveat: `.announce` is a broadcast to every player of the realm. On a claimed slot with only lab characters
  this is harmless, but a targeted message (whisper or a module command) would be cleaner. Not tested.
- Reading the result still needs the SavedVariables channel, which needs `/reload`, which is a keyboard action.
  Keyboard-free end to end is therefore not proven; the announce channel removes typing for requests only.

## Q5. In-client screenshot
Result: **yes, two ways**

- `Screenshot()` from the addon (`/cpshot`) wrote `Screenshots/WoWScrnShot_091726_121416.jpg` (JPEG, 800x600)
  within 2 s.
- `DISPLAY=:1 magick import -window <id>` captures the client window as PNG without the user's screen (Q2).
- Readability: at 800x600 the client text is too small, both for the user watching workspace 9 and in
  screenshots (the agent had to crop and enlarge the chat to read it). The user raised it during the spike. The
  lab client must run at a higher resolution; see the resolution check below.

## Resolution check

At the user's request the lab client moved from 800x600 to `gxResolution "1920x1080"` with gamescope
`-W 1920 -H 1080 -w 1920 -h 1080`. The window is 1920x1080, the chat is readable in screenshots without
enlarging, and the scaled login click (`HEIGHT * 315 / 600`) still works. The user chose to keep 1080p.

## User client untouched
Result: **untouched by the spike**

- `sha256sum -c` against the baseline reported 12 changed files, and 221 files exist against 189 in the
  baseline (taken 11:30:18).
- Every changed or new file is under account `LOCAL` or `WTF/Custom`, dated 11:40:24 to 11:55:29, for characters
  the lab never used (Gdfgfdgdf, Dsqdsq, Dzadaz). The lab client first started at 12:02:02 and uses account
  `LABSPIKE` in its own directory. No file of the user's client changed after 11:56.
- Conclusion: the user's client was used between 11:40 and 11:55 (its realmlist points at slot 2, port 3824),
  independently of the spike (the user confirmed manual tests). The baseline approach works, but a baseline must be taken right before the lab
  starts, or the check must be limited to files modified after the lab start.

## Verdict and spec changes
Result: **go for Milestones 1-4**

- Q1 yes, Q2 yes (keyboard only), Q3 yes (SavedVariables after `/reload`), Q4 yes for requests, Q5 yes.
- Chosen for Milestone 1: `hyprctl eval` + `hl.exec_cmd` launch on workspace 9, `xdotool` on gamescope's
  display, `magick import` screenshots, stop by PID, 1920x1080.
- Chosen for Milestone 2: CoaProbe answers in SavedVariables, read after a typed `/reload`; requests typed, with
  the server-message path kept as an option.
- Spec changes: reflink copy instead of hard links, launcher commands and Hyprland 0.56 launch form, CoaProbe
  install-before-start and output channel, lab `WTF` without the user's remembered account, 1080p, character
  creation through Ghost, Milestone 0 marked done, open questions updated.
- State left behind: lab copies kept (`~/CoaServer/client-lab`, `~/Games/umu/coa-client-lab`) with the throwaway
  `CoaProbeSpike` addon; throwaway scripts in `~/CoaServer/client-lab-spike`; accounts `labspike` and `labsender`
  (GM 3, characters `Labspike` and `Labsender`) remain in slot 3's database; slot 3 released.
