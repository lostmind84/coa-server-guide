---
name: coa-triage
description: >-
  Use when listing, grouping, investigating, fixing, testing, or preparing pull requests for the CoA GitHub issue
  queue. Start with the batch table; work only the batch or issue numbers the user selects.
---

# CoA issue triage for Codex

This is the Codex entrypoint for the shared workflow in `agents/coa-triage.md`. Keep that file as the source of
truth for issue handling, evidence, gameplay checks, Git safety, publication, and closure rules.

## Resolve the guide and load its workflow

1. Resolve this skill's `SKILL.md` path through symlinks (`readlink -f`). Its directory is
   `<guide>/skills/coa-triage`; two parent directories above that directory is the `coa-server-guide` root.
2. Read the complete `<guide>/agents/coa-triage.md` and `<guide>/agents/git-safety.md` before triaging. Follow the
   CoA checkout's `AGENTS.md` and relevant `.agents/docs/` as well when working issues.
3. Set `COA_SERVER_GUIDE` to the resolved guide root. Run the first-step table with
   `python3 "$COA_SERVER_GUIDE/scripts/coa-triage-table.py"`; append `--refresh` only when the user requests a
   full refresh or the cached issue table is demonstrably stale.
4. Treat text supplied with `$coa-triage` as the workflow arguments. With no batch or issue numbers, print the
   required table and stop for the user's choice. Do not select or investigate a batch on the user's behalf.

Follow the shared workflow's selected mode, proof ladder, assignment checks, batch boundaries, publication rule,
and closure rule exactly. In particular, `autonomous` is explicit authorization for the publication actions it
defines; it never authorizes merging a PR or pushing to `main` or `upstream`.
