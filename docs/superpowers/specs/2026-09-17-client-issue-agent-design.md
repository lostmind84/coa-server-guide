# Client issue agent: design

Date: 2026-09-17
Status: approved design, spike done (see `2026-09-17-client-issue-agent-spike-findings.md`)

## Goal

Let an agent reproduce, and later verify fixes for, CoA issues whose symptom is only visible in the game
client: wrong tooltip text or values, missing icons or models, broken UI or Lua errors. The Ghost e2e bots
work at protocol level and cannot see these symptoms.

Scope, in order:

1. **Repro**: given an open issue, drive the real client, collect evidence and give a verdict.
2. **Verify**: run the same check after a fix is deployed to a server slot.

Out of scope for now: headless rendering, several lab clients in parallel, bots that play through the client,
writing fixes (the existing `/coa-triage` flow already does that).

## Constraints

- The client is `Ascension.exe` under umu-run / GE-Proton. It enters the world only with
  `WINEDLLOVERRIDES="divxtac=d"`.
- The user's own client, WTF config, SavedVariables and addons must never be touched.
- Server work uses `coa-slot` slots. A red `coa-slot preflight N` blocks any conclusion.
- Changing shared server DBCs or the user's client needs the user's agreement.
- Nothing is posted to GitHub without the user's agreement.

## Approach

Hybrid observation:

- A debug addon (**CoaProbe**) returns structured facts: tooltip lines, auras, known spells, visible frames,
  captured Lua errors. These facts are the primary evidence.
- A screenshot backs every finding, as readable proof in the issue. For purely visual bugs (icon, model,
  animation) the screenshot is the only evidence, and the verdict is marked "visual, needs user confirmation".
- Character setup reuses the Ghost harness helpers (account, level, class, spec, spells, talents, items). The
  client only logs in and observes.

Rejected alternatives:

- Vision only (screenshots plus injected mouse and keyboard): generic but slow and fragile, and reading a digit
  from an image is exactly the kind of value the checks must get right.
- Addon only: exact, but blind to purely visual bugs.

The client runs in a nested gamescope window on a dedicated Hyprland workspace: it does not take the user's
input devices, and the user can watch the agent. Headless gamescope can come later without changing the other
components.

## Components

### 1. Lab client (`~/CoaServer/client-lab`)

A reflink copy (`cp -a --reflink=always`, btrfs) of the client and of its Wine prefix
(`~/Games/umu/coa-client-lab`), separate from the user's install. Hard links are not used: they would share file
contents with the user's client. CoaProbe is installed only here. The preflight must also check this copy, so
that a lab client behind on patches cannot produce a false result.

The lab client runs at `gxResolution "1920x1080"`: at 800x600 the text is unreadable for the user watching and
in screenshots. Its `WTF` must not keep the user's remembered account; the copy made for the spike did.

### 2. Launcher `coa-client-lab` (`scripts/` in this repository)

Modelled on `coa-slot`:

- `start N`: write the realmlist for slot N's auth port (`WTF/Config.wtf` and `Data/enUS/realmlist.wtf`),
  purge the lab client's `Cache`, launch the client in a nested gamescope (`-W 1920 -H 1080 -w 1920 -h 1080`) with
  the DivxTac override on workspace 9. Hyprland 0.56 uses a Lua config: launch through
  `hyprctl eval "hl.exec_cmd([[<cmd>]], { workspace = \"9 silent\" })"`.
- `login <account>`: keyboard-only login and world entry (see findings Q2 for the sequence and delays).
- `stop`: stop the lab Wine process by PID (never `pkill -f` with a pattern that can match the caller's own
  command line), wait for gamescope to exit, release the lock. Always cleans up, including after errors.
- `type "<text>"` and `key <key>`: `xdotool` on gamescope's Xwayland display (`DISPLAY=:1` during the spike;
  read it from the client process environment), window found by `xdotool search --name '^Ascension$'`. Keyboard
  only: mouse clicks inside gamescope are unreliable.
- `screenshot`: `magick import -window <id>` on the same display.
- `status`.
- A lock: one lab client at a time. A held lock means wait or give up, never take over a running check.

### 3. Addon `CoaProbe` (versioned in this repository)

Slash commands that answer with structured data. Every answer carries the request id so the agent can match
question and answer.

- Install before the client starts: an addon folder added while the client runs is not loaded by `/reload`.
- Requests: a typed slash command, or a server message parsed on `CHAT_MSG_SYSTEM` (a Ghost GM bot sending
  `.announce COAPROBE-CMD <req> <args>` worked; `.announce` is a realm-wide broadcast).
- Output: answers are stored in the addon's SavedVariables and read from
  `WTF/Account/<ACCOUNT>/SavedVariables/CoaProbe.lua` after a typed `/reload` (file rewritten within 1 s). Strings
  keep colour codes and `\r\n`. The chat log is not a channel: `print` is not logged and the file stays empty
  while buffered.
- `Screenshot()` writes `Screenshots/WoWScrnShot_*.jpg` within 2 s and is an alternative to the host capture.

### 4. Skill `coa-client-check`

Same family as `coa-gameplay-test`. Runs one check end to end and returns one of three verdicts:
**reproduced**, **not reproduced**, **inconclusive**, always with the reason.

### 5. `/coa-triage` integration

Issues with a client-side symptom go through `coa-client-check`: repro mode before the fix, verify mode after
the fix is deployed to the slot.

## Check flow

### Repro mode

1. **Preconditions**: slot claimed, `coa-slot preflight N` green, lab client on the same patch. Otherwise stop
   with **inconclusive**.
2. **Read the issue** and write a *checkable expectation*, for example "tooltip of spell 501281 shows damage X"
   or "no Lua error when opening the talent panel". If the issue is too vague for that, ask in the issue and run
   nothing.
3. **Setup**: a Ghost scenario creates the account and the character (the CoA character creation screen is not
   driven by input) and puts it in the required state, then logs the bot out.
4. **Observe**: `coa-client-lab start N`, log in to the character, send CoaProbe requests, take one screenshot
   per finding. Actions are limited to slash commands and GM commands; no blind clicking.
5. **Verdict**: compare CoaProbe facts with the expectation.
6. **Evidence folder** `.agents/plans/<issue>/client/`: expectation, raw CoaProbe answers, screenshots, server
   revision, DBC hash.
7. **Issue comment**: short (1 to 3 lines) with the screenshot, posted only after the user agrees.

### Verify mode

Deploy the fix branch to the slot, patch the lab client if the fix changes client DBCs, run the preflight, then
steps 3 to 6 with the *same expectation*. A fix counts as verified only if the expectation passes where it
failed in repro mode. Without a failing repro first, the agent does not claim a fix.

## Error handling

Any technical failure gives **inconclusive**, never **not reproduced**: a false negative would close a real
issue.

| Situation | Response |
|---|---|
| Client does not start or does not reach the world within the timeout | Screenshot and Proton log (`--debug`), stop the client, inconclusive |
| CoaProbe silent (addon not loaded, no answer) | One retry, then inconclusive. No textual conclusion from a screenshot alone |
| Client crash or freeze | `coa-client-lab stop`, keep any core dump, inconclusive. A reproducible crash is itself a finding |
| Server disconnect | Check the slot (container restarted?), rerun the preflight, retry once |
| Stale client cache | `WDB` purged at every start |
| Lock held | Wait or give up |
| Visual-only finding | Verdict allowed, marked "visual, needs user confirmation" |

## Validating the tool itself

- **Positive control**: a known client-side issue that is already fixed, replayed on a revision before the fix
  (expect reproduced) and on the fixed revision (expect not reproduced).
- **Negative control**: a deliberately wrong expectation must give reproduced, which proves the comparison
  actually fails when it should.
- **Stability**: the same check run 3 times in a row gives the same verdict.

## Milestones

Each milestone is usable on its own.

0. **Spike**: done 2026-09-17, go. All questions answered yes (nested gamescope, keyboard injection, local
   addon with SavedVariables output, server-message requests, screenshots). Details in the spike findings.
1. **Lab client and launcher**: done 2026-09-17 (`scripts/coa-client-lab`, tests in
   `scripts/tests/coa-client-lab.test.sh`, preflight through `coa-client-lab preflight N`). Real run on slot 2:
   login, chat, screenshots and stop (3 s, no process left) worked.
2. CoaProbe: tooltip, auras, known spells, Lua errors.
3. `coa-client-check` in repro mode, validated by the controls above.
4. Verify mode and `/coa-triage` integration.

## Open questions

- Which already-fixed client-side issue serves as the positive control (chosen at Milestone 3).
- A targeted server message instead of the realm-wide `.announce` for keyboard-free requests (not tested).
- When the client flushes `Logs/WoWChatLog.txt` (not needed while SavedVariables works).
