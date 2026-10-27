# 0008. Shared lab accounts get the same generated/reused password as dedicated ones

- Status: accepted
- Date: 2026-10-27
- Extends: ADR 0007's open item ("The shared-account defect ... was investigated but not fixed by this
  task", flagged for the next session)

## Context

ADR 0007 diagnosed, but did not fix, why a shared lab account (`--account NAME`, several characters on one
account for bank/account-bound/char-select testing) could not be reliably logged into by name: `character
--account NAME ...` left `Password` empty in the request to `scripts/lab-character`, so
`e2eharness.EnsureAccount` (`ConquestOfAzerothGhost/e2e/e2eharness/db.go:51-66`) applied
`e2eharness.DefaultPassword` ("test") to the account's real DB password every time, while
`secrets/<account>.password` either did not exist or held an unrelated generated value for a same-named
account from earlier testing. `login` had no way to read back a password that was actually valid for the
account, so the shared-account switch this task's brief asked for could not be tested at all.

The user's goal (verbatim, from the controlling brief): master every step of login/logout well enough to
switch accounts or restart the client as fast as possible.

## Decision

`cmd_character` (`scripts/coa-client-lab`) now calls `ensure_lab_password "$account"` unconditionally, after
deriving the dedicated account name when `--account` was not given. A shared account's password is generated
once with `openssl rand -hex 16` and kept at `secrets/<account lower>.password` (mode 600), exactly like a
dedicated account's, and is sent as `Spec.Password` on every `character --account NAME ...` call. Because
`EnsureAccount` always rewrites `salt`/`verifier` for an account that already exists (not just on creation),
every `character --account NAME ...` call re-synchronizes the account's real DB password to the secret, even
if the account previously had a different password (`"test"`, or an earlier unrelated generated value for a
same-named account). `dedicated` is still `false` for this path (TestLabCharacterApply's single-character
refusal does not apply), and the "account holds 2+ characters" warning is unchanged.

A new `login --account NAME CHARACTER` form reads that secret back the same way `login CHARACTER` already
does for a dedicated account, so no password is ever typed on a command line or read by a human for either
kind of account. `login ACCOUNT PASSWORD [CHARACTER]` is unchanged for any caller that already holds the
password another way.

No file under `secrets/` was edited or deleted to make this change: a brand-new account name (`Coalabshare`,
never used before this task) was used for live verification, so `ensure_lab_password` created its secret
file itself, never touching any pre-existing one.

## Measured (live, slot 2, 2026-10-27; `~/Projects/coa-server-guide-labfix`,
`fix/lab-login-relay`; see `.agents/plans/client-lab-memory-diagnostics/reports/l9-shared-accounts.md`)

New shared account `Coalabshare`, two CoA-class characters (`Sharea` class 23, `Shareb` class 24), created
through `character --slot 2 --account Coalabshare --character ... --race 5 --class ...`; `secrets/
coalabshare.password` created (mode 600), 32 hex chars, reused unchanged across both `character` calls and
every `login --account Coalabshare ...` call below.

5 consecutive alternating same-account switches, each confirmed by `coa-client-lab probe state` reading
back the expected `player.name` after the call:

| # | `login --account Coalabshare` target | Elapsed | Confirmed |
|---|---|---|---|
| 1 | Sharea | (first login of the session) | Sharea |
| 2 | Shareb | 14s | Shareb |
| 3 | Sharea | 14s | Sharea |
| 4 | Shareb | 14s | Shareb |
| 5 | Sharea | 13s | Sharea |

Then one switch to a dedicated account and back, both confirmed the same way:

| Switch | Elapsed | Confirmed |
|---|---|---|
| `login Labswitch` (dedicated) | 15s | Labswitch |
| `login --account Coalabshare Sharea` (back to shared) | 12s | Sharea |

Every switch above paced with a short gap between calls (this task's own probe reads, screenshots and
heartbeats) landed in the 12-15s range consistent with ADR 0007's kick-path numbers (13.5-13.8s) -- the
password fix adds no measurable cost of its own.

## A related, not-yet-explained failure under truly back-to-back calls (no gap)

Run with zero gap between six consecutive `login --account Coalabshare` calls (no probe reads, no sleeps
between them, well beyond a human operator's pace, deliberately heavier than the paced run above): the
first three calls succeeded but with rising elapsed times (14.9s, 44.7s, 46.1s -- the second and third
consistent with ADR 0007's `/camp` + `restart_client` fallback cost, not the fast kick path), then the next
three all failed the same way: `could not highlight CHARACTER in the character-select list within its own
length; refusing to enter the world as an unconfirmed character` (`select_character_via_memory`'s own
refusal, `scripts/coa-client-lab`), each still costing 36-68s before failing.

The failure is not the character-select navigation itself: a screenshot taken immediately after
(`state/screen-check.png`) showed a client-native "Project Descension - Connection Help" modal ("Unable to
connect? ... Start the local server ... Use your Descension client shortcut ... Check your account"), not
character-select at all, while `coa-lab-mem glue` read `current_screen: "login"`, `characters: []`
throughout -- consistent with the glue quirk ADR 0007 already documents (a screen value that is stale,
accurate for the account-login screen but blind to a modal layered on top of it) but with a different modal
than ADR 0007's own "disconnected" dialog, so `select_character_via_memory` had no real character list to
navigate and correctly refused rather than guessing.

The cause of the connection loss itself was not established in this task's time budget (not verified): a
plausible but unconfirmed explanation is host-level contention from six back-to-back `restart_client` cycles
(each launching a fresh gamescope + client process tree) saturating the host faster than the lab client could
reconnect to the local authserver, but no resource measurement (CPU, memory, open sockets) was taken to
support this over another cause. Recovery needed one full `coa-client-lab stop && start 2` plus a single
paced `login --account Coalabshare Sharea` (15s, confirmed) -- normal cost, not a lingering defect in the
account/password path itself. Flagged for the next session rather than chased further here, per the agent
protocol's one-plus-one retry limit: this task's own six-call, zero-gap stress loop is a harsher load than
any described use (a human operator, or this task's earlier 1-2s-gap runs, which never hit it).

## Consequences

- Any shared lab account (new or pre-existing under a name this task's secret generation would reuse) has its
  real DB password permanently kept in sync with `secrets/<account>.password` from the next
  `character --account NAME ...` call onward, so `login --account NAME CHARACTER` always has a valid password
  to read back; this does not retroactively fix an account whose secret file is wrong until `character` is
  run for it again (unaffected: no existing secret was read, written or deleted by this task).
- `login ACCOUNT PASSWORD [CHARACTER]` keeps working unchanged for any caller (human or script) that already
  holds a password another way; nothing in this change requires migrating existing callers.
- True zero-gap back-to-back `login` calls (this task's own six-call stress loop, not a described use case)
  can still reach a state `coa-client-lab` cannot recover in place from the described fallback chain and needs
  a `stop && start`; this is the same class of "pre-existing, already-documented gap" ADR 0007 left open for
  the leftover-dialog case, now observed once more under a different modal and a heavier load. Not re-attempted
  further here.
