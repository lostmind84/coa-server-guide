# 0019. `coa-verify` follows the server's development build profile

- Status: accepted
- Date: 2026-11-12
- Amends: [0018](0018-verify-inside-a-versioned-container-image.md) (adds mold to the image)

## Context

Since #38 `coa-verify` builds without precompiled headers by default, in `build-nopch`, with its own
`cmake_args`. Precompiled headers made a second worktree reuse only 41 % of the cache.

The server repository found the cause: `-D_CONF_DIR="<checkout>/env/dist/etc"` on every compile command. ccache
hashes the `-D` arguments when it compiles a precompiled header, so each worktree rebuilt its `.gch`. Server PR
#12170 limits that define to `Config.cpp`, makes unit-test coverage opt-in, and gives `verify_all.py` a development
profile for new build directories: `-g1`, a unity build of `game`, thin archives on Linux, and mold when it is on
`PATH`.

`coa-verify`'s own `cmake_args` replace `verify_all.py`'s defaults, so the wrapper must stop passing them for the
profile to apply. Older branches still need the previous behaviour.

## Considered options

1. Keep `build-nopch` with `-DNOPCH=1` for every branch.
2. Detect the profile with an ancestor commit, as for 2a14cd00f5.
3. Detect the profile from the worktree's `tools/verify_all.py` content, and give it its own build directory.

## Decision

Option 3:

- When `tools/verify_all.py` defines `linux_development_arguments`, the default settings are only
  `{"build_directory": "build-dev"}`, and `verify_all.py` configures with its own defaults.
- Otherwise the previous rules apply: `build-nopch`, or `build` on a HEAD older than 2a14cd00f5.
- `--pch` and `--nopch` keep their meaning.
- The image installs `mold`.

Option 2 needs the merged commit's hash. That hash is only known after the server PR merges, and a squash merge
gives it a different one.

## Consequences

- A worktree on a profile branch builds once more from scratch, in `build-dev`; its `build-nopch` can be deleted.
- Measured on 2026-11-12, one run each, `--stages build,unit`, empty ccache:

  | Server commit | Mode | Cold | Second worktree |
  |---|---|---|---|
  | dfc249177c | previous default | 881.7 s | 153.6 s |
  | #12170 (`48350fd6ac`) | development profile | 421.3 s | 47.0 s (97.6 % hits) |

- Detection by file content follows whatever the server branch carries. A server rename of
  `linux_development_arguments` would silently return such branches to `build-nopch`. The marker is a constant
  (`DEV_PROFILE_MARKER`) tested in `scripts/tests/test_coa_verify.py`.
- An image built before this change lacks mold. Builds still pass and link with `ld`.
