---
name: coa-slot-workflow
description: >-
  How to work on a CoA server safely with the guide's tooling: take an isolated coa-slot, deploy a branch, run the
  preflight, run gameplay scenarios and Ghost e2e tests, send client-side symptoms to coa-client-check, check
  whether a spell was ever obtainable, and clean up afterwards. Load before touching a CoA server, running Ghost or
  gameplay tests, or using coa-slot.
---

# CoA slots, harness and cleanup

The workflow for several agents sharing one machine. The commands are documented in the guide
(`docs/tooling/slots-and-preflight.md`, `coa-slot help`); this file is the order to use them in and the traps.
Pitfalls that cost time in past runs: `docs/agent-lessons.md`. Linux only (see "Platform" in `AGENTS.md`): on another
operating system, adapt the setup first and tell the user what you changed.

## Step 0: take a slot before touching a server

Up to four isolated Docker stacks ("slots", 1 to 4) are managed by `coa-slot`. Several agents work at the same time:
each uses exactly one slot and never builds, restarts or queries another slot's server, database or build clone.

1. `coa-slot list`, then `coa-slot claim N "<batch> <note>"` on a free slot. Slot 1 is a development slot like the
   others (ADR 0002) and shares its configuration with the stack of Part 1: do not edit its config. If a claim
   fails pick another; if all slots are held, stop and tell the user. Never delete or overwrite another agent's
   `owner` file.
2. `coa-slot claim-issues N <issue>...` before working issues. An issue held by another slot is skipped and reported.
3. First use of a slot: `coa-slot create N` (add `--own-data` when the batch changes server DBC files, so other slots
   keep reading the shared server data).
4. `coa-slot env N` prints ports, container names, the build clone and the Ghost env file. Every Ghost test loads that
   file: `set -a; . <slots root>/sN/ghost.env; set +a; go test -tags=e2e -p 1 ./e2e/<pkg> -count=1 -v`. Never source
   the Ghost repository's own `.env`: it points at slot 1.
5. Deploy only with `coa-slot deploy N <branch>`: it checks the branch out in the slot's build clone (a worktree cannot
   be a build context; never edit the clone, commit in a worktree first), builds the images, applies SQL updates,
   restarts and waits until ready. SQL applied by one branch stays in the slot database: before deploying a branch
   that lacks it, `coa-slot reset-db N` (slots 2 to 4; on slot 1 ask the user).
6. A deploy takes 2 to 5 minutes: give the tool a timeout of 10 minutes or background it.
7. Batch published or abandoned: `coa-slot stop N` unless the user wants the server up, then `coa-slot release N`.

Parallel builds wait for each other while compiling (a shared ccache mount): expected, never a reason to use another
slot.

## Preflight

`coa-slot preflight N` before reproducing anything, and after every fetch, rebase, rebuild, restart, SQL import, client
patch or DBC install. It checks that the build clone contains `origin/main`, that the worldserver was built from
`HEAD` and is ready, that shipped SQL is applied, which client archives a local patch replaced, that the server DBC
set passes the checkout's `apps/coa-dbc/client_dbc.py check`, and that every DBC the installed client loads is
byte-identical on the server. **A FAIL means no result is trustworthy.** Declare DBC differences of work in progress in
the preflight's expectations file (`--expected`). Changing the shared server DBC directory or the user's client affects
every slot: ask the user first.

## Gameplay scenarios (`coa-gameplay-test`)

The server repository ships a Compose service for Linux (`apps/coa-gameplay-test/docker/compose.yml`). Against a
claimed slot, with `$C` the slot's build clone:

    mkdir -p "$C/.cache/coa-gameplay-tests"
    coa-slot compose N -f "$C/apps/coa-gameplay-test/docker/compose.yml" --profile tests build ac-gameplay-test
    coa-slot compose N -f "$C/apps/coa-gameplay-test/docker/compose.yml" --profile tests \
      run --rm --no-deps ac-gameplay-test run apps/coa-gameplay-test/scenarios/<scenario>.json

**The `build ac-gameplay-test` step is not one-time.** The image bakes its own copy of the worldserver binary and
`coa-slot deploy` does not rebuild it: rebuild after every deploy that changed C++, or scenarios keep running the
previous binary. The preflight reports this as `harness`. A result that does not move after a C++ change is an
image-staleness suspicion first, not a wrong fix. One verification cycle (deploy, image rebuild, preflight) costs 5
to 10 minutes: run it once per batch of changes, never once per file.

For faster verification see `docs/tooling/ram-mysql.md` (an optional in-RAM test MySQL).

## Harness pitfalls

- `.aura` and `.cooldown` apply to the current selection; `ApplyAura` may double-stack (use `.aura` and wait on
  stacks for exact counts).
- A training dummy of a much higher level resists a low-level bot: `.npc set level`. Training dummies are neutral
  (faction 7): code gated on `IsHostileTo` does not run against them, and creature summons treat them as invalid
  targets.
- GM commands leave GM mode on: creatures ignore and cannot assist GMs and GMs get no kill XP; use `.gm off`.
- Casts miss: retry a few times. Cast the rank the character owns; another rank gets no server answer (timeout).
- `SMSG_SPELL_GO` is not sent for some triggered spells, but their damage log is.
- Crash check = world session alive plus the slot's worldserver container `StartedAt` unchanged.
- `go test -p 1`: packages in parallel share the slot's server and fail spuriously.
- `ScenarioOpts.Prefix` plus a 10-character suffix must fit `MAX_ACCOUNT_STR` (17) or auth fails with EOF.
- Level scaling only runs out of combat (stand 30 yd away); `.quest add` refuses item-started quests.
- Items, bank and vanity: the collection tables (`Appearances.dbc`, `ItemAppearances.dbc`, `VanityCollection.dbc`) are
  read from the client DBC set; a green preflight means server and client agree on them.
- The Docker build's compiler occasionally crashes at random (SIGILL or SIGSEGV); a plain retry builds.

## Client-side symptoms

Tooltips, icons, UI and auras shown on the wrong unit are invisible to Ghost. Use the `coa-client-check` skill: it owns
the workflow (expectation, setup, observation, the three verdicts) and drives `coa-client-lab` on a lab copy of the
client; the user's own client is never touched.

## Is this spell obtainable?

An audit line of the form `Class: "Name" (Spell ID: N) - Spell Script / Aura Handler Not Implemented` is often about a
spell no player could reach, where implementing it would add dead code. This fork is a reconstruction, so its own
database cannot settle that. Use `coa-obtainable` (outside captures, calibrated per class before trusting an
absence); setup and how to read it: `docs/tooling/spell-obtainability.md`. Never report a bare absence.

## Clean up once the work is published

When the PR (or the last PR) of a worktree is pushed and nothing is left to do in it: `coa-client-lab stop`, erase your
throwaway characters (`coa-client-lab erase CHARACTER --slot N`), `coa-slot release N`, then
`coa-worktree-cleanup <worktree>` (dry run) and `coa-worktree-cleanup <worktree> --yes`. It drops the worktree's world
caches from the in-RAM test MySQL if you use one, removes the worktree and its local branch, and refuses unpublished,
in-use or leased work: report a refusal, never force it. Also remove any worktree whose PR is merged when you find
one. Rule and rationale: `agents/git-safety.md` and ADR 0016.
