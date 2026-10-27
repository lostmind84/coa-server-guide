# 0015. `restart_client` reuses the profile/display/resolution recorded by `start`

- Status: accepted
- Date: 2026-10-27
- Extends: ADR 0003 (restart as the clean-login-screen recovery), ADR 0004 (restart as the fallback used by
  every non-login starting state)

## Context

Class mechanics batch 23 (slot 4, 2026-10-26, report
`~/Projects/azerothcore-wotlk-coa-cm23/.agents/plans/cm23/client.md`) hit `coa-client-lab login` with an
account switch auto-restarting the client non-headless and hanging with "no window after 120s". The session
had been started with `COA_LAB_PROFILE=minimal` (headless, 1024x768); the later `login` call carried none of
`COA_LAB_PROFILE`/`COA_LAB_DISPLAY`/`COA_LAB_WIDTH`/`COA_LAB_HEIGHT`/`COA_LAB_FPS` in its own environment.

`PROFILE`, `DISPLAY_MODE`, `WIDTH`, `HEIGHT` and `FPS` (`scripts/coa-client-lab`, top of file) are derived
once from `COA_LAB_PROFILE`/`COA_LAB_DISPLAY`/`COA_LAB_WIDTH`/`COA_LAB_HEIGHT` at the start of *each* script
invocation, defaulting to `readable`/`nested`/`1920x1080` when unset. `restart_client` (used by `cmd_login`
whenever memory cannot already confirm the login screen — the normal case for an account switch, since the
same-account in-place switch in `cmd_login` only applies when the requested character's account matches
`state/account`) calls `cmd_stop` then `cmd_start "$slot"`, which re-reads those same process-local globals.
A prior comment on `restart_client` claimed this was safe because the variables are "read once from the
environment at the top of this script" — true only within one invocation, not across the separate `start`
and `login` invocations that make up a real session; `login` here restarted nested/readable (1920x1080) in
place of the minimal/headless (1024x768) client that was actually running, and the readable/nested client
either took much longer to open a window or genuinely hung in the agent session that reported this.

## Decision

`cmd_start` now records the settings it resolves (`PROFILE`, `DISPLAY_MODE`, `WIDTH`, `HEIGHT`, `FPS`) to
`state/profile` (`state/<instance>/profile` for a `COA_LAB_INSTANCE`), right after it takes the lock and
before launching the client. `restart_client` sources that file, when present, before `cmd_stop`/`cmd_start`,
overriding this process's own environment-derived globals (and `MINIMAL_CVARS[0]`, which bakes `$FPS` into a
string at array-definition time and would otherwise keep a stale value). A pre-0015 instance with no
`state/profile` yet falls back to this process's own environment, exactly as before this fix — graceful
degradation, not a hard failure.

`cmd_stop` does not delete `state/profile`: a later `start` always overwrites it, and a restart (the only
other reader) only ever runs on an instance where `start` has already written it in this same
run-to-completion.

## Consequences

- `restart_client` now relaunches with the settings the client was actually running under, regardless of
  which script invocation (and which environment) triggers the restart — the scenario an account-switching
  `login` call exercises every time memory cannot confirm the login screen in place.
- `MINIMAL_CVARS[0]` (`maxFPS`) is corrected alongside the restart for the same reason; no other
  profile-dependent value in this script is computed ahead of `cmd_start`'s own validation, so nothing else
  needed the same treatment.
- Regression: `scripts/tests/coa-client-lab.test.sh` starts minimal/headless, then forces two `login` calls
  with no profile/display override at all (a different account, so the same-account fast path cannot apply
  either); the second, restart-driven login is asserted to relaunch headless, not the caller's own
  readable/nested default.
