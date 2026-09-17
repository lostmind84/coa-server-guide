# coa-client-check (Milestone 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A skill `coa-client-check` that runs one client-side issue check end to end in repro mode and returns
**reproduced**, **not reproduced** or **inconclusive** with its reason and evidence, validated by controls and by
one real open issue.

**Architecture:** The skill is text: it composes the existing tools (`coa-slot`, `coa-client-lab`, CoaProbe,
`coa-probe-read.py`, Ghost helpers) into a fixed order with written expectations and verdict rules. Its master copy
lives in the public guide (`skills/coa-client-check/SKILL.md`), symlinked into `~/.claude/skills/coa-client-check`
so Claude Code loads it on this machine. The guide also gains a section for developers who only want the addon,
without the lab.

**Tech Stack:** Claude Code skills (Markdown + frontmatter), `coa-client-lab`, CoaProbe, `coa-slot`, Ghost e2e
helpers, GM chat commands.

**Spec:** `docs/design/client-issue-agent.md` (component 4 and "Check flow"), with
`docs/design/client-issue-agent-spike-findings.md` for what the tools can and cannot do.

## Global Constraints

- The guide repository is public: no personal data, no session links, no AI attribution trailers, English only.
- The user's client (`~/CoaServer/client/ascension-live`) is never touched; only the lab client is driven.
- A slot is claimed before any server or client work; `coa-client-lab preflight N` FAIL means the only allowed
  verdict is **inconclusive**.
- `origin/main` of the server does not build right now (`AscensionChronomancerMovement.cpp:171`, `NearTeleportTo`
  called with a temporary). A local-only build fix is allowed to move forward; it is never committed or pushed.
- Never `pkill -f` near the client. Stop the lab client with `coa-client-lab stop`.
- Nothing is posted to GitHub (issue comments included) without the user's explicit agreement.
- Known tool limits to respect in the skill text: no UI Lua error capture; CoaProbe has no action-bar command;
  a probe costs about 15 s; typed text must not contain `|`.
- Conventional Commits in the guide; the plan file itself is deleted once executed (guide convention).

## File Structure

| Path | Role |
|---|---|
| `skills/coa-client-check/SKILL.md` | the skill (master copy, public guide) |
| `~/.claude/skills/coa-client-check` | symlink to the directory above, so Claude Code loads it |
| `README.md` (guide) | new section "CoaProbe on its own" for developers without the lab |
| `docs/design/client-issue-agent.md` | Milestone 3 marked done |
| `docs/design/client-issue-agent-spike-findings.md` | control runs and the real check appended |
| `~/Projects/azerothcore-wotlk-coa/.agents/plans/3935/client/` | evidence of the real check (gitignored) |

---

### Task 1: The skill

**Files:**
- Create: `skills/coa-client-check/SKILL.md`
- Create: symlink `~/.claude/skills/coa-client-check` → `~/Projects/coa-server-guide/skills/coa-client-check`

**Interfaces:**
- Produces: the skill `coa-client-check`; the evidence layout `.agents/plans/<issue>/client/` with
  `expectation.md`, `answers/*.json`, `screenshots/*.png`, `context.txt`; the three verdicts.

- [ ] **Step 1: Write the skill**

`skills/coa-client-check/SKILL.md`:
```markdown
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

## Verdicts

- **reproduced**: the expectation failed exactly as the issue describes.
- **not reproduced**: the expectation held.
- **inconclusive**: anything else — red preflight, client or addon failure, an issue too vague to turn into an
  expectation, a symptom the tools cannot observe.

A technical failure is never "not reproduced": closing a real issue costs more than one more run.

## 1. Preconditions

1. `coa-slot list`, then `coa-slot claim N "<issue> client check"`; `coa-slot claim-issues N <issue>`.
2. The slot runs the revision the check needs (`coa-slot deploy N origin/main`, or the fix branch in verify mode).
3. `coa-client-lab preflight N` must be PASS. A FAIL stops the check with **inconclusive**, naming the failing line.
4. The lab client exists (`coa-client-lab create` once) and no other check holds it (`coa-client-lab status`).

## 2. Expectation

Read the issue, then write one or more checkable expectations in `.agents/plans/<issue>/client/expectation.md`:
what will be observed, with which probe, and which result means the issue is reproduced. Examples:

- `probe spell 706240` — tooltip line 1 is the spell name and the description says the debuff lands on the target.
- `probe auras target` after casting 706240 — the aura is on the target, not on the player.
- `probe item 6948` — the tooltip has a "Use:" line.

If the issue cannot be turned into an expectation (no spell id, no reproduction path, a symptom nobody can see
twice), ask the question in the issue and stop with **inconclusive**.

What the tools cannot observe today: UI Lua errors, action-bar contents, 3D models, animations, anything purely
visual. Pure visuals are judged from screenshots and marked "visual, needs user confirmation"; the rest is
**inconclusive** with the missing capability named.

## 3. Setup

Put the character in the state the issue names, cheapest first:

1. GM chat commands through `coa-client-lab chat` (`.learn <spell>`, `.aura <spell>`, `.levelup`, `.localspec`,
   `.additem`, `.gm off` before anything that needs the world to react to a player).
2. A Ghost scenario when the state needs more than commands (class and spec creation, talents, a second actor).
   The character itself is created by a Ghost login: the CoA creation screen is not driven by input.

Record what you did: every command lands in the evidence folder.

## 4. Observe

1. `coa-client-lab start N`, then `coa-client-lab login <account> <password>` (about 90 s).
2. One `coa-client-lab probe <command>` per expectation; save each answer under `answers/`.
3. One `coa-client-lab screenshot` per finding, saved under `screenshots/`.
4. Keyboard only: slash commands and GM commands. No blind clicking. Typed text must not contain `|`.
5. A probe costs about 15 s because it forces a `/reload`; group the requests you need.

## 5. Verdict and evidence

`.agents/plans/<issue>/client/` holds `expectation.md`, `answers/`, `screenshots/` and `context.txt` with the
slot number, the deployed commit, the preflight result and the account and character used.

State the verdict with the fact that produced it, quoting the probe answer. If the observed value differs from the
issue's claim, report what you saw: the issue may be right about the symptom and wrong about the cause.

## 6. Reporting

Propose a 1 to 3 line comment (the `coa-fix-issues` format) with the decisive screenshot. Post it only after the
user agrees. In verify mode, no "fixed" claim without a failing repro on the same expectation beforehand.

## Errors

| Situation | Verdict |
|---|---|
| Preflight FAIL, or the slot is not the revision under test | inconclusive, quote the failing line |
| The client does not reach the world | inconclusive, keep `~/CoaServer/client-lab/state/client.log` |
| A probe times out (`no CoaProbe answer`) | one retry, then inconclusive |
| A probe answer has an `error` field | inconclusive unless the error itself is the finding |
| The client crashes or freezes | `coa-client-lab stop`, inconclusive; a reproducible crash is a finding |
| The symptom needs a capability the tools lack | inconclusive, name the capability |

Always finish with `coa-client-lab stop` and `coa-slot release N`, even after a failure.
```

- [ ] **Step 2: Install and check the skill loads**

```bash
ln -s ~/Projects/coa-server-guide/skills/coa-client-check ~/.claude/skills/coa-client-check
ls -l ~/.claude/skills/coa-client-check/SKILL.md
head -5 ~/.claude/skills/coa-client-check/SKILL.md
```
Expected: the file is readable through the symlink. Claude Code lists skills at session start, so the new skill
appears in the next session, not this one; note that in the report instead of claiming it is loaded.

- [ ] **Step 3: Commit**

```bash
git add skills/coa-client-check/SKILL.md
git commit -m "feat(skill): add the coa-client-check workflow"
```

---

### Task 2: CoaProbe for developers without the lab

**Files:**
- Modify: `README.md` (guide), new subsection after the client lab part of Part 2

**Interfaces:**
- Produces: instructions for installing and using CoaProbe by hand, on Linux or Windows, and reading answers.

- [ ] **Step 1: Write the section**

Add after the client lab paragraph:
```markdown
### CoaProbe on its own

The probe addon does not need the lab client, the slots or Linux: it answers in any 3.3.5 client, typed by hand.

1. Copy [`addons/CoaProbe`](addons/CoaProbe) (without `tests/`) into `Interface/AddOns/CoaProbe` of your client
   and start the client (an addon folder added while it runs is not loaded by `/reload`).
2. In game, type a request with an id of your choice:
   `/coaprobe r1 spell 706240`, `/coaprobe r2 item 6948`, `/coaprobe r3 auras target`, `/coaprobe r4 spellbook`,
   `/coaprobe r5 known 78`. The chat answers `COAPROBE r1 ok`.
3. Type `/reload`: the client writes the answers to
   `WTF/Account/<ACCOUNT>/SavedVariables/CoaProbe.lua` (`WTF\Account\<ACCOUNT>\SavedVariables\CoaProbe.lua` on
   Windows).
4. Read one answer as JSON: `python3 scripts/coa-probe-read.py <that file> r1`.

Answers are JSON: `spell` gives name, rank, icon, cost, cast time, range, whether the character knows it and the
tooltip lines; `item` gives the tooltip lines; `auras` gives name, spell id, stacks, duration, expiry, caster and
whether it is harmful for every aura on the unit; `spellbook` lists the known spells with their ids; `known` answers
one spell id. The addon keeps the last 50 answers and never talks to the server, so it is safe on a live realm.
Limits: it cannot read action bars, 3D models or UI Lua errors, and a request must not contain `|`.
```
Check the paths and command names against `scripts/coa-probe-read.py` and `addons/CoaProbe/Commands.lua` before
committing; correct the text if they differ.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: explain how to use CoaProbe without the lab client"
```

---

### Task 3: Controls

**Files:**
- Create: `~/CoaServer/client-lab-spike/m3-controls/` (throwaway evidence, outside any repository)
- Modify: `docs/design/client-issue-agent-spike-findings.md`

**Interfaces:**
- Consumes: the skill (Task 1).
- Produces: proof that the check can fail and that it is stable.

- [ ] **Step 1: Prepare a slot**

```bash
coa-slot list
coa-slot claim <free N> "client-check controls"
```
If the slot is not on `origin/main`, deploy it. `origin/main` does not build: apply the local-only fix
(`AscensionChronomancerMovement.cpp:171` — bind the position to a named variable before passing it) inside the
slot's build clone only, never commit it, and record in the report that the slot ran a patched build.
Then `coa-client-lab preflight <N>` (must be PASS) and make sure the lab account and character exist (Ghost
helpers, see `coa-ghost-harness`).

- [ ] **Step 2: Negative control — a deliberately wrong expectation**

Expectation: "the tooltip of spell 501281 says the damage is 999 Fire damage".
```bash
coa-client-lab start <N>
coa-client-lab login labspike labspike
coa-client-lab probe spell 501281 > ~/CoaServer/client-lab-spike/m3-controls/negative.json
```
Expected: the answer shows 35 Fire damage, so the expectation fails and the verdict is **reproduced**. A control
that "passes" here would mean the comparison does not bite.

- [ ] **Step 3: Positive control — an expectation that must hold**

Expectation: "the tooltip of spell 501281 names Fel Fireball and costs 35 Energy".
```bash
coa-client-lab probe spell 501281 > ~/CoaServer/client-lab-spike/m3-controls/positive.json
```
Expected: verdict **not reproduced** (nothing wrong), from the same answer.

- [ ] **Step 4: Stability — the same check three times**

```bash
for i in 1 2 3; do coa-client-lab probe spell 501281 > ~/CoaServer/client-lab-spike/m3-controls/stable-$i.json; done
python3 - <<'PY'
import json, pathlib
base = pathlib.Path.home() / "CoaServer/client-lab-spike/m3-controls"
results = [json.load(open(base / f"stable-{i}.json"))["result"] for i in (1, 2, 3)]
print("identical:", results[0] == results[1] == results[2])
PY
```
Expected: `identical: True` (the `req` and `time` fields differ, the result does not).

- [ ] **Step 5: Record**

Append to `docs/design/client-issue-agent-spike-findings.md` a `## Milestone 3 controls` section: the slot, the
deployed commit and whether it was patched locally, the three control results, and the observed time per probe.
Commit: `docs(design): record the client-check controls`.

---

### Task 4: One real issue

**Files:**
- Create: `~/Projects/azerothcore-wotlk-coa/.agents/plans/3935/client/` (gitignored evidence)
- Modify: `docs/design/client-issue-agent.md`, `docs/design/client-issue-agent-spike-findings.md`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Read the issue and write the expectation**

Issue jealous-sound/azerothcore-wotlk-coa#3935, "Arbalest Mastery is being displayed wrong": spell 706240, class
id 15, level 60; the reporter says the debuff shows on the player instead of the enemy, while the damage
amplification is correct.
Write `.agents/plans/3935/client/expectation.md`: after casting 706240 on a target, `probe auras target` lists an
aura with spell id 706240 and `probe auras player` does not. Reproduced = the aura is on the player, or missing
from the target.

- [ ] **Step 2: Setup**

Create or reuse a character able to cast 706240 (GM commands first: `.learn 706240`, `.levelup`, a spec if the
spell needs one; a Ghost scenario if commands are not enough). Get a valid target: a training dummy is neutral
(faction 7) and some code gated on hostility does not run against it — prefer a hostile creature, and use
`.gm off` so it reacts. Record every command in the evidence folder.

- [ ] **Step 3: Observe**

Cast the spell from the client (`coa-client-lab chat` cannot cast; use `.cast 706240` on the selected target, or
a keybound action if casting is needed as a player), then:
```bash
coa-client-lab probe auras target > .agents/plans/3935/client/answers/auras-target.json
coa-client-lab probe auras player > .agents/plans/3935/client/answers/auras-player.json
coa-client-lab probe spell 706240 > .agents/plans/3935/client/answers/spell.json
coa-client-lab screenshot .agents/plans/3935/client/screenshots/after-cast.png
```
If `.cast` is not accepted or the aura never appears, say so and stop with **inconclusive**; do not invent a
substitute cast.

- [ ] **Step 4: Verdict and report**

Write the verdict with the decisive answer quoted, and `context.txt` (slot, commit, preflight, account, character).
Propose a 1 to 3 line comment for the issue and **wait for the user's agreement** before posting anything.
Then `coa-client-lab stop`, `coa-slot release <N>`.

- [ ] **Step 5: Record and close the milestone**

Append `## Milestone 3 real check (#3935)` to the spike findings: expectation, what the probes returned, verdict,
and anything the tools could not observe. In `docs/design/client-issue-agent.md`, replace the Milestone 3 line by:
```markdown
3. **`coa-client-check` in repro mode**: done 2026-09-17 (`skills/coa-client-check/SKILL.md`), validated by the
   controls and one real issue (#3935).
```
Note in the same commit that issue #3965 (action-bar icons stacking) needs a CoaProbe `actionbar` command, which
does not exist yet.
Commit: `docs(design): record the first client check and close milestone 3`.
