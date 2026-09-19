# Workspace and git safety for agents

Applies to any agent working a CoA batch, and to any agent it dispatches. The failure this prevents has happened
more than once: an agent produced several good per-issue commits, then used `git reset` to rebuild a "before the
fix" state, and the branch tip became the only pointer to that work. Nothing was lost either time, but only
because someone was watching.

## Prove the failure before writing the fix

A regression scenario must fail before the fix and pass after it. Obtain that order naturally instead of undoing
work:

1. Write the scenario.
2. Run it. Record the failure output.
3. Write the fix.
4. Run it again. Record the pass.
5. Commit the scenario and the fix together, one commit per issue.

Nothing needs to be reset, reverted or amended. An agent that commits first and then resets to re-observe the
failure has chosen the one sequence that can lose work.

When a "before" state is genuinely needed after committing, revert the data instead of the history. The gameplay
harness copies the databases, so a targeted `DELETE FROM spell_proc WHERE SpellId = N` against the test schema
proves the same point. Otherwise use `git stash` or a throwaway worktree.

## Never rewrite committed work

- No `git reset` in any mode, no `git rebase`, no forced ref move over commits that are not the ones you created
  in this session and still hold entirely in mind.
- No `git clean -fd`, no `git checkout -- .` across the tree, no `git gc --prune=now`, no `git reflog expire`.
- `git commit --amend` only on a commit you made yourself in this session.
- A value changed after its passing run is an untested value: re-run its scenario, then amend only that commit.
- Temporary commits are a smell. If one is unavoidable it never leaves the agent's own worktree, and it is never
  the only copy of anything.

## One worktree per agent

A dispatched implementer works in its own `git worktree` on its own branch, never in the main checkout and never
in another agent's worktree. This bounds a destructive command to one branch, and it is already the convention
here (`~/Projects/wt-coa-*`). State the worktree path and the branch in the dispatch prompt, and forbid every
other path.

Serena's root stays the main checkout and it has no `activate_project` in this setup, so files inside a worktree
are reached through that worktree's absolute paths.

## Recovery is configured, not guaranteed

Set, once per clone:

    git config --local gc.reflogExpire never
    git config --local gc.reflogExpireUnreachable never
    git config --local gc.pruneExpire never

The defaults drop unreachable reflog entries after 30 days and prune after two weeks. With `never`, a lost commit
stays recoverable through `git reflog` indefinitely — but that only helps someone who knows to look. Before any
operation that moves a branch tip over commits worth keeping, create a real ref:

    git branch backup/<batch>-<what> <sha>

Delete it once the branch is verifiably correct, and say in the report if one was left behind.

Only committed content is protected. An untracked file that a reset removes from the tree is gone, so commit early
rather than holding work in the working tree.

## A green run is not a proof on its own

Two ways a scenario result lies, both seen in practice:

- **A stale harness image.** `apps/coa-gameplay-test/docker/compose.yml` builds the test image *from*
  `acore/ac-wotlk-worldserver:$TAG`, so it carries its own copy of the binary, and `coa-slot deploy` does not
  rebuild it. Rebuild it explicitly after any C++ change, then re-run. A scenario result that is *identical*
  after a C++ change should make you suspect the image before the fix. `coa-slot preflight` checks this since
  `12dfcef`.
- **A probabilistic assertion.** A proc with a 20% chance, or one gated on a critical hit without crit rating,
  passes and fails at random. That is a coin flip, not a test. Force the condition (`spell_crit_rating` exists in
  the harness), or drive enough ticks that the residual failure probability is negligible and state it in the
  scenario's `contract`.

And a red `coa-slot preflight` voids every result taken under it, including the ones that looked like clean
failures.
