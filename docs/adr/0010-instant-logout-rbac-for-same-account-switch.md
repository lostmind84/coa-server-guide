# 0010. `RBAC_PERM_INSTANT_LOGOUT` grant, and an in-place same-account character switch

- Status: accepted (partial: the same-account fast path; a different-account use was tried and reverted)
- Date: 2026-10-27
- Extends: ADR 0007 (`.kick` replaces `/camp` for in-world recovery), ADR 0009 (login state machine reads)

## Context

The user's goal (verbatim, unchanged since L6): master every step of login/logout to switch accounts or
restart the client as fast as possible; the ~2 minutes this used to cost per switch under test was the
complaint. L11 (ADR 0009) reached 8/8 reliable dedicated-account switches at a ~2s pace, 15-20s each
(kick_via_soap primary, `/camp` + character-select Back as fallback), but every one of those still goes
through the full account-login screen, even when the next character shares the *same* account already
logged in this session — a full credential retype and realm-connect round trip for no reason other than
that `/camp` itself normally takes up to 20s to log out (`WorldSession::HandleLogoutRequestOpcode`,
`src/server/game/Handlers/MiscHandler.cpp:528-571`, AzerothCore fork at
`~/Projects/azerothcore-wotlk-coa`): `instantLogout` is already true for a resting or in-flight player, or
for any session that `HasPermission(rbac::RBAC_PERM_INSTANT_LOGOUT)` — permission 1,
`src/server/game/Accounts/RBAC.h:52` — otherwise the player is rooted and a 20s timer armed
(`SetLogoutStartTime`).

Grepping every `RBAC_PERM_INSTANT_LOGOUT` and `HasPermission(1` use in the server source found exactly one
effect: that single `instantLogout` check. Granting it to a lab account only widens an existing condition
(this fork did not author it) and does nothing else observable.

## Decision

1. `grant_instant_logout_rbac` (`scripts/coa-client-lab`) grants permission 1 to an account over the lab
   SOAP relay (`.rbac account grant ACCOUNT 1`, `src/server/scripts/Commands/cs_rbac.cpp:85-117`), called
   automatically from `character` for the account it just created or re-applied a password to, and
   available standalone as `rbac-grant --account NAME` for an account created before this change. Both
   refuse (never grant to) an account name that does not start with `COALAB` — this never reaches a real
   player account. Idempotent: AzerothCore's own "already has that permission" answer
   (`acore_string` 72) counts as success exactly like "Granted permission ..." (`acore_string` 74).
2. `goto_charselect_via_memory` logs out to character-select via `/camp`, confirmed by a bounded poll
   (`COA_LAB_INSTANT_LOGOUT_WAIT`, 8s), without ever reaching the login screen. `cmd_login`'s same-account
   character switch (the requested character's account matches `state/account`, the account already
   logged in this session) uses this, then `select_character_via_memory` to pick the new character by
   name — skipping the credential retype, the account-field click and the realm-connect round trip
   entirely. Any failure anywhere in this path falls through to the existing full recovery
   (`goto_login_screen_via_memory`) exactly as if it had not been attempted.
3. **Not done**: using the same instant `/camp` as the *primary* recovery for a different-account world
   switch too (ahead of `kick_via_soap`). Tried and reverted — see "What was tried and did not work" below.

## What was measured, live, slot 2, 2026-10-27

- `.rbac account list ACCOUNT` confirmed permission 1 present in the account's DB row after both the
  automatic grant (via `character`) and the standalone `rbac-grant`, and confirmed idempotent (a second
  grant on an already-granted account still returns success, no duplicate row behavior observed from the
  command's own output).
- Same-account switch (`Coalabshare`'s `Sharea`/`Shareb`): **never failed the overall switch** — 15/15 live
  attempts across this session's runs succeeded, whether the fast path landed or the full fallback ran.
  When the fast path landed, it reached world in 6.3-8.6s, against the ~18-37s a full relogin costs this
  task elsewhere in this session. It did not land reliably: roughly 1 fast switch in every 7-9 attempts;
  the rest timed out waiting for `charselect-loaded` within `COA_LAB_INSTANT_LOGOUT_WAIT` and fell through
  to the slower full recovery (a success, just not a fast one). Raising the bound to 20s did not change
  the ratio (still about 1 fast in 6, the misses simply spent more of that bound before falling back),
  ruling out a plain timeout-too-short explanation. No memory field or source read this session explained
  the inconsistency; not chased further (time budget).
- Dedicated-account switch (`Coalabres`/`Labswitch`, different accounts, `kick_via_soap`-first, unchanged
  from L11): 8/8 at a ~2s pace, 15-20s each, matching L11's own measurement — no regression from this
  session's changes.
- Mixed switch (shared account to a dedicated one, and back): both directions eventually succeeded; one
  direction needed `restart_client` (kick failed its retries, old `/camp` fallback also did not confirm in
  time) — the known, pre-existing final fallback, not a new failure mode.
- Fresh start (stop, start, login): unaffected, 7.2s start + 20.2s login, matching prior sessions.

## What was tried and did not work

Making the instant `/camp` the primary path in `goto_login_screen_via_memory` too (ahead of
`kick_via_soap`), on the theory that a graceful, instant, in-session logout would avoid the server-side
name/connected-flag registration race L11 found for `kick_via_soap` under fast switching. Live, slot 2: the
instant `/camp` did reach character-select quickly and reliably (confirmed even with a generous 25s bound,
ruling out a mere timeout on that leg), but the character-select "Back" click and different-account relogin
that followed it then reliably failed (`login_state` 5, `LOGIN_DISCONNECTED`) on every attempt tried: zero
gap, a 2s pace, and a real-world gap of roughly 15s between calls, alike. A 2s fixed settle sleep inserted
between the charselect-loaded confirmation and the Back click did not fix it either. `kick_via_soap`'s own
path (straight to the login screen, no character-select/Back leg at all) kept succeeding in the same
session immediately afterward, including right after this failure. The exact mechanism was not established
(not verified further, time budget): something about the graceful `/camp` → character-select → Back →
different-account-relogin sequence specifically breaks the next realm connection, not generic timing, since
neither a shorter nor a much longer wait changed the outcome. Reverted: `goto_login_screen_via_memory`'s
world-recovery order is unchanged from L11 (`kick_via_soap` first, the old full-length `/camp` as fallback).

## Consequences

- The same-account switch is the only place this session's new instant-logout permission is used; it is
  strictly additive (a fast path with a proven-safe fallback), never a regression risk for the
  already-working different-account paths.
- The permission is granted to every `COALAB*` lab account going forward, and `rbac-grant` lets an
  operator backfill accounts created before this change; both are refused for any non-`COALAB*` name.
- Two open items for whoever continues this: why the same-account fast path's own `/camp` is only
  instant about 1 attempt in 7-9 despite the permission being confirmed present throughout, and the root
  cause of the different-account `/camp`+Back relogin failure found and reverted above.
