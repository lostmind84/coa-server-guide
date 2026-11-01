# Skills, issue workflow and contributing

Part of the contributor tooling of the CoA server guide (see the [README](../../README.md#part-2-contributor-tooling)).

## Skills

[`skills/coa-client-check`](../../skills/coa-client-check) is a Claude Code skill: it documents the workflow for checking
whether a client-visible symptom (tooltip text or values, an aura shown on the wrong unit, a missing icon or model,
a broken UI element) reproduces, by driving the lab client above and CoaProbe, and returns one of three verdicts
(reproduced / not reproduced / inconclusive) with its evidence. Server-side symptoms belong to the Ghost e2e
harness instead. The skill needs `coa-slot` and `coa-client-lab` on `PATH`, so it is not useful without this guide.

To use it locally, symlink it into Claude Code's skill directory:

```bash
ln -s <path to this repository>/skills/coa-client-check ~/.claude/skills/coa-client-check
```

## Issue workflow for agents

[`agents/coa-triage.md`](../../agents/coa-triage.md) is the shared workflow this tooling was built for: list the open CoA
issues grouped into batches, then route a selected batch through quick dispositions, source-only work, shared
proof cohorts, individual runtime/client work, and blocked reports. Independent investigation can run in
parallel; mutations to a shared slot, client lab, database, harness image, or worktree are serialized. It expects
a gameplay scenario as the default proof for each issue, Ghost bots for what that harness does not cover (client
packets, experience, RDF/LFG, duels, real relogs, quest-giver interaction), and the client lab for client-only
symptoms. Claiming and closing issues adapt to the permissions your account actually has.

When an agent has pushed the PR of a worktree, it runs
[`scripts/coa-worktree-cleanup`](../../scripts/coa-worktree-cleanup) `<worktree>` (dry run) and then with `--yes`: the
worktree's world caches leave the in-RAM test MySQL, then the worktree and its local branch go. The script
refuses unpublished, in-use or leased work. When the test MySQL is full mid-batch, `--cache-only` drops only a
worktree's idle world caches and keeps the worktree; the next run copies the world again. See [`agents/git-safety.md`](../../agents/git-safety.md) for the full
cleanup rule and [ADR 0016](../../docs/adr/0016-clean-up-worktrees-after-publishing.md).

Claude Code uses the command file directly or through a symlink:

```bash
ln -s ~/Projects/coa-server-guide/agents/coa-triage.md ~/.claude/commands/coa-triage.md
```

Invoke it as `/coa-triage`. With no argument it prints the batch table and stops; `/coa-triage <batch>` works that
batch.

Codex uses the skill adapter in [`skills/coa-triage`](../../skills/coa-triage). Install it as a user skill so it is
available while Codex is running in the separate server repository:

```bash
mkdir -p ~/.agents/skills
ln -s ~/Projects/coa-server-guide/skills/coa-triage ~/.agents/skills/coa-triage
```

Invoke it with `$coa-triage`; with no batch or issue numbers it prints the table and stops. `$coa-triage crashes`
works that batch. `manual` pauses before each fix; `autonomous` settles by policy what the workflow would otherwise
ask (interpretation, snapshot values, publication) and journals every such decision in
`.agents/plans/<batch>/decisions.md`. The selected batch and all publication and issue-closure rules remain those
in `agents/coa-triage.md` for both platforms.

For an issue-to-PR run that follows the server repository's `coa-fix-issues` rules while scheduling work by
evidence cost, install the personal [`coa-fix-issues-batch`](../../skills/coa-fix-issues-batch) skill:

```bash
ln -s ~/Projects/coa-server-guide/skills/coa-fix-issues-batch ~/.agents/skills/coa-fix-issues-batch
```

Invoke `$coa-fix-issues-batch <issue numbers or filter>`. With no selection it shows the batch table; `all`
explicitly selects the entire open queue. The maintainer-owned skill in the server repository stays unchanged.

In Claude Code, pair `autonomous` mode with `/goal` for an unattended batch. Its timeout settings are specific to
Claude Code and are not required by the Codex skill.

[`agents/git-safety.md`](../../agents/git-safety.md) covers the workspace rules a batch misses most expensively: prove a
scenario fails before the fix exists rather than resetting to re-observe it, give each dispatched implementer its
own worktree, never rewrite committed work, and treat a stale harness image or a probabilistic assertion as a
result that lies.

Its first step, the topical batch table, is deterministic and does not need an agent: `scripts/coa-triage-table.py`
keeps a local copy of the open issues in `~/.cache/coa-triage/issues.json`, asks GitHub only for the issues
updated since its last sync (the API's `since` filter: open ones are upserted, closed ones dropped) and prints the
table. The first run fetches everything, about 20 s; later runs take under a second and say on stderr what changed.
Audit reports are grouped by class; the rest go to crashes, then to their class label (`multi-class` when an issue
carries several), then to a class named in the title, then to a keyword theme; issues that carry an assignee are counted
separately so a batch already taken is visible. This table is a stable topic index, not an execution order or a
cost estimate. After the user selects a batch, the workflow makes a compact issue ledger and orders work by
evidence cost: fast dispositions, source-only fixes, shared runtime proof, individual runtime/client proof, then
unclear or blocked reports. It batches deploy/build/preflight cycles at the shared-proof cohort boundary and
publishes ready work without waiting for unrelated items. The 90% time reduction is a target to measure, not a
claim made by the grouping algorithm.

```bash
python3 scripts/coa-triage-table.py            # sync since last run, print the table
python3 scripts/coa-triage-table.py --refresh  # discard the local copy and refetch everything
```

Class labels come from the maintainers and are reliable; the keyword themes and the title-based class fallback are
not, so read those rows as a starting point, not a classification. The cache keeps each issue's labels; a cache
written before labels were kept is refetched in full on the next run.

## Contributing back

- You need write access or a GitHub fork of `jealous-sound/azerothcore-wotlk-coa` (external contributors open PRs
  from their fork): `git remote add fork https://github.com/<user>/azerothcore-wotlk-coa.git`.
- PR body follows `.github/pull_request_template.md`: *Problem and resulting behavior*, *Validation and remaining
  limits*, *Data/source dependencies* (confirm applied SQL is unchanged, no credentials, profiles or game archives).
- `.github/CONTRIBUTING.md`: focused changes; report source checks, builds and in-game tests separately. GitHub
  Actions only runs repository checks, not a server build; PRs from forks may wait for maintainer approval to run.
- Commit/PR title: `type(Scope/Subscope): short description`, imperative, max 50 characters, as in
  `fix(CoA/Chronomancer): implement Displacement pull-and-cleanse`; the repository's
  `.agents/skills/generate-pr-description` skill describes the PR format. Everything in English. Disclose AI
  assistance. Put `Fixes #N` in the PR body so the issue closes on merge.
- Local checks matching CI: `python apps/codestyle/codestyle-cpp.py --files <path>`,
  `python -B tools/check_repository.py`, `python -B apps/codestyle/tests/test_scoped_lint.py`,
  `python -B modules/mod-ascension-compat/tests/client_compat/run.py`, `git diff --check`.

## Appendix: AzerothCore MCP

[`azerothcore/azerothMCP`](https://github.com/azerothcore/azerothMCP) (Python, SSE on port 8080) gives an AI
assistant access to the databases (creatures, SmartAI, quests, conditions…). Wiki/source search is disabled by
default; it is only useful with a filled database. Quick audit of commit `dc62b920`: nothing malicious found, but a
Python `exec()` sandbox enabled by default, read-only mode enforced by query prefix only, and unpinned
dependencies. If used: `ENABLE_SANDBOX=false`, a `SELECT`-only MySQL user without `acore_auth` access, isolated
container, pinned commit.

## Useful links

CoA project
- Server: <https://github.com/jealous-sound/azerothcore-wotlk-coa>
- Bug report service: <https://github.com/jealous-sound/coa-bug-report>
- Local kit (workspace tooling, portable client components), cited in `.github/CONTRIBUTING.md`:
  <https://github.com/jealous-sound/coa-local-kit> (returned 404 on 2026-09-15: private or removed)
- mod-playerbots: <https://github.com/jealous-sound/mod-playerbots>
- AzerothCore WotLK with playerbots: <https://github.com/jealous-sound/azerothcore-wotlk-playerbot>
- PR #235 (gameplay test harness): <https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/235>
- Client, client patch and repack downloads: shared by the fork author in the project's Discord channel (not linked
  here; game archives must not be redistributed through the repository).

AzerothCore
- Upstream repository: <https://github.com/azerothcore/azerothcore-wotlk>
- Installation overview: <https://www.azerothcore.org/wiki/installation>
- Docker installation: <https://www.azerothcore.org/wiki/install-with-docker>
- Pre-built Docker images (acore-docker): <https://www.azerothcore.org/acore-docker/>
- Linux requirements: <https://www.azerothcore.org/wiki/linux-requirements>
- Linux server setup (configs, client data): <https://www.azerothcore.org/wiki/linux-server-setup>
- Database installation: <https://www.azerothcore.org/wiki/database-installation>
- Keeping the database up to date: <https://www.azerothcore.org/wiki/database-keeping-the-server-up-to-date>
- Networking (realmlist, ports): <https://www.azerothcore.org/wiki/networking>
- Final server steps (accounts, GM): <https://www.azerothcore.org/wiki/final-server-steps>
- Client setup: <https://www.azerothcore.org/wiki/client-setup>
- Common errors: <https://www.azerothcore.org/wiki/common-errors>
- Commit message guidelines: <https://www.azerothcore.org/wiki/commit-message-guidelines>
- AI agentic engineering guidelines: <https://www.azerothcore.org/wiki/agentic-engineering>
- How to test a PR: <https://www.azerothcore.org/wiki/How-to-test-a-PR>
- Stock client data releases: <https://github.com/wowgaming/client-data/releases>
- Discord: <https://discord.com/invite/GyFvXpk7>

Tools
- AzerothCore MCP: <https://github.com/azerothcore/azerothMCP>
- AzerothCore MCP (blinkysc): <https://github.com/blinkysc/azerothMCP>
- MCP via SOAP discussion: <https://github.com/azerothcore/azerothcore-wotlk/discussions/24853>
- Keira3 (database editor): <https://github.com/azerothcore/Keira3>
- umu-launcher (Proton outside Steam): <https://github.com/Open-Wine-Components/umu-launcher>

Ascension on Linux (community)
- Ascension Linux guide (Lutris/Wine, disables `divxtac`): <https://github.com/Elkenniss/ascension-linux-guide>
- Ascension WoW on Arch Linux (GE-Proton, `divxtac` override, `PROTON_DISABLE_XALIA`):
  <https://github.com/Ostekages/Ascension-WoW-on-Arch-Linux>
- Lutris page: <https://lutris.net/games/ascension-wow/>
