# 0016. Agents clean up their worktree and test data after publishing

- Status: accepted
- Date: 2026-10-27

## Context

On 2026-10-27 the in-RAM test MySQL `coa-test-mysql` (tmpfs, 12 GB) was full: every worktree that runs gameplay
scenarios keeps its own `coa_test_<id>_world` cache (about 1.3 GB), and nothing removed one when its worktree was
done. A batch agent stopped because dropping another session's cache needed the user's consent. The same day, 14
worktrees of merged PRs (about 40 GB on disk) were still present.

Dropping only the schema is not enough: the cache's `world.json` stays in the worktree, and the next run fails the
owner-token check (`apps/coa-gameplay-test/world_cache.py`, `verify_owner`).

## Options

1. Enlarge the tmpfs. It delays the problem and needs a container re-create and reseed.
2. Evict caches by age from a shared job. That needs a policy for caches that are still in use.
3. Each agent removes its own worktree and caches once its work is pushed, with a script that refuses anything
   unpublished or in use.

## Decision

Option 3, at the user's request ("supprimer leurs data (worktree et base sql, etc.) quand ils ont push leur PR",
permanent for later agents). `scripts/coa-worktree-cleanup` does it: dry run by default, and `--yes` to remove.
It refuses a worktree with uncommitted or untracked work (`.cache/`, `build/` and `env/` excepted), an unpushed
HEAD that is not the head of a merged PR, a process running inside it, or a cache that is leased, not
ready/invalid, has a different owner token, or has open connections. Only then does it drop each cache schema
with its `world.json`, run `git worktree remove` (never forced), and delete the branch (`-D` only after a
verified merged PR, because a squash merge leaves the branch unmerged for git).

## Consequences

- The test MySQL and the disk only hold what live work uses, and an agent no longer stops to ask about it.
- A review follow-up recreates the worktree from the pushed branch. Its first build is a full one (ccache helps),
  and its first scenario copies the world again (a few minutes).
- Ignored files in a removed worktree, such as `.agents/plans/`, go with it. Anything worth keeping belongs in
  the PR or the issue before cleanup. Shared inputs that used to live in a worktree, such as the RAM MySQL
  config files, were moved to `~/CoaServer/test-mysql/secrets/`.
