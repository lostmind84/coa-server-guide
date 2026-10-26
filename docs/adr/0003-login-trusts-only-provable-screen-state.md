# 0003. `login` trusts only a provable screen state before typing credentials

- Status: accepted
- Date: 2026-10-26

## Context

Two earlier sessions (batch 19, batch 20) reported `coa-client-lab login` as a blocker: logging a second
character into an already-running lab client (switching accounts without a `stop`/`start`) sent account and
password text into the wrong place 6/6 times — world chat, or a garbled account field — because the command
assumed the client was sitting on the account-login screen and started typing. Recovery needed a manual
`/camp`, the character-select "Back" button, and retyping.

The previous design used one proxy for "is a login attempt likely to find a dialog to dismiss": whether
`state/account` existed from an earlier `login` call in the same lab session. On a truly fresh client this was
safe (confirmed live: an unconditional dismiss `Return` on an untouched login screen corrupted the account
field, since the client's default-focused control there is not that field). It was never safe for anything
else `login` might currently be showing: world, character-select, or a real leftover dialog all look alike to
a script with no way to read the screen.

## Options considered

1. Keep guessing from `state/account` alone, tuning the blind recovery keystrokes.
2. Read the actual screen with OCR or template matching before every keystroke.
3. Trust only two provable states — a fresh client (nothing has touched the glue screens since `start`), and
   "currently in world" proven by a relay probe ping against the lab descriptor's character (an offline
   character cannot answer it) — and refuse to type anywhere else. From the proven in-world state, drive a
   bounded recovery (`/camp` to character-select, click Back to account-login) and confirm arrival with a
   pixel-brightness sample of the login screen's bright logo/sky area before typing (srgb sum measured live,
   slot 2, 2026-10-26: account-login ~479, character-select ~112; `LOGIN_SCREEN_BRIGHTNESS=300` sits between
   them). Every other state (character-select reached any other way, a leftover dialog, mid-transition)
   refuses outright with a named reason.

## Decision

Option 3, as originally accepted above, with one change (2026-10-26, same day, a follow-up session): the
in-world recovery path (`/camp`, wait, click the character-select Back button, confirm the login screen with
the pixel check) is replaced by a restart of the lab client on the same slot.

The original `/camp` + Back recovery was driven end-to-end inside one `login` process, with waits from 5s up
to 90s per attempt and total elapsed time up to ~330s: it reproducibly did **not** reach the login screen in
4 separate full runs (4/4 failures). The same click, performed as a separate manual step immediately
afterward, succeeded in under 20s every time it was tried (3/3) — so the recovery logic (coordinates, click
form, confirm check) was not the problem, but the cause of the in-process failure was never established (not
verified): click coordinates, click form, hover-state before the click, rapid-repeat-click interference, and
raw elapsed time up to 330s were all ruled out live without explaining it. Rather than keep an unreliable path
whose failure mode is not understood, `login` now uses the one path already proven reliable in this
environment: a fresh client since `start` always reaches the login screen (LOGIN_WAIT, then the pixel check).

`coa-client-lab login` now:

- On a fresh client (`state/account` absent): waits `LOGIN_WAIT`, confirms the login screen via the pixel
  check, types credentials. Dies if the check fails instead of typing blind.
- Otherwise (a lab session that already attempted a login, in any state — in world, character-select, a
  leftover dialog, mid-transition): restarts the lab client on the same slot (read from `state/slot` before
  the restart clears it; instance and profile/resolution come from the environment the whole script run
  already has, so the restart necessarily matches them), then takes the same fresh-client path above. No
  relay probe ping is required for this any more — the previous design's "prove it is in world first" check
  only ever gated an in-place recovery that is no longer attempted.

This makes `login CHARACTER` (or `login ACCOUNT PASSWORD`) reliable the second and every later time in a row,
not just self-recovering when a relay descriptor happened to be available to prove in-world state.

## Consequences

- Typing credentials onto an unknown screen (the batch 19/20 defect) still cannot happen: every path either
  proves the screen first (after a restart if needed) or refuses.
- A second (or later) `login` no longer needs a relay descriptor or a successful probe ping to succeed: it
  restarts unconditionally instead of trying to prove in-world state first. The in-place in-world recovery
  this ADR originally described, and the gap it left open (character-select → account-login transition slower
  than explained), no longer apply — there is no in-place recovery any more.
- Every non-fresh `login` now pays a full restart's cost (`stop` then `start N`, roughly the time `start`
  itself takes) instead of the faster path when in-place recovery happened to work. This trades a cost that
  was always paid (`stop && start N`) only on refusal for one paid on every repeat login, in exchange for not
  depending on an unexplained, unreliable transition.
- `CAMP_WAIT` and `recover_to_login_screen` are removed; `/camp` and the character-select Back button are no
  longer used by `login`.
