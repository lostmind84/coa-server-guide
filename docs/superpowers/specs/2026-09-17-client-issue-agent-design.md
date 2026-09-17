# Client issue agent: design

Date: 2026-09-17
Status: approved design, not implemented

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

A hard-linked copy of the client, separate from the user's install. CoaProbe is installed only here. The
preflight must also check this copy, so that a lab client behind on patches cannot produce a false result.

### 2. Launcher `coa-client-lab` (`scripts/` in this repository)

Modelled on `coa-slot`:

- `start N`: write the realmlist for slot N's port, purge the lab client's `WDB` cache, launch the client in a
  nested gamescope with the DivxTac override on the dedicated workspace.
- `stop`: kill gamescope and the Wine processes, release the lock. Always cleans up, including after errors.
- `screenshot`, `type "<text>"`, `status`.
- A lock: one lab client at a time. A held lock means wait or give up, never take over a running check.

### 3. Addon `CoaProbe` (versioned in this repository)

Slash commands that answer with structured data. Every answer carries the request id so the agent can match
question and answer. The output channel from the client to the host is an open question for the spike (see
Milestone 0).

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
3. **Setup**: a Ghost scenario creates the account and puts the character in the required state, then logs the
   bot out.
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

0. **Spike** (throwaway code). It must answer:
   - Does the client reach the world inside nested gamescope with the DivxTac override?
   - Does injected keyboard input reach the client?
   - Does a local addon load in the Ascension client, and through which channel can it hand data to the host
     (SavedVariables written on `/reload` or logout, chat log, other)? Unverified today.

   If any answer is no, return to this design (for example, vision becomes the primary mode).
1. Lab client, `coa-client-lab` (start, stop, screenshot, type), preflight extended to the lab client.
2. CoaProbe: tooltip, auras, known spells, Lua errors.
3. `coa-client-check` in repro mode, validated by the controls above.
4. Verify mode and `/coa-triage` integration.

## Open questions

- CoaProbe output channel (Milestone 0).
- Whether the Ascension client restricts local addons (Milestone 0).
- Which already-fixed client-side issue serves as the positive control (chosen at Milestone 3).
