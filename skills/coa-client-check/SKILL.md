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
