# 0017. Cache-only cleanup frees the test MySQL during a batch

- Status: accepted
- Date: 2026-10-28

## Context

ADR 0016 frees the in-RAM test MySQL (`coa-test-mysql`, 12 GB tmpfs, about 1.3 GB per world cache) when a
worktree's work is published. On 2026-10-28 it was full again while every worktree holding a cache was still in use or
unpushed, so `coa-worktree-cleanup` refused all of them and a batch agent reported runs failing with
"item_template is full" during the world copy. The agent asked for a way to drop a cache whose
worktree is still needed.

## Options

1. Enlarge the tmpfs. It needs a container re-create and reseed, and fills again later.
2. Drop schemas by hand. Leaving `world.json` behind breaks the next run (`verify_owner`), and nothing checks
   that the cache is idle.
3. A `--cache-only` mode of the same script: the same cache checks, no worktree or git checks, the worktree kept.

## Decision

Option 3. `coa-worktree-cleanup WORKTREE --cache-only [--yes]` still requires a linked worktree of the CoA
checkout, then drops each world cache only if no `lease.json` holds it, its state is `ready` or `invalid`, its
owner token matches and no MySQL connection uses it, and deletes its `world.json`. It does not look at processes,
uncommitted work or the pushed state, and never removes the worktree or the branch.

## Consequences

- An agent can free space mid-batch without asking, first from its own worktrees.
- The next gameplay run of that worktree copies the world again (a few minutes).
- A cache can be dropped between two runs of an agent that is still working; the lease and connection checks
  only protect a run in progress. Agents say so to the owner when they drop another agent's cache.
