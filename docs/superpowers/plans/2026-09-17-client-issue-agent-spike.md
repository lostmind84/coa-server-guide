# Client Issue Agent: Milestone 0 Spike Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer the spike questions of the design (client in nested gamescope, input injection, addon output
channel) with evidence, and give a go / no-go for Milestones 1-4.

**Architecture:** A separate lab copy of the client and of its Wine prefix runs inside a nested gamescope on a
dedicated Hyprland workspace, against a claimed `coa-slot` server. A throwaway addon probes the output channels.
Every result lands in one findings file; all spike code is throwaway.

**Tech Stack:** gamescope, umu-run / GE-Proton, Hyprland (`hyprctl`), xdotool or wtype, WoW 3.3.5a Lua addon API,
`coa-slot`, Ghost e2e harness.

**Spec:** `docs/superpowers/specs/2026-09-17-client-issue-agent-design.md`

Plans for Milestones 1-4 are written after this spike: their shape depends on its answers (output channel, input
method, lab copy method).

## Global Constraints

- The user's own client (`~/CoaServer/client/ascension-live`), its Wine prefix (`~/Games/umu/coa-client`), WTF
  config, SavedVariables and addons must never be modified. Task 1 records checksums; Task 6 compares them.
- Server work uses a claimed `coa-slot` slot. A red `coa-slot preflight N` blocks any conclusion.
- Changing shared server DBCs or the user's client needs the user's agreement.
- Nothing is posted to GitHub.
- Package installs need `sudo`: the user runs them (suggest `! sudo pacman -S ...`).
- Spike code is throwaway: it lives in `~/CoaServer/client-lab-spike/`, never in a repository. Only the findings
  file is committed.
- Anything not observed during the spike is written as "unverified", never as a result.

## Facts checked while writing this plan (2026-09-17)

- Installed: `wtype`, `grim`, `hyprctl`, `umu-run`. **Not installed:** `gamescope` (in `extra`, 3.16.28-1),
  `xdotool`, `ydotool`.
- `~/CoaServer` is on btrfs, so `cp --reflink=always` gives a near-free, independent copy (the spec says
  hard links; hard links would share file contents with the user's client, reflinks do not).
- The user's `WTF/Config.wtf` currently has `SET realmList "127.0.0.1:3824"` (a slot port, not slot 1's 3724).
  The spike does not touch it.
- `coa-client --kill` matches the process path `ascension-live\Ascension.exe`, so the lab directory must use
  another name.
- `coa-slot` has no console command; server-side GM commands go through a GM character (Ghost bot).
- `.announce` exists in `src/server/scripts/Commands/cs_message.cpp`.

## File Structure

| Path | Role |
|---|---|
| `~/CoaServer/client-lab/ascension-lab/` | reflink copy of the client (lab only) |
| `~/Games/umu/coa-client-lab/` | reflink copy of the Wine prefix |
| `~/CoaServer/client-lab-spike/run-lab.sh` | throwaway launcher: gamescope + umu-run |
| `~/CoaServer/client-lab-spike/checksums-user-client.txt` | baseline to prove the user's client is untouched |
| `.../ascension-lab/Interface/AddOns/CoaProbeSpike/` | throwaway probe addon (`.toc`, `.lua`) |
| `docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md` | findings, committed in this repo |

---

### Task 1: Lab copies and baseline

**Files:**
- Create: `~/CoaServer/client-lab/ascension-lab/` (copy), `~/Games/umu/coa-client-lab/` (copy)
- Create: `~/CoaServer/client-lab-spike/checksums-user-client.txt`
- Create: `docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md`

**Interfaces:**
- Produces: `LAB_CLIENT=~/CoaServer/client-lab/ascension-lab`, `LAB_PREFIX=~/Games/umu/coa-client-lab`, the
  baseline checksum file, the findings file with one section per question.

- [ ] **Step 1: Check the user's client is not running**

Run: `pgrep -af 'Ascension.exe' || echo "no client"`
Expected: `no client`. Otherwise ask the user to close it and stop here.

- [ ] **Step 2: Record the baseline of the user's client**

```bash
mkdir -p ~/CoaServer/client-lab-spike
cd ~/CoaServer/client/ascension-live
find WTF Interface/AddOns -type f -print0 | sort -z | xargs -0 sha256sum > ~/CoaServer/client-lab-spike/checksums-user-client.txt
wc -l ~/CoaServer/client-lab-spike/checksums-user-client.txt
```
Expected: a non-zero line count.

- [ ] **Step 3: Make the reflink copies**

```bash
mkdir -p ~/CoaServer/client-lab
cp -a --reflink=always ~/CoaServer/client/ascension-live ~/CoaServer/client-lab/ascension-lab
cp -a --reflink=always ~/Games/umu/coa-client ~/Games/umu/coa-client-lab
df -h ~/CoaServer | tail -1
```
Expected: both commands exit 0; free space nearly unchanged (was 182G). If `--reflink=always` fails, stop and
record it: a full 44G copy needs the user's agreement.

- [ ] **Step 4: Create the findings file**

```markdown
# Client issue agent: spike findings

Date: 2026-09-17
Plan: docs/superpowers/plans/2026-09-17-client-issue-agent-spike.md

## Q1. Does the client reach the world inside nested gamescope?
Result: unverified

## Q2. Does injected keyboard input reach the client without taking the user's focus?
Result: unverified

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
```

- [ ] **Step 5: Commit the findings skeleton**

```bash
cd ~/Projects/coa-server-guide
git add docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md
git commit -m "docs(spike): add client issue agent findings skeleton"
```

---

### Task 2: Q1, client in nested gamescope

**Files:**
- Create: `~/CoaServer/client-lab-spike/run-lab.sh`
- Modify: findings file, section Q1

**Interfaces:**
- Consumes: `LAB_CLIENT`, `LAB_PREFIX` from Task 1.
- Produces: `run-lab.sh <slot>` that starts the lab client in gamescope on workspace 9; the exact gamescope flags
  that worked.

- [ ] **Step 1: User installs gamescope**

Ask the user to run: `! sudo pacman -S gamescope`
Then run: `gamescope --help 2>&1 | head -60`
Record in the findings file the flags actually present for output size (`-W`/`-H`), game size (`-w`/`-h`) and
any backend option. Use only flags shown by this help output.

- [ ] **Step 2: Claim a slot and check it**

```bash
coa-slot list
coa-slot claim 3 "client-spike lab client probes"
coa-slot env 3
coa-slot preflight 3
```
Expected: claim succeeds (if slot 3 is taken, use a free slot and substitute its number everywhere), preflight
PASS. Note the authserver port from `env`. A FAIL stops the spike.

- [ ] **Step 3: Point the lab client at the slot**

Set `SET realmList "127.0.0.1:<authserver port of the slot>"` in
`~/CoaServer/client-lab/ascension-lab/WTF/Config.wtf`, and the same `set realmlist 127.0.0.1:<port>` line in
`~/CoaServer/client-lab/ascension-lab/Data/enUS/realmlist.wtf`.
Also delete `~/CoaServer/client-lab/ascension-lab/Cache` (WDB cache purge from the spec).

- [ ] **Step 4: Write the throwaway launcher**

```bash
#!/bin/bash
# Throwaway spike launcher: lab client in nested gamescope on Hyprland workspace 9.
set -euo pipefail
LAB_CLIENT="$HOME/CoaServer/client-lab/ascension-lab"
LAB_PREFIX="$HOME/Games/umu/coa-client-lab"
PROTON="$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton11-6-x86_64"
LOG="$HOME/CoaServer/client-lab-spike/lab-client.log"
cd "$LAB_CLIENT"
# Replace the gamescope flags with the ones recorded in Task 2 Step 1.
hyprctl dispatch exec "[workspace 9 silent] env WINEPREFIX=$LAB_PREFIX GAMEID=0 PROTONPATH=$PROTON WINEDLLOVERRIDES=divxtac=d gamescope -W 1280 -H 720 -w 1280 -h 720 -- umu-run Ascension.exe >>$LOG 2>&1"
```
Save as `~/CoaServer/client-lab-spike/run-lab.sh`, `chmod +x`. The `[workspace 9 silent]` exec rule and the
working directory inheritance through `hyprctl dispatch exec` are unverified: if the client does not find `Data/`,
wrap the command as `bash -c 'cd <LAB_CLIENT> && ...'`.

- [ ] **Step 5: Run it and observe**

Run: `~/CoaServer/client-lab-spike/run-lab.sh`, wait 60 s, then:
```bash
hyprctl clients -j | grep -iE '"class"|"title"|"workspace"' | head -20
pgrep -af 'ascension-lab' | head
tail -30 ~/CoaServer/client-lab-spike/lab-client.log
```
Expected: a gamescope client on workspace 9, an `ascension-lab\Ascension.exe` process. Ask the user to look at
workspace 9 and confirm the login screen shows.

- [ ] **Step 6: Reach the world (manual login allowed here)**

Ask the user to log in on the lab client with a GM account of the slot and enter the world with any character.
Q1 only asks whether the world loads in gamescope; automated login is Q2.
Expected: the world renders, no freeze at 100% loading.

- [ ] **Step 7: Record Q1 and stop the client**

Write in section Q1: pass/fail, gamescope flags used, time to login screen and to world, any log lines of
interest. Stop with `pkill -f 'ascension-lab\\Ascension.exe'; pkill -x gamescope` only if `pgrep -af gamescope`
shows the lab instance alone.

```bash
cd ~/Projects/coa-server-guide
git add docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md
git commit -m "docs(spike): record nested gamescope result"
```

If Q1 fails after trying the flags from the help output, record why and go straight to Task 6 (verdict: no-go
for nested gamescope; the design must be revisited).

---

### Task 3: Q2, keyboard injection without taking the user's focus

**Files:**
- Modify: findings file, section Q2

**Interfaces:**
- Consumes: `run-lab.sh` from Task 2.
- Produces: the input method that works (tool, target, command form) and whether it moves host focus.

- [ ] **Step 1: User installs xdotool**

Ask the user to run: `! sudo pacman -S xdotool`

- [ ] **Step 2: Find the lab client's X display**

Start the lab client (`run-lab.sh`), wait for the login screen, then:
```bash
pid=$(pgrep -f 'ascension-lab\\Ascension.exe' | head -1)
tr '\0' '\n' < /proc/$pid/environ | grep -E '^(DISPLAY|WAYLAND_DISPLAY|GAMESCOPE)'
```
Expected: a `DISPLAY` value belonging to gamescope's Xwayland (different from the host's `echo $DISPLAY`). Record
both.

- [ ] **Step 3: Method A, xdotool on gamescope's display**

With focus on another window on the user's current workspace:
```bash
hyprctl activewindow -j | grep '"class"'
DISPLAY=<gamescope display> xdotool search --name '.' | head
DISPLAY=<gamescope display> xdotool type --delay 50 'abc'
hyprctl activewindow -j | grep '"class"'
```
Expected: `abc` appears in the account field of the lab client (user checks workspace 9), host active window class
identical before and after. If `xdotool type` without a target does not reach the client, retry with
`--window <id>` from the search output.

- [ ] **Step 4: Method B, wtype (only if Method A fails)**

`wtype` types into the focused Wayland window, so this method needs focus on workspace 9. Test it and record the
focus change: it breaks the "does not take the user's input" constraint and is acceptable only as a fallback.

- [ ] **Step 5: Automated login**

With the working method, type the GM account name, `Tab`, password, `Return`, then `Return` again at the character
list. Use `xdotool key Tab` / `xdotool key Return` for keys.
Expected: world loads without the user touching the client.

- [ ] **Step 6: Type a chat command**

In world: `Return`, type `/say spike-input-ok`, `Return`.
Expected: the text is visible in the lab client's chat (user confirms or Task 4's screenshot shows it).

- [ ] **Step 7: Record Q2 and commit**

Section Q2: method, display value, exact commands, delays needed, host focus before/after, failure modes seen.
Stop the lab client as in Task 2 Step 7.

```bash
cd ~/Projects/coa-server-guide
git add docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md
git commit -m "docs(spike): record keyboard injection result"
```

---

### Task 4: Q3 and Q5, probe addon, output channels, screenshot

**Files:**
- Create: `~/CoaServer/client-lab/ascension-lab/Interface/AddOns/CoaProbeSpike/CoaProbeSpike.toc`
- Create: `~/CoaServer/client-lab/ascension-lab/Interface/AddOns/CoaProbeSpike/CoaProbeSpike.lua`
- Modify: findings file, sections Q3 and Q5

**Interfaces:**
- Consumes: lab client + input method from Task 3.
- Produces: the output channel(s) that deliver `COAPROBE` data to the host, with latency; screenshot location.

- [ ] **Step 1: Write the addon**

`CoaProbeSpike.toc`:
```
## Interface: 30300
## Title: CoaProbeSpike
## Notes: Throwaway spike probe for the client issue agent
## SavedVariables: CoaProbeSpikeDB
CoaProbeSpike.lua
```

`CoaProbeSpike.lua`:
```lua
CoaProbeSpikeDB = CoaProbeSpikeDB or {}

local function tooltipLines(spellId)
    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    GameTooltip:SetHyperlink("spell:" .. spellId)
    local lines = {}
    for i = 1, GameTooltip:NumLines() do
        local left = _G["GameTooltipTextLeft" .. i]
        lines[#lines + 1] = left and left:GetText() or ""
    end
    GameTooltip:Hide()
    return lines
end

local function probe(req, spellId)
    local lines = tooltipLines(spellId)
    CoaProbeSpikeDB[#CoaProbeSpikeDB + 1] = { req = req, spell = spellId, time = time(), lines = lines }
    print("COAPROBE " .. req .. " " .. spellId .. " " .. table.concat(lines, " | "))
end

SLASH_COAPROBESPIKE1 = "/cps"
SlashCmdList["COAPROBESPIKE"] = function(msg)
    local req, spellId = msg:match("^(%S+)%s+(%d+)$")
    if not req then
        print("COAPROBE usage: /cps <req> <spellId>")
        return
    end
    probe(req, tonumber(spellId))
end

SLASH_COAPROBESHOT1 = "/cpshot"
SlashCmdList["COAPROBESHOT"] = function()
    Screenshot()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:SetScript("OnEvent", function(_, event, message)
    if event == "PLAYER_LOGIN" then
        print("COAPROBE loaded")
    elseif event == "CHAT_MSG_SYSTEM" and message then
        local req, spellId = message:match("COAPROBE%-CMD (%S+) (%d+)")
        if req then
            probe(req, tonumber(spellId))
        end
    end
end)
```

- [ ] **Step 2: Load check**

Start the lab client, log in with the Task 3 method.
Expected: `COAPROBE loaded` in chat (screenshot in Step 6 or user confirmation). If absent, check the character
screen AddOns list and `Logs/FrameXML.log` in the lab client; record whether the Ascension client lists or blocks
local addons.

- [ ] **Step 3: Channel A, SavedVariables**

Type `/cps a1 501281`, then `/reload`, wait 20 s:
```bash
find ~/CoaServer/client-lab/ascension-lab/WTF -name 'CoaProbeSpike.lua' -newer ~/CoaServer/client-lab-spike/run-lab.sh -exec cat {} \;
```
Expected: a `CoaProbeSpikeDB` entry with `req = "a1"` and tooltip lines. Record the delay between `/reload` and
the file update. Spell 501281 is Fel Fireball rank 2; any spell id present in the slot's Spell.dbc works.

- [ ] **Step 4: Channel B, chat log**

Type `/chatlog`, then `/cps b1 501281`, wait 5 s:
```bash
ls -la ~/CoaServer/client-lab/ascension-lab/Logs/ | grep -i chat
grep -a 'COAPROBE b1' ~/CoaServer/client-lab/ascension-lab/Logs/WoWChatLog.txt
```
Expected: the line appears. Record whether it is written at once or only later (repeat with `b2` and check every
second for 30 s). If no file appears, record "chat log channel: not available".

- [ ] **Step 5: Other log files**

```bash
grep -rla 'COAPROBE' ~/CoaServer/client-lab/ascension-lab/Logs/ 2>/dev/null
```
Record any other file that carries `print` output (none expected; this checks it).

- [ ] **Step 6: Q5, in-client screenshot**

Type `/cpshot`, wait 5 s:
```bash
find ~/CoaServer/client-lab/ascension-lab -iname '*.jpg' -newer ~/CoaServer/client-lab-spike/run-lab.sh -o -iname '*.tga' -newer ~/CoaServer/client-lab-spike/run-lab.sh
```
Expected: a new image file. Open it with the Read tool and check it shows the game, chat with `COAPROBE` lines
included. If `Screenshot()` writes nothing, try `grim` on the output showing workspace 9 and record which works.

- [ ] **Step 7: Record Q3 and Q5 and commit**

Sections Q3 (addon loads yes/no, each channel with latency and reliability) and Q5 (method, file location, format).
Stop the lab client.

```bash
cd ~/Projects/coa-server-guide
git add docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md
git commit -m "docs(spike): record addon output channel and screenshot results"
```

---

### Task 5: Q4, command channel without keyboard

**Files:**
- Modify: findings file, section Q4

**Interfaces:**
- Consumes: CoaProbeSpike (`CHAT_MSG_SYSTEM` handler) from Task 4; the slot's Ghost env (`coa-slot env 3`).
- Produces: whether a Ghost GM bot can command the lab client through a server message.

- [ ] **Step 1: Lab client in world**

Start and log in the lab client on account A as in Task 3.

- [ ] **Step 2: Send the message from a Ghost bot on another account**

In `~/Projects/ConquestOfAzerothGhost`, write a throwaway test under the `e2e` tag that logs in a GM bot (use an
existing scenario helper that sends GM chat commands; find it with Serena `find_symbol` on the harness) and sends
`.announce COAPROBE-CMD c1 501281`, then waits 10 s. Run it with the slot's Ghost env file from `coa-slot env 3`,
never the repo `.env`. Do not commit this test.

- [ ] **Step 3: Check the result**

Use the best channel from Task 4 (chat log or `/reload` + SavedVariables).
Expected: an entry with `req = "c1"`. Record the exact announce text as received (the server may prefix it, which
the Lua pattern tolerates because it is not anchored).

- [ ] **Step 4: Record Q4 and commit**

```bash
cd ~/Projects/coa-server-guide
git add docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md
git commit -m "docs(spike): record server message command channel result"
```

---

### Task 6: Verdict, cleanup, spec update

**Files:**
- Modify: findings file, sections "User client untouched" and "Verdict and spec changes"
- Modify: `docs/superpowers/specs/2026-09-17-client-issue-agent-design.md` (only the parts the findings change)

- [ ] **Step 1: Prove the user's client is untouched**

```bash
cd ~/CoaServer/client/ascension-live
sha256sum --quiet -c ~/CoaServer/client-lab-spike/checksums-user-client.txt && echo "UNCHANGED"
find WTF Interface/AddOns -type f | wc -l; wc -l < ~/CoaServer/client-lab-spike/checksums-user-client.txt
```
Expected: `UNCHANGED` and equal counts. Any difference is reported to the user at once. Note the user may have
played meanwhile: ask before calling a difference a spike defect.

- [ ] **Step 2: Stop everything and release the slot**

```bash
pgrep -af 'ascension-lab\\Ascension.exe|gamescope' || echo "nothing running"
coa-slot release 3
```
Kill only lab processes. Keep the lab copies: Milestone 1 reuses them (tell the user they can be removed with
`rm -rf ~/CoaServer/client-lab ~/Games/umu/coa-client-lab` if the verdict is no-go).

- [ ] **Step 3: Write the verdict**

In "Verdict and spec changes": go / no-go per question, the chosen input method, output channel, screenshot
method, and a list of spec changes. Known change: lab copy by reflink instead of hard links. Record also whether
the keyboard-free command channel (Q4) replaces typed slash commands.

- [ ] **Step 4: Update the spec**

Edit the design spec only where findings contradict it (for example "hard-linked copy" becomes "reflink copy",
the CoaProbe output channel is named, Open questions answered are removed). Change `Status:` to
`approved design, spike done (see spike findings)`.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/coa-server-guide
git add docs/superpowers/specs/2026-09-17-client-issue-agent-design.md docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md
git commit -m "docs(spike): client issue agent spike verdict and spec update"
```

- [ ] **Step 6: Report to the user**

Short summary: verdict, answers Q1-Q5, spec changes, next step (plan for Milestone 1 if go).
