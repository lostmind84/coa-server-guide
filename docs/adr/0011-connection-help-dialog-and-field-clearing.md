# 0011. A second disconnect popup, and select-all instead of a fixed `BackSpace` count

- Status: accepted (partial: two proven client-side bugs fixed; a third, pre-existing flake and the original
  trigger are not resolved)
- Date: 2026-10-27
- Extends: ADR 0007 (`.kick` replaces `/camp` for in-world recovery), ADR 0009 (login state machine reads),
  ADR 0010 (instant-logout RBAC, same-account switch)

## Context

Brief L13: master every step of login/logout to switch accounts or restart the client as fast as possible
(user goal, verbatim, unchanged since L6). The controller's read-only facts going in named
`WorldSessionMgr::AddSession_` (`src/server/game/Server/WorldSessionMgr.cpp:320`, AzerothCore fork at
`~/Projects/azerothcore-wotlk-coa`) as a suspected cause: it kicks an existing session of the same account and
refuses the new one outright if the old session is still `PlayerLoading()`. A fast different-account switch
sequence (`--account Coalabshare Sharea` ; `Coalabres` ; `--account Coalabshare Shareb`, zero gap) was known
to fail intermittently at the last step with "disconnected during character selection".

## What was measured, live, slot 2, 2026-10-27

Slot 2's worldserver logging was changed for this task only (`Logger.network.kick=4,Console Server` and
`Logger.network=5,Server` added after `Logger.root`, restored byte-for-byte afterward; `diff` confirmed clean
before the final restart) and the worldserver was restarted twice on slot 2 alone. No other slot, and no
server source, was touched.

Across 27 login/switch attempts this session (a 6-call warm-up loop, three 3-call reps of the exact failing
sequence pre-fix, and further reps post-fix), `Server.log` showed every attempt completing a normal
`WorldSocket::HandleAuthSession: Client 'X' authenticated successfully` followed by exactly one
`Account: N Character: 'Y' ... kicked with reason: Unknown reason` — that exact string traces to
`WorldSession.h:562`'s no-argument `KickPlayer()` overload, reached every time through the SOAP `.kick`
command (`ACSoap: got command 'kick Y'` immediately precedes it). The `AddSession_`/`PlayerLoading`
same-account refusal (`WorldSessionMgr.cpp:328`, the exact string `"kick existing session with same
account"`) never appeared once. That hypothesis is ruled out for this reproduction: the server-side session
registration handled every one of these 27 attempts cleanly.

Two client-side bugs were found and fixed instead, both confirmed live via screenshots of
`state/screen-check.png`:

1. **An unrecognized second popup.** This client's own addon shows a custom "Project Descension - Connection
   Help" dialog on a genuine connection drop (title "Project Descension - Connection Help", body starting
   "Unable to connect? Check the following steps."). It shares `current_screen == "login"` with a clean
   screen, exactly like the standard Blizzard "You have been disconnected from the server" `StaticPopup`
   `click_login_dialog_dismiss` already targets — but it is much larger, and its own Okay button sits at
   about (0.697, 0.792) of the window (measured live, 1024x768: (714, 608)), well outside
   `click_login_dialog_dismiss`'s point (0.5, 0.517), which lands inside this popup's body text and does
   nothing. Reproduced twice independently (05:44 and 06:05): once shown, every later `login` call kept
   failing or silently mistyping credentials under it until it was cleared by a manual click. Fix:
   `clear_login_dialog_unconditionally` now also calls `click_connection_help_dismiss`
   (`xtest_click_pct 697 792`). Same harmlessness precedent as the existing click: confirmed live against a
   dialog-free login screenshot that this point sits in empty background between the Login and Quit buttons.
2. **Fields not actually cleared.** `cmd_login` cleared the Username and Password fields with a fixed run of
   20 `BackSpace` keys. Reproduced live (screen-check.png, `Coalabres -> Labswitch`): the Username field read
   `COALABCOALABRESLABS` — the *previous* account's text (`COALABCOALABRES`, 15 chars) entirely intact, with
   the new account's tail appended, not replacing it. An unrecognized/malformed account is rejected before it
   ever reaches the worldserver: the client reports `login_result_name=LOGIN_DISCONNECTED` (read from its own
   memory) within 6-11s, with zero new lines in `Server.log`'s `network`/`network.kick` loggers at all — not
   even one of `WorldSocket::HandleAuthSession`'s own `LOG_ERROR` failure branches, which `Logger.network=5`
   would have captured. This is decisive: the client never got far enough to reach the worldserver's auth
   step at all. Fix: both fields are now cleared with `ctrl+a` then `Delete` instead of a fixed `BackSpace`
   count, which clears regardless of the field's prior length or the click's exact cursor position.

(Authserver successes are not logged at all in this config — only failed `AuthChallenge` attempts are, at
`LOG_WARN` — so an absence of `Auth.log` growth during a *successful* attempt is expected and was not used as
evidence either way; only the worldserver's `network`/`network.kick` loggers, which log both success and every
failure branch, were used as decisive evidence above.)

## What was tried and still fails (not fixed, not newly introduced)

With both fixes applied, the exact failing sequence from the brief ran clean for three full zero-gap reps (9
switches: dedicated↔dedicated, same-account shared, and mixed, all succeeding) before a later rep failed again
with `LOGIN_DISCONNECTED`, this time with neither the popup nor the garbled-field symptom. This matches
`kick_via_soap`'s own already-documented flake (ADR 0007/0009's own comments in `scripts/coa-client-lab`): a
kick attempt made very soon after the target character's own world entry can get back the SOAP command's own
usage/syntax text instead of a real kick, on no fixed schedule, and the existing retry (`KICK_RETRY_ATTEMPTS`)
does not always cover it under true zero-gap pressure. This is a pre-existing limitation, not something this
task introduced or fully resolved; it was not re-diagnosed further within the task's 2h time budget.

The root trigger of the very first genuine disconnect — the event that puts either popup on screen in the
first place — is not established. `Server.log` and `Auth.log` carry no timestamps in this configuration, so a
specific failing attempt among many textually-identical auth/kick cycles cannot be matched to a specific log
line. Labelled **not verified**; left for whoever continues this (adding a timestamp-capable appender format
would be the natural next step, but was out of scope for a read-only, slot-2-only logging change).

## Decision

1. `click_connection_help_dismiss` (`xtest_click_pct 697 792`), called unconditionally alongside
   `click_login_dialog_dismiss` inside `clear_login_dialog_unconditionally`.
2. `cmd_login`'s credential entry clears both fields with `ctrl+a` then `Delete`, not a fixed `BackSpace`
   count.
3. **Not done**: a server source change. The AddSession_/PlayerLoading race remains an unconfirmed hypothesis
   for a different reproduction than this one; this task's scope was client-lab-only and server-read-only.
4. **Not done**: a fix for the `kick_via_soap` retry-cadence flake under true zero-gap pressure; it is
   pre-existing (ADR 0007/0009) and out of this task's scope and time budget.

## Consequences

- Both fixes are strictly additive clicks/key-sequences, each confirmed harmless on a dialog-free/empty-field
  screen by direct live observation, consistent with the precedent ADR 0007 already established for
  `click_login_dialog_dismiss`.
- Zero-gap different-account switching is measurably more reliable (first-failure point moved from the very
  first different-account step to after 9 clean switches in this session) but not fully reliable: the
  pre-existing `kick_via_soap` flake can still surface under sustained zero-gap load.
- Open items for whoever continues this: the `kick_via_soap` retry-cadence flake under true zero-gap pressure,
  and the root trigger of the first genuine disconnect (needs timestamped server logging to chase further).

## Addendum (2026-10-27): measured state after these fixes

Measured live on slot 2, zero gap, with the default path order:

- With the fields cleared reliably, the `/camp` + Back different-account path that ADR 0010 reverted works:
  6/6 switches with `.kick` forced to fail, 23-26 s each. It now backs up a missed `.kick`.
- One failure remains: switching back to a shared account sometimes gets the new session disconnected while
  the character list is shown (about 1 in 10 mixed switches; no server log line at the default levels). A
  second login from the same client state failed the same way 3/3, so `login` restarts the client and logs in
  once more for that one error (`LOGIN_DISCONNECTED_EXIT`, `COA_LAB_LOGIN_ATTEMPTS`, default 2).
- Result: 15/15 mixed switches reached the right character; 14 took 13-23 s, one took the restart retry
  (73 s). The cause of that disconnect is still open.
- After a fresh `start`, switches failed 2 of 4 with LOGIN_DISCONNECTED in about 10 s: after a `.kick` the
  "disconnected" dialog can appear once the client is already on the login screen, after the blind dismiss
  clicks, and the credentials were typed under it. Memory shows no trace of that dialog, but its red Okay
  button does: at (0.5, 0.514) of the window, srgb(67,1,0) to (230,1,0) with the dialog, srgb(29,27,19)
  without. `login` now waits up to 3 s for that dialog after a kick, clicks Okay while it is visible and
  refuses to type while it stays. A LOGIN_DISCONNECTED answer is retried once in place.
- Measured from a fresh start, zero gap: 8/8, then 16/16 mixed switches (15 at 14-26 s, one restart retry at
  74 s), then 6/6.
