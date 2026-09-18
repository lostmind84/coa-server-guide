---
description: List the open CoA issues grouped into work batches, then work a chosen batch end to end
argument-hint: "[batch name, e.g. starcaller | crashes | quests] [manual] [per-issue]"
---

# CoA issue triage and fixing

An agent workflow for the CoA issue queue, built around the tooling in this guide. Nothing here is specific to one
contributor: the steps that need repository permissions fall back to what an outside contributor can do.

Work the CoA issue queue: with no argument, print the batch table and stop; with a batch name or issue numbers,
work that queue end to end. `manual` pauses for approval before each fix (default is auto). `per-issue` opens one
PR per issue instead of one per batch.

Environment: server slots, preflight, the Ghost e2e bots and the client lab are documented in
[Part 2](../README.md#part-2-contributor-tooling) of this guide. If your agent has its own workstation guidance
(paths, slot manager, harness pitfalls), follow that for anything touching a server. Repository conventions: the
checkout's `AGENTS.md` and `.agents/docs/`.

Resolve once per run and keep it in the conversation: the repository from `origin`
(`gh repo view --json nameWithOwner`), your login (`gh api user --jq .login`), your permissions
(`gh api repos/<owner>/<repo> --jq .permissions`) and the remote to push to — your fork, or `origin` only when you
have `push` and the maintainers expect branches there. Never push to `main` or `upstream`.

Talk to the user in their language. Everything written to the repository or GitHub — code, commits, branch names,
PR titles and bodies, issue comments — is English.

## Step 1 — always: print the batch table

```
gh issue list -R jealous-sound/azerothcore-wotlk-coa --state open --limit 1000 --json number,title,assignees
```

The count is above 3,400, so check whether the result hit the limit and page if it did. Most of the queue is a
spell audit filed report by report ("no script or aura handler"): group those **by class, and by spec when a class
is too large for one reviewable PR**, as in PR #2521. Group the rest by theme: crashes; resources (power and aura
costs and gains); summons and pets; missing talent trees and specs; items, bank and vanity; quests, world and
creatures; systems and modes (RDF, Manastorm, war mode, GM, rest); client UI and visual (not testable by a
protocol bot); duplicates and non-bugs.

Before working an issue, re-read its state, assignees and the PRs referencing it. Claim it: with `triage` or
`push` permission, `gh issue edit <n> -R <repo> --add-assignee <login>`; without, post one short comment
(`Working on this in <branch>.`). An issue assigned to someone else, or already carrying someone else's PR, is
skipped and reported, not taken over.

Flag issues already covered by a merged or open PR (`gh pr list -R ... --state all --search "<number>"`, then read
the body), issues assigned to someone else, probable duplicates and non-bugs.

**Output format is mandatory: always one Markdown table, never a bullet list per batch**, even for few issues or a
single batch. Columns, in this order: `Batch | Issues | Why it matters | Proof`. One row per batch (one per class
or spec for audit reports); issue numbers comma-separated, with a short tag when useful (`901 and 1467 Vault`);
the last column says which harness proves the batch (`gameplay-test`, `gameplay-test + Ghost`, `client lab`) plus
a few words. The table is conversation output: write it in the language you are speaking, keeping issue numbers
and tool names as they are. Before the table, one line with the open issue count. After the table, only short
grouped notes: issues a merged PR already covers, non-bugs and obsolete reports, probable duplicates (say they are
title-based and not verified), then the slot status, then ask which batch to take.

If `$ARGUMENTS` is empty, stop here and let the user pick a batch.

## Step 2 — work the chosen batch

Rules, in order of priority:

0. **Preflight before any conclusion.** `coa-slot preflight N` before reproducing an issue, and again after every
   fetch, rebase, rebuild, restart, SQL import, client patch or DBC install. A FAIL means no test result is
   trustworthy: fix it or report it to the user before going further.
1. **Reproduce before fixing.** Time-box each issue: the reported scenario plus one or two variants, then stop and
   write it down. No reproduction, no fix. Means, in this order:
   1. **`coa-gameplay-test` scenario — the default proof.** It runs a disposable worldserver with copied
      databases and asserts the server's own calculations (`spell_damage_done`, `spell_effect_value`,
      `spell_modifier`, `spell_cast_time_ms`, `spell_power_cost`, auras, cooldowns, talents, pets, loot, quests
      through `prepare_quest`/`reward_quest`). The scenario is committed in `apps/coa-gameplay-test/scenarios/`,
      fails before the fix and passes after it. Use the `coa-gameplay-test` skill for scenario design.
   2. **Ghost e2e test** for what the harness lists as outside its coverage: actual client packets,
      authentication and network session discovery, movement, reconnect and restart. In practice: experience (it
      has no XP metric), RDF/LFG, duels, area triggers, war mode, chat-visible state, real relogs, quest-giver
      interaction and quest-only loot.
   3. Module or unit tests (`modules/mod-ascension-compat/tests/`).
   4. Source and data analysis with exact manual steps, written in the PR as not automated.

   Choosing between the three, by what each one can actually prove:

   | Tool | Proves | Cannot see | Cost |
   |---|---|---|---|
   | `coa-gameplay-test` scenario | the server's own numbers: damage and healing done, effect values, modifiers, cast time, power cost, auras, cooldowns, talents, pets, loot, quest steps | anything that needs a real session: packets, movement, relogs, and everything the client displays | a disposable worldserver with copied databases; the scenario is committed and replayable |
   | Ghost e2e test | what a real session receives: packets and opcodes, authentication, movement, experience, RDF/LFG, duels, area triggers, war mode, chat-visible state, relogs, quest-giver interaction, several actors at once | rendering: tooltip text, icons, models, and how the interface classifies an aura | a claimed slot; a test run is seconds, the code is committed |
   | `coa-client-check` | only what is displayed: tooltip text and values, whether an aura shows as buff or debuff and on which unit, icons and models by screenshot, UI errors | action bars, 3D model correctness, Lua errors, anything needing many characters | a claimed slot plus the lab client: about 90 s to log in and 15 s per probe, one character at a time |

   A symptom that exists on both sides is proved on both: the server harness for the value, the client check for
   what the player sees. When the two disagree, that difference is the finding.

   Client-only symptoms (tooltip text or values, an aura shown on the wrong unit, icons, models, broken UI) are
   not provable by either harness: run the `coa-client-check` skill
   ([`skills/coa-client-check`](../skills/coa-client-check)), which drives the lab client and returns
   reproduced / not reproduced / inconclusive with its evidence. Write its expectation before touching the
   client, and treat any technical failure as inconclusive, never as "not reproduced".
2. **Check an audit report before treating it as a bug.** Those issues were filed by searching the source for the
   spell ID, so a passive working through native spell modifiers or stat auras is reported as missing. Trace the
   spell to the value the server actually uses, then classify:
   - **real bug**: fix it, with a scenario failing before and passing after;
   - **already works natively**: no code change, but commit a regression scenario proving the tooltip contract, so
     the issue can be closed with evidence;
   - **not obtainable**: no `CharacterAdvancement.dbc` row, no trainer, create-info, module or SQL grant. Change
     nothing and say so in the PR with the evidence.

   Contract: `.agents/docs/systems/ascension-spell-parity.md`. Shape of such a PR: #2521. When a tooltip promises
   more than the client data delivers, implement the tooltip part and record it in `docs/<class>-completion.md`.
3. **Fix only what the issue reports.** Do not extend a fix to similar spells or classes found along the way;
   record those findings in `.agents/plans/<batch>/observations.md` (gitignored) and list them in the PR as
   examined but not fixed.
4. Anything needing interpretation of missing server logic, or contradicting an explicit maintainer decision in
   the code, is a question for the user, not a change. Check first that the decision really covers this case.
5. **Never invent a value** (damage, amount, rate, ID). Read it from the DBC, the DB or the code, or say it is
   unknown. Community references — what a class, spec, talent or ability is meant to do, and data the server
   lacks:
   - https://bindmysoul.com/ (e.g. `?realm=voljin&class=primalist&spec=wildwalker&pane=talents`): its dataset
     `https://bindmysoul.com/conquest/talents.normalized.json` holds every CoA talent node (21 classes, 70 specs,
     3612 nodes) with `spellId`, full tooltip text with numbers, tree kind, required level, point costs and
     dependencies. Snapshot of the CoA Build Hub calculator (`metadata.fetchedAt` 2026-07-22). Its spec/tab IDs
     differ from the server's `.localspec` IDs (Houndmaster is 40 there, 11 here): match on `spellId`.
   - https://ascensionsidekick.com/ with `https://ascensionsidekick.com/data.js` (`window.ASC.coaKits[class]
     .specs[].abilities[]`: name, level, talent flag, description without numbers or IDs; `coaGuide`/`coaSkill`).
   - For data the server lacks (creature templates, spawns, loot, spells, client caches), check
     https://github.com/hertigservices/ascension-data before calling a value unknown:
     `supplemental/exiles-db-export/` is a 2026-09-13 PostgreSQL/CSV export of the db.exil.es CoA database
     (spells, creatures, spawns, loot; see its `SCHEMA_REFERENCE.md`), `datasets/cache.json` restores captured WDB
     caches, `supplemental/coa-databank/` holds coabuildhub talent scrapes.
     https://ascension-db.ascension-archive.workers.dev/ searches all of it by name or ID and shows the captured
     record with its source, mode and date. https://github.com/hertigservices/Ascension_preservation documents the
     client protocol (`reference/ascension_custom_opcodes.json`, `docs/WIRE-SPEC.md`).
   All of these are community snapshots, not the live server: use them to find the right spell, support an
   interpretation or ask a question. When the installed DBC, DB and code have the value, they win, and a snapshot
   that differs is a finding to report. When they lack it, a value taken from a snapshot row must name its source
   and snapshot date in the commit and PR, and the choice goes to the user first.
6. **One commit per issue**, including issues that only add a regression scenario. Conventional Commits,
   `fix(CoA/<Scope>): <imperative summary>`, no issue number in the subject (the squash merge appends the PR
   number), `Fixes #N` in the body, English. Never add session links or AI attribution trailers.
7. **Branches**: `fix/coa-<batch>` off freshly fetched `origin/main` (never a local `main`) in the server repo;
   `test/coa-<batch>` off the Ghost repository's freshly fetched primary branch. `per-issue`:
   `fix/issue-<number>-<short-name>`.
8. **Verify**: `coa-slot deploy N <branch>`, `coa-slot preflight N`, the batch's scenarios and any Ghost tests plus
   earlier ones, `python3 apps/codestyle/codestyle-cpp.py --files <changed>`, module tests under
   `modules/mod-ascension-compat/tests/`, `git diff --check`. An issue that cannot be reproduced or fails
   verification leaves the branch and is reported; it never holds back the rest of the batch.
9. **Publish only when the user says so**: push to your remote, open the server PR against the upstream CoA
   repository (follows
   `.github/pull_request_template.md`; per issue the commit, its scenario and the outcome — fixed, already works,
   not obtainable — one `Fixes #N` line per resolved issue, what was examined but not fixed, the checks actually
   run and on which platform) and the matching PR in the Ghost repository, then post the issue comments.
10. **Issue comments are 1 to 3 short lines**: status first ("Fix in #PR: …", "Confirmed: …", "Can't reproduce on
    current main: …"), then the cause or the one caveat, then at most one question. Details belong in the PR. No
    comment when there is nothing useful to say.
11. **Closure**: `Fixes #N` closes the issue when the PR merges. Afterwards verify the fix is on `origin/main`; if
    the issue is still open, comment `Fixed` and close it when your permissions allow, otherwise leave the
    comment only. Never label duplicates or invalid reports fixed, never reopen someone else's closure.
