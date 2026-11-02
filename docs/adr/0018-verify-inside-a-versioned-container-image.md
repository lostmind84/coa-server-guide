# 0018. Run `verify_all.py` inside a versioned container image, not native host deps

- Status: accepted
- Date: 2026-11-02

## Context

The server repository's `tools/verify_all.py` needs a C++20 toolchain, CMake, Ninja, Boost, MySQL client
libraries and OpenSSL to configure, build and test the worldserver. On at least one workstation these are not
installable natively: CMake reports `Could NOT find Boost` against that distribution's packages. Agents worked
around this by building one Docker image (`coa-verify-env:24.04`) by hand on that workstation and running
`verify_all.py` inside it with a new, hand-written `docker run` wrapper per task (for example
`.agents/plans/qb4/verify.sh` in the server repository): same package list copied by eye each time, no
Dockerfile committed anywhere, so the image could not be rebuilt, audited or reproduced on another machine, and
every wrapper risked drifting (mount paths, env vars, uid handling) from the last one that worked.

`docker history --no-trunc coa-verify-env:24.04` recovers the exact steps that produced the image in use: a
`ubuntu:24.04` base, `DEBIAN_FRONTEND=noninteractive`/`TZ=Etc/UTC`, one `apt-get install` of a fixed package
list, and a `python3` to `python` symlink.

## Options

1. **Fix the native host deps** on every workstation that runs verification (distribution packages, a PPA, or
   building Boost from source). Reopens the original problem on each new machine and each distribution version,
   and does nothing for the next host that lacks packaged Boost.
2. **Keep the hand-built image and ad hoc wrappers**, just write down the steps somewhere. Does not fix the
   actual problem: the image stays a snapshot on one disk, nothing enforces that a rebuild matches it, and each
   task still hand-edits a wrapper.
3. **Commit a Dockerfile reproducing the recovered image, plus one versioned wrapper script**, in this guide,
   alongside the already-documented in-RAM test MySQL route (`docs/tooling/ram-mysql.md`) that this setup
   composes with for the gameplay stage.

## Decision

Option 3. `docker/coa-verify-env/Dockerfile` reproduces the image in use, package for package and in the same
order, so a rebuild is a `docker build` away on any machine with Docker, and a future change to the package list
is a reviewable diff instead of a silent drift between workstations. `scripts/coa-verify` replaces the per-task
wrapper: it derives the worktree's main checkout, mounts what the image needs, refuses with the exact build
command when the image is missing, and adds an opt-in `--ram` mode for the in-RAM test MySQL route instead of
copying secrets into the worktree. See `docs/tooling/verify-container.md` for the setup steps and what the
wrapper does in detail.

The image is a toolchain layer only (no repository source baked in): the same image serves every worktree of the
server repository, mounted at build time, which keeps it reusable instead of per-branch.

## Consequences

- Verification is reproducible on a second PC: build the image from the committed Dockerfile, point `coa-verify`
  at a worktree, and the remaining setup is the already-documented server data, module configs and (optionally)
  in-RAM MySQL.
- A package list change to the image is now a diff to review (and, if it matters to a result, a reason to
  rebuild and note the new image in a report), not an invisible edit to one workstation's Docker state.
- This still does not fix native verification on a host without packaged Boost; it only removes the need to.
  Native verification remains possible and preferred wherever it already works, per the server repository's
  `AGENTS.md`.
- The image and wrapper were written for and tested on Linux with Docker; see "Limits" in
  `docs/tooling/verify-container.md`.
