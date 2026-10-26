# 0005. `login` recovers to the account-login screen in place, without restarting the client

- Status: accepted
- Date: 2026-10-26
- Supersedes: the "restart-vs-in-place" part of ADR 0004 (its memory-read decisions otherwise stand)

## Context

ADR 0004 (L5) added `coa-lab-mem glue` and bounded polls, but kept ADR 0003's restart-based recovery for every
non-fresh `login` call: the only in-place recovery tried (`/camp` + `xdotool mousemove --window "$WINDOW" ...
click 1` on the character-select "Back" button, XSendEvent) reliably failed to register when driven from
inside `login`'s own process -- 4/4 in L3/ADR 0003, 2/2 in L5 after a real `glue_field` boolean bug was fixed
-- while the exact same call succeeded every time it was run as a separate, external command against the same
window. The cause was never established across either session.

The user's goal for this session (L6, verbatim, 2026-10-26): "je veux qu'on maitrise chaque étape du login et
de la deconnexion pour pouvoir relancer le client ou changer de compte le plus rapidement possible. [...]" --
master every step of login/logout to restart or switch accounts as fast as possible; memory writes are
authorised for this goal, reads preferred. This session only needed reads: no memory write was used or needed.

## What was tried

1. **Escape key at character-select** (candidate b): sends the key, but `current_screen`/`in_world` never
   change in `coa-lab-mem glue` -- confirmed live, slot 2, 2026-10-26, 5 polls over 5s, before and after.
   Screenshot evidence (see below) shows Escape instead opens the client's own in-game/glue "Game Menu"
   overlay (Options/Video/Sound/Manage Account/Change Realm/Logout/Exit Game/Close) on top of whatever glue
   screen is current -- not a glue transition at all, and not useful for this recovery. Dropped.
2. **The same click, delivered as XTEST fake input instead of XSendEvent** (candidate a): `xdotool
   windowactivate --sync "$WINDOW"` to focus/activate the window, then `xdotool mousemove --sync X Y` and
   `xdotool click 1` with **no** `--window` argument (so xdotool uses XTEST against whatever window the X
   server now has focused, instead of XSendEvent targeted at a window handle) -- same (0.943, 0.967) fraction
   of window size as the existing `click_charselect_back`. This is `click_charselect_back_xtest` in
   `scripts/coa-client-lab`.

**Live validation, slot 2, 2026-10-26, driven from inside `coa-client-lab login`'s own process (the exact
failure mode ADR 0003/0004 hit):**

- First exploratory click (standalone, not yet wired into `login`): `current_screen` moved from `"charselect"`
  to `"login"` within the next poll; a screenshot confirmed the real account-login screen underneath a leftover
  Game Menu overlay (left open by the Escape test above, not caused by this click -- closing it showed the
  clean login screen with the account field pre-filled and password empty).
- Wired into `goto_login_screen_via_memory` (in-world: `/camp` first, confirmed by a bounded poll for
  character-select, `CAMP_WAIT`, 15s cap; then the XTEST click, confirmed by a bounded poll for the login
  screen, `CHARSELECT_BACK_WAIT`, 10s cap) and driven end-to-end through `coa-client-lab login CHARACTER`, in
  process: **4/4 live switches reached the login screen and completed into the world with no restart**
  (confirmed throughout by the lab's own `gamescope` PID staying the same across every switch, and by no
  `restart_client` "restarting the lab client" message in any run's output):

  | Run | Transition | Duration | Restart? |
  |---|---|---|---|
  | 1 | Coalabres[world] -> Labswitch | 46.0s | no (same gamescope PID) |
  | 2 | Labswitch[world] -> Coalabres | ~35s (instrumented run; outer wall time polluted, see report) | no |
  | 3 | Coalabres[world] -> Labswitch | 44.7s | no |
  | 4 | Labswitch[world] -> Coalabres | 44.8s | no |
  | 5 (cross-account) | Coalabres[world] -> COALABMEMDEDI/Memdedi | 43.4s | no |
  | 6 (same-account, nav by name) | Memdedi[world] -> Memtwo (1 Down press) | 45.8s | no |

  A 1s-resolution `coa-lab-mem glue` poll instrumenting run 2 (full log in the session report) measured each
  sub-phase: in-world -> `/camp` confirms character-select, 2.6s; character list loaded, 7.6s; XTEST click ->
  login screen confirmed, 10.1s (i.e. ~2.5s after the list, ~7.5s after `/camp`); credentials typed -> new
  character-select loaded, 25.2s (the dominant phase, ~15.1s after the login screen was confirmed); ->
  in-world, 30.3s. Both new bounded waits (`CAMP_WAIT` 15s, `CHARSELECT_BACK_WAIT` 10s) have margin: measured
  2.6s and 2.5s respectively against those caps.

## Why this is not a clear wall-clock win over ADR 0004's restart path, and is shipped anyway

ADR 0004's restart-based switch measured 42.9-49.6s live. This session's in-place switches measured 43.4-46.0s
(one run's total was not independently clean, see table) -- **within the same band, not reliably faster**, even
though the in-place path's own phase breakdown (run 2 above) shows it reaching the login screen in ~10s where a
restart needs `stop` (measured 1.9s standalone) + `start` (measured 7.3s standalone, window up) + boot-to-login
(~4.6s, measured from a separate fresh-start poll) = ~13.8s before the identical credential+realm-connect phase
(which dominates both paths at ~15-26s and is not attacked by either). The theoretical ~13.8s saving did not
show up cleanly in the wall-clock table above; the most likely explanation is session-to-session variance in
the credential+realm-connect phase itself (compare 25.7s in ADR 0004's fresh-boot measurement vs. 15.1s in this
session's run 2) swamping a smaller, real saving -- **not verified**, no run count large enough this session to
separate the two.

Shipped despite the inconclusive wall-clock win because:
- It answers ADR 0003/0004's own open question (the in-process click's unreliability) with a working,
  4/4-live-proven alternative, removing a `restart_client` dependency for the common case.
- It avoids the restart's own risks that this ADR did not have to pay this session: a lingering client process
  blocking the next `start`, the preflight-carry-across-restart special case in `restart_client`, and the
  window/display re-discovery `cmd_start` does on every boot.
- `restart_client` is kept, unconditionally, as the fallback whenever `goto_login_screen_via_memory` returns 1
  (character-select click or `/camp` not confirmed within its bound, or memory unusable) -- this session's
  live runs never needed it, but the safety net ADR 0003 built is unchanged.

## What this does not attack

- The credential-typing + realm-connect phase (~15-26s, the single largest phase in every run this session)
  is server/network-bound, not a client-side click or sleep; no candidate in this session's scope attacked it.
- `stop`'s hard-kill vs. graceful-shutdown question (task list item) was not pursued: the graceful `cmd_stop`
  measured 1.9s standalone this session, already small next to the ~44s total, so it was not the largest
  remaining phase per the brief's own "attack the largest phases" priority.
- A server-side `.kick` over the lab SOAP relay (candidate c) was not tried: the XTEST click (candidate a)
  already proved reliable 4/4 in-process, so the brief's own ladder ("(d) only if (a)-(c) all fail") was never
  reached for (c), and no memory write (candidate d) was needed either.
- `GLUE_POLL_INTERVAL` (2s) was left unchanged: a smaller value would shave at most ~1-2s off the now-small
  `CAMP_WAIT`/`CHARSELECT_BACK_WAIT` phases, not the dominant credential/realm-connect phase.

## Consequences

- `login`'s core safety property is unchanged: credentials are still only typed once both memory and the pixel
  check confirm the clean login screen; the in-place recovery adds a new confirmed intermediate step (the
  character-select click) but never types onto an unconfirmed screen.
- `click_charselect_back` (the XSendEvent form) is kept, unused, as documented, working evidence of what does
  *not* reliably register in-process; `click_charselect_back_xtest` (XTEST) is the one `login` now uses.
- A future session that wants a further, reliably faster switch has one proven lever left unexplored: the
  credential+realm-connect phase itself (15-26s, the true remaining bottleneck) -- out of this session's scope
  since it is not a client-local click or sleep.
