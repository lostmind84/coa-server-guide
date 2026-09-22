---
description: List the open CoA issues grouped into work batches, then work a chosen batch end to end
argument-hint: "[batch name, e.g. starcaller | crashes | quests] [manual | autonomous] [per-issue]"
---

# CoA issue triage and fixing

An agent workflow for the CoA issue queue, built around the tooling in this guide. Nothing here is specific to one
contributor: the steps that need repository permissions fall back to what an outside contributor can do.

Work the CoA issue queue: with no argument, print the batch table and stop; with a batch name or issue numbers,
work that queue end to end. `manual` pauses for approval before each fix (default is auto). `autonomous` goes
further: it also settles rules 4, 5 and 9 by policy instead of asking (see "Autonomous mode"). `manual` and
`autonomous` together: `manual` wins. `per-issue` opens one PR per issue instead of one per batch.

Environment: server slots, preflight, the Ghost e2e bots and the client lab are documented in
[Part 2](../README.md#part-2-contributor-tooling) of this guide. If your agent has its own workstation guidance
(paths, slot manager, harness pitfalls), follow that for anything touching a server. Loading that workstation
guidance is not a choice of proof method: it owns the slot, preflight and local invocation of *every* harness,
including `coa-gameplay-test`, whose repository skill documents Windows paths only. The proof method comes from
the batch's `Proof` column and the ladder in rule 1, never from which environment file was read. Repository
conventions: the checkout's `AGENTS.md` and `.agents/docs/`.

Resolve once per run and keep it in the conversation: the repository from `origin`
(`gh repo view --json nameWithOwner`), your login (`gh api user --jq .login`), your permissions
(`gh api repos/<owner>/<repo> --jq .permissions`) and the remote to push to — your fork, or `origin` only when you
have `push` and the maintainers expect branches there. Never push to `main` or `upstream`.

Talk to the user in their language. Everything written to the repository or GitHub — code, commits, branch names,
PR titles and bodies, issue comments — is English.

## Subagents — keep the controller's context small

Delegate by default. The controller's context is the scarce resource of a batch: every raw file read, log, build
output and test transcript it holds stays resident for the rest of the run. Anything that produces bulk output the
controller does not need verbatim goes to a subagent.

Delegate: locating code and tracing a spell to the value the server uses; reading an issue thread, its linked PRs
and their diffs; running a scenario or a Ghost test and reading its output; writing or adapting a scenario;
reviewing the batch diff before publication; checking a community snapshot for a value.

Keep in the controller: the batch table and the `Proof` decision per batch, slot claim and `coa-slot claim-issues`,
preflight verdicts, the classification of each issue (real bug / already works / not obtainable), commits, branch
and PR bodies, issue comments, and every exchange with the user.

Dispatch contract, in the dispatch prompt itself:

- Name the report file: `.agents/plans/<batch>/<issue-or-topic>.md` (gitignored). The full findings, evidence,
  traces and command output go there.
- Cap the returned message: 15 lines for an investigator or implementer (status, file:line conclusions, one-line
  test summary, concerns), 10 lines for a reviewer (verdict, counts by severity, one line per Critical/Important).
- Restate your code-navigation rules verbatim: a subagent inherits the tools, never the reasoning behind them. If
  your agent has symbol-aware navigation and editing (Serena's `find_symbol`, `find_referencing_symbols`,
  `replace_symbol_body`, `rename_symbol`, or an equivalent), require it and say that grep on a symbol name is a
  defect, not a shortcut.
- Name the slot number and forbid touching any other slot, and restate rule 3 (fix only what the issue reports).
- Restate rule 8's batching: deploy, rebuild the harness image and preflight once per batch of changes, never
  per file. Said imprecisely ("redeploy after any change"), a subagent takes it literally and pays a 5-10 min
  cycle per SQL file.
- Say that a `Fixes #N` line belongs only on a commit whose issue was proved, and that a reverted attempt
  leaves no `Fixes` line anywhere — including on the revert. Subagents routinely get this wrong, and the cost
  is closing someone's open issue with a PR that settled nothing.
- List the harness walls already known, so they are not rediscovered at the cost of an hour each.
- Give the subagent the issue text it needs; it starts cold and must not re-derive the batch.

One subagent per independent issue can run in parallel, but only one at a time may use the slot's server: serialise
anything that deploys, restarts, imports SQL or runs a scenario against it.

## Step 1 — always: print the batch table

Run `python3 scripts/coa-triage-table.py` from the coa-server-guide checkout (cached for an hour in
`~/.cache/coa-triage`; `--refresh` to refetch first, about 20 s). It fetches every open issue through `gh api`,
paginated, and prints the batch table deterministically: audit reports ("no script or aura handler") grouped
**by class**, as in PR #2521; everything else grouped by theme (crashes; resources; summons and pets; talents and
specs; items, bank and vanity; quests and world; systems and modes; client UI); issues carrying an assignee
counted apart so an already-claimed batch is visible. Columns are `Batch | Issues | Why it matters | Proof`, the
last column defaulting to `gameplay-test` per the capability table in rule 1. The non-audit grouping is
keyword-based, so read those rows as a starting point, not a verified classification. Print the script's table
verbatim as the conversation output — do not rebuild it by hand or re-run `gh issue list` yourself.

Before working an issue, re-read its state, assignees and the PRs referencing it. Claim it: with `triage` or
`push` permission, `gh issue edit <n> -R <repo> --add-assignee <login>`; without, post one short comment
(`Working on this in <branch>.`). An issue assigned to someone else, or already carrying someone else's PR, is
skipped and reported, not taken over.

After the table, add short grouped notes the script does not produce: issues already covered by a merged or open
PR (`gh pr list -R ... --state all --search "<number>"`, then read the body), probable duplicates (say they are
title-based and not verified) and non-bugs spotted while reading titles, then the slot status, then ask which
batch to take. Keep these notes in the language you are speaking; issue numbers and tool names stay as they are.

If `$ARGUMENTS` is empty, stop here and let the user pick a batch.

## Autonomous mode

`autonomous` exists so a batch can run unattended once the user has picked it in Step 1. Step 1 itself never
changes: with no argument, print the table and stop. Inside a batch, the mode replaces every question to the
user with a recorded decision:

- **Rule 4 (interpretation, maintainer decisions)**: change nothing. Classify the issue as "needs a maintainer
  decision", record it, list it in the PR under examined but not fixed, and move on. Never resolve an
  interpretation by guessing.
- **Rule 5 (values from community snapshots)**: use the value when exactly one calibrated source gives it and
  the installed DBC, DB and code lack it; name the source and snapshot date in the commit and PR as the rule
  already requires. When sources disagree or none is calibrated, treat it as rule 4.
- **Rule 9 (publication)**: push to your remote, open the PRs and post the issue comments without asking, as soon
  as rule 8 is green. Still never merge, never push to `main` or `upstream`, never force-push, never close an
  issue that is not yours.
- **Anything else the user would have been asked** (which variant of a fix, which scenario shape, whether to keep
  a partial result): take the option you would recommend, or the most conservative one when you have no
  recommendation, and record it.

Record every such decision as it is taken in `.agents/plans/<batch>/decisions.md` (gitignored): the question
that would have been asked, the option chosen, the reason, and whether it is reversible. Summarise the file in
the final report and link the relevant entries from the PR body. A decision that is not recorded is a defect of
the run.

Hard stops remain: a red preflight that cannot be fixed, a slot owned by someone else, and anything the harness
guidance marks as "ask the user first". Report them in the final message and end the run; do not wait for an
answer mid-run.

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
   - **not obtainable**: no player can acquire or trigger it. Change nothing and say so in the PR with the
     evidence. This fork is a reconstruction, so its own database cannot establish this: a missing acquisition
     row is exactly what lost server data looks like. Settle it with `~/CoaServer/reference/coa-obtainable`,
     which compares the checkout against captures taken while the servers ran and, before any verdict,
     calibrates each source against the spells that class is already known to acquire. Never report a bare
     absence from an uncalibrated source. The same tool finds the reverse case, spells the live capture offers
     that this fork's `CharacterAdvancement.dbc` lacks, which are real gaps worth their own report.

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

   **Deploy per batch of changes, never per change.** One cycle is `coa-slot deploy N <branch>`, then the
   harness image rebuild (`coa-slot compose N -f "$CLONE/apps/coa-gameplay-test/docker/compose.yml" --profile
   tests build ac-gameplay-test` — `deploy` does not rebuild it, and a stale image silently runs the previous
   binary), then `coa-slot preflight N`. That cycle costs 5 to 10 minutes, so write all the SQL and C++ the
   batch needs, run it **once**, then execute every affected scenario back to back with the 30 s gap between
   runs. Paying it per file turns a 90 s cadence into a 10 min one and can triple a batch's wall-clock time.

   The one case that needs its own cycle is fail-before / pass-after proof: deploy the batch without the
   changes under test, run those scenarios to capture the failures, then deploy with them and re-run. That is
   two cycles for the whole batch, not two per issue.

   **Re-run only what the change can reach.** Before relaunching a suite, read
   `git diff --stat <the commit the suite was measured on>..HEAD` and let the file list decide:

   - nothing the server or the scenarios read (`.md`, `.agents/`, plan files, comments): re-run **nothing**.
     The binary and the scenario JSONs are identical, so the result cannot differ. Name the measured commit
     in the PR and say the later commits are documentation, rather than implying the suite ran on HEAD;
   - one narrow fix or a handful of scenarios: re-run those scenarios, plus any that share the touched
     spell, aura or stat path;
   - a shared core file (`StatSystem.cpp`, `Unit.cpp`, `SpellMgr`, a load-time contract chain), or a merge
     of upstream `main` touching files the batch's scenarios exercise: re-run the whole suite, because a
     stat or spellmod path reaches scenarios that never name it;
   - a merge of upstream `main` touching nothing the batch exercises: re-run nothing. Preflight's `git`
     check still has to go green before publishing, but that needs the merge, not a suite run.

   A full pass of a class batch is one to three hours. Relaunching it on reflex after every merge or
   documentation commit is the single largest avoidable cost of a batch; reading the diff is free. A red
   `coa-slot preflight N` still invalidates every result whatever the diff says (rule 0).
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
