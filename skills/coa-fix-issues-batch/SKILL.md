---
name: coa-fix-issues-batch
description: >-
  Use when fixing a selected CoA GitHub issue queue with fast dispositions, parallel investigation, shared proof
  cohorts, and per-issue PR delivery. Keeps the server repository's coa-fix-issues ownership and publication rules.
---

# CoA fix issues in batches

This personal skill changes queue scheduling only. Resolve this `SKILL.md` through its symlink with `readlink -f`;
the guide root is two directories above its containing folder. Read the current CoA checkout's
`.agents/skills/coa-fix-issues/SKILL.md` for mode, assignment, branch, review, commit, push, PR, and closure rules.
Read this guide's `agents/coa-triage.md` and `agents/git-safety.md` for the evidence lanes, slot ownership, and
batch verification cycle. The CoA checkout's `AGENTS.md` and relevant subsystem guides govern source changes.
Editing this skill does not resume or execute an issue queue.

## Select a finite queue

Use the issue numbers or filter the user supplied. With no selection and no explicit `all`, show the table from
`scripts/coa-triage-table.py` and wait for a chosen batch; do not silently start every open issue. If `all` is
explicit, freeze the complete paginated set of open issue numbers and work through successive cohorts. Preserve
the user's specified order and demonstrated dependencies. New issues belong to a later run.

Fetch titles, labels, state, and assignees for the selected set first. Make a provisional issue-to-lane ledger
from that metadata. Do not preassign or deep-read the whole queue. Immediately before working an issue, recheck
its state, assignees, and linked PRs as the project skill requires; claim it before reading its full report,
comments, or source. Confirm or change its lane after the full read.

## Schedule by evidence cost

When the user did not specify an order, use the selected batch's lanes from `agents/coa-triage.md`:

1. Fast dispositions with complete evidence, such as a fix already on `origin/main` or calibrated proof that a
   capability is not obtainable. Apply only closure actions authorized by the project skill and current request.
2. Source-only fixes whose contract and checks do not require gameplay, server, or client proof.
3. Confirmed fixes sharing a root cause or runtime proof surface.
4. Individual gameplay or client checks.
5. Reports blocked by unclear expectations, ownership, or failed preflight.

The initial lane is a scheduling estimate. Reclassify when evidence changes. Group investigation by root cause or
shared evidence source. A test cohort can span several issues; one PR may span them only when a shared root cause
or dependency makes one review and rollback boundary correct. Keep one branch and PR per independent issue.

Parallelize independent read-only investigations and isolated source edits in separate worktrees. The controller
owns GitHub mutations, final review, commits, pushes, and PRs. One worker owns each mutable server slot, client
lab, database, build directory, or harness image. Deploy, rebuild, preflight, and run relevant scenarios together
for a ready cohort. Attribute a result to a PR only when the tested tree contains its changes. Deliver each ready
PR without waiting for unrelated issues.

The project skill's `manual` checkpoint takes precedence: work only the current issue while approval is pending.
In `auto`, continue independent work around blocked issues. Record wall time for triage, source work, build and
runtime proof, review, and external waits; compare batches only when measurement boundaries and proof scope match.
Treat a 90% reduction as a target until measured results establish it.

The project skill retains every other rule, including the requirement to claim before investigation, the
per-issue PR boundary, and closure only after verifying a fix on `origin/main`. This skill overrides only its
default all-open selection, numeric ordering, and issue-sized sequential scheduling.
