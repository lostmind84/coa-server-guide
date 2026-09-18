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

## Not this skill

- A server value (damage, cost, cast time, cooldown, aura amount, loot, quest step): a `coa-gameplay-test`
  scenario proves it without a client and stays committed as a regression test.
- Anything a real session receives but does not render (packets, experience, movement, relogs, duels, several
  actors): a Ghost e2e test.
- Use this skill when the question is what the player *sees*, or when the server and the client disagree.

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

What the tools cannot observe today: Lua errors (a `seterrorhandler` wrapper never sees them), action-bar contents,
3D models, animations, anything purely visual. That is different from the red on-screen UI errors, which
`probe log` does capture (section 4 below). Pure visuals are judged from screenshots and marked "visual, needs
user confirmation"; the rest is **inconclusive** with the missing capability named.

## 3. Setup and action: Ghost first

The Ghost e2e harness builds a character in seconds (race and class at login, `SetLevel`, `SetSpecialization`
through `.localspec`, `Learn`, `AddItem`/`EquipEntry`, `Teleport`, `Spawn` for a fixture target) and can cast the
spell itself, checking both the server's aura list and the one the client receives. Typing GM commands into the lab
client is slower, blind and fails silently: use it only for a last tweak.

Split the work:

1. **Ghost** does the setup: account, character of the right race, class and level, spec, spells, equipment,
   position, and the target creature. It also performs the action (cast, use, pull) whenever the check is about
   values or about which unit carries an aura, and reports what the server and the packets say.
2. **The lab client** logs in afterwards on the same character and only observes what is *displayed*: tooltip
   text, aura on the unit frame, icon, model. It acts only when the action itself is a UI interaction that Ghost
   cannot perform.

A Ghost run that already contradicts the issue is a finding on its own: say so and check the display only if the
issue is about the display.

Record what you ran: the scenario or test name, the GM commands, the character. Everything lands in the evidence
folder.

## 4. Observe

1. `coa-client-lab start N`, then `coa-client-lab login <account> <password>` (about 90 s).
2. Drive the client with `chat` (slash and GM commands), `key`, `hold KEY MS` (walk with `w`/`s`, turn with
   `Left`/`Right`) and `screenshot`. Typed text must not contain `|`.
3. **Read what the screen forgets.** `coa-client-lab probe log [n]` returns the addon's capture of UI errors
   ("Target too close", "Not enough rage"), system messages and the player's casts with their failure reason.
   Nothing else shows why an action did not happen: the red error text fades and `/reload` clears the chat.
   Read the log after every action that could fail, before concluding anything.
4. **One request per moment.** `coa-client-lab probe state` snapshots the player and the current target together
   (name, level, health, every power index the client exposes, auras). A probe writes its answer through
   `/reload`, which clears the target selection, so two probes never describe the same situation.
5. **Snapshot inside the effect window.** Many auras last seconds: send the probe immediately after the action,
   without waiting. An empty aura list after a finished cast proves nothing.
6. Useful facts the client hides: the displayed bar is not always the resource a spell charges (`probe state`
   reports mana, rage, focus, energy and runic power); `.gps` prints the position into the captured system
   messages; `.go xyz X Y Z MAP O` takes the facing as its fifth number, which answers "Target needs to be in
   front of you".

## Getting the state you need, shortest route first

Waiting for the game to produce a condition rarely converges: rage decays out of combat, cooldowns return,
fixtures wander. Set the state instead, and record what you set.

- Resources: select the character (`/target <name>`) then `.modify rage 1000` (or `mana`, `energy`,
  `runicpower`). `.modify` acts on the selected *player*: with a creature selected it answers "No character
  selected."
- Fixture target: a training dummy at the character's own level (`.npc add 32666` then `.npc set level <level>`)
  never fights back, and the level gap does not distort hit or resist. Leave it at its default faction until a
  refusal proves a hostile one is needed.
- GM cheats (`.cheat god|power|cooldown`) change how the game behaves, so they are a last resort: use one only
  when a captured error proves it is the blocker, and write in the report which one and why. A dummy that cannot
  kill you removes the need for `god`; `.modify` removes the need for `power`.
- Prefer the normal player path for what the check is about: level, `.localspec`, `.localtalent <entry> <rank>`.
  If a forced `.learn` was used and the issue does not reproduce, redo it through the talent path before
  concluding: the acquisition method can be the difference. Talent entry ids come from
  `/srv/coa/server-data/dbc/CharacterAdvancement.dbc` (field layout in
  `modules/mod-ascension-compat/src/AscensionCoATalentData.cpp`).

## 5. Verdict and evidence

`.agents/plans/<issue>/client/` holds `expectation.md`, `answers/`, `screenshots/` and `context.txt` with the
slot number, the deployed commit, the preflight result and the account and character used.

State the verdict with the fact that produced it, quoting the probe answer. If the observed value differs from the
issue's claim, report what you saw: the issue may be right about the symptom and wrong about the cause.

## 6. Verify mode: the same expectation after a fix

A fix is verified only against a check that failed first. Reuse the repro run's `expectation.md` word for word.

1. Deploy the fix branch to the slot (`coa-slot deploy N <branch>`) and run `coa-client-lab preflight N` again. A
   data-only fix still needs the deploy: the slot database applies the migration there.
2. Rebuild the character with the same setup run, so nothing but the fix differs.
3. Repeat the same probes, in the same effect window, and save them next to the repro answers
   (`answers/verify-*.json`).
4. The fix passes only if the expectation now holds where it failed. Quote both answers side by side in the
   report; "it looks right now" is not a result.

Worked example (#3935): repro showed `Arbalest Mastery (706241)` with 3 stacks as **HARMFUL** on the caster; after
one `spell_custom_attr` row marking the aura positive, the same probe showed the same 3 stacks as **HELPFUL**.

## 7. Reporting

Propose a 1 to 3 line comment (the `coa-fix-issues` format) with the decisive answer quoted, and the screenshot
when the interface itself is the evidence — make the interface legible first (the spell on the action bar, the
frames visible), a bare screenshot proves nothing. Post only after the user agrees.

Name the ids and their names together: a human reads `706241 "Arbalest Mastery"`, not a bare number.

When the check contradicts the report, say what you saw rather than what was claimed, and look for the mechanism:
for #3935 the client classified a positive stacking effect as harmful, which is why the reporter called it a
debuff on themselves.

This check is a step of `coa-fix-issues`, not a workflow of its own: the issue claim, the branch, the commit, the
PR and the issue comment stay that skill's job; this one only produces the verdict and its evidence.

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
