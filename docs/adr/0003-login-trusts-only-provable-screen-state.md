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

Option 3. `coa-client-lab login`:

- On a fresh client (`state/account` absent): waits `LOGIN_WAIT`, confirms the login screen via the pixel
  check, types credentials. Dies if the check fails instead of typing blind.
- Otherwise: requires `state/lab.json` and a successful relay `probe ping`; only then does it recover
  (`/camp`, wait, click the character-select Back button, confirm the login screen the same way) before
  typing. If probe ping does not succeed, it refuses and names the reason, with no keystrokes sent.

This makes `login CHARACTER` the second call in a row (the exact batch 19/20 scenario, once relay-setup and a
first `login ... CHARACTER` are in place) self-recovering, and makes every other ambiguous state a clean,
named refusal instead of a silent corruption.

### Known gap

The character-select → account-login transition itself was measured to take much longer in this environment
than its on-screen content suggests (character-select renders in a screenshot well before the transition
becomes clickable; recovery needed roughly two minutes of total elapsed time across repeated attempts in one
run, live, slot 2, 2026-10-26, for reasons this guide's tooling does not explain — not a click-mechanism or a
hover-state issue, both ruled out live). `CAMP_WAIT` and the retry loop in `recover_to_login_screen` are set
with a wide, evidenced-but-unexplained margin rather than a measured minimum.

## Consequences

- Typing credentials onto an unknown screen (the batch 19/20 defect) cannot happen any more: every path either
  proves the screen first or refuses.
- A second `login` with no CHARACTER argument (no relay descriptor to prove anything by) now always refuses in
  a lab session that already attempted a login, where it previously guessed. `coa-client-lab stop && start N`
  gets back to the one state this command trusts unconditionally.
- Recovery is slower than the old blind dismiss (CAMP_WAIT plus a multi-attempt retry loop) and its margin is
  empirical, not derived from a known cause; a future session with headroom to investigate the transition delay
  itself could likely tighten it.
