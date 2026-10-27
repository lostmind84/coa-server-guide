# 0013. Relay configuration moves from one shared file to one file per slot

- Status: accepted
- Date: 2026-10-27
- Context: `reports/l14-lab-fixes.md` (ADR 0012's task) found that `~/CoaServer/client-lab/relay.env`, written
  by `coa-client-lab relay-setup N`, is a single file shared by every slot and every lab instance
  (`COA_LAB_INSTANCE`). A `relay-setup` call on one slot overwrites it outright, so a session working slot 2
  silently breaks another session's relay on slot 4 -- exactly what happened during that task (its own
  Concern 1: the agent overwrote `relay.env` once, had to restore it, and then had the harness's own
  auto-mode classifier refuse a second `relay-setup` call as "Modify Shared Resources" once it noticed
  another session held the file for slot 4). That refusal blocked every live proof ADR 0012's two problems
  needed (`probe ca`'s `activeSpec` field, and a live alternating `login --account A C1`/`C2` end-to-end
  check) -- this task (L14b) exists to make per-slot relay configuration possible and then run those proofs.

## Decision

`coa-client-lab relay-setup N` now writes `~/CoaServer/client-lab/relay/slotN.env`, one file per slot,
instead of the single shared `relay.env`. It never writes to, moves or deletes a pre-existing `relay.env`.

Every reader resolves its own slot's file the same way (`relay_env_for_slot` in `scripts/coa-client-lab`,
`resolve_relay_env` in `scripts/coa-lab-relay`): try `relay/slotN.env` first; if that does not exist, fall
back to the shared `relay.env`, read only, but only when its own `SLOT=` line still names this slot. A setup
made before this change, never rerun through `relay-setup`, keeps working through that fallback for as long
as no other slot's `relay-setup` call claims the shared file for itself in the meantime (the exact failure
mode this ADR removes, now scoped to setups that never adopt the per-slot file). Updated readers:

- `grant_instant_logout_rbac` (the RBAC grant made by `character` and by `rbac-grant`): takes an optional
  slot argument for a call site that already knows it (`character --slot N`, before any lab instance has
  even started for that slot), and otherwise falls back to the running instance's own slot
  (`STATE_DIR/slot`, written by `start N`).
- `kick_via_soap` (the in-world-to-login-screen recovery path): same fallback, no call site needs the
  explicit argument today.
- `write_descriptor` (the lab descriptor `login` writes for `coa-lab-relay probe`): resolves the relay file
  from `STATE_DIR/slot` before populating `soap_url`/`soap_account`/`soap_password_file`; its own defensive
  check that the resolved file's `SLOT=` line still matches stays, now naming whichever path was resolved
  instead of hard-coding "relay.env" in the message.
- `coa-lab-relay soap` (used directly by a human, or internally through `coa-client-lab`'s own `$RELAY`
  calls): resolves the same way from `state_dir/slot` -- the same file `coa-client-lab start N` already
  writes for its own slot tracking, so a human running `coa-lab-relay soap` with `COA_LAB_INSTANCE` set
  needs nothing new. `coa-client-lab`'s own internal calls pass `COA_LAB_RELAY_ENV` (an env var, not a new
  CLI flag) to short-circuit this when they already resolved the slot themselves and it may differ from
  `state_dir/slot` (`character --slot N`, again, before any `start`).

No command-line surface changed: `relay-setup N`, `login`, `character`, `rbac-grant` and `coa-lab-relay soap`
all take the same arguments as before. The only behavior difference a user can observe is that `relay-setup`
on one slot no longer disturbs another slot's relay.

### Alternatives considered

- A `--slot` flag threaded onto every reader's CLI was rejected: the brief explicitly ruled out command-line
  changes, and every reader already had a way to know its own slot (an existing `--slot`/`STATE_DIR/slot`),
  so a flag would only have duplicated that.
- Encoding the slot into the shared file's *name* chosen by the caller (e.g. `COA_LAB_RELAY_FILE=...`) was
  rejected in favor of a fixed, predictable `relay/slotN.env` naming scheme: every reader can compute the
  path from the slot number alone, with no extra configuration to keep in sync between callers.

## Live proofs run with this change (slot 2, 2026-10-27)

- `relay-setup 2` with the new code wrote only `relay/slot2.env`; `relay.env` (still holding another
  session's slot-4 configuration) was confirmed byte-identical by `sha256sum` before and after.
- `character --spec 34` on `COALABSHARE`'s `Sharea`, then `login --account COALABSHARE Sharea`, then
  `probe ca`: `"activeSpec": 34` came back over slot 2's own per-slot relay file (ADR 0012, problem 1's
  previously-unrun client-probe proof).
- `login --account COALABSHARE Shareb` / `Sharea` alternated 4 times each (8 switches); `probe ping`'s
  `character` field confirmed the correct one in world every time (ADR 0012, problem 2's previously-unrun
  live end-to-end proof).
- The mismatch check's negative case: calling `wait_ui_ready` directly with a deliberately wrong expected
  name, against a real session correctly in world as `Sharea`, died with "logged in as the wrong character:
  requested WrongCharacterName, the relay reports Sharea is in world" -- proven without provoking an actual
  bad login.
- `coa-lab-relay soap "server info"` run directly (not through `coa-client-lab`), with no `COA_LAB_RELAY_ENV`
  override, resolved slot 2's relay file through `state_dir/slot` alone and reached the server.

## Consequences

- A session on one slot can no longer break another session's relay by running `relay-setup`. Each slot's
  relay configuration now has exactly one writer-reader pair (its own `relay-setup N` call and its own
  readers) instead of all slots sharing one file nobody could safely write to concurrently.
- A pre-existing shared `relay.env` left over from before this change is never deleted by this change and
  keeps working for its own slot through the fallback; it becomes misleading only if some other slot's
  `relay-setup` is run first and changes its `SLOT=` line out from under the slot that was relying on it --
  exactly the scenario this ADR exists to stop happening through `relay-setup` itself, now impossible,
  though a hand-edited `relay.env` could still in principle do it.
- Tests: `scripts/tests/coa-client-lab.test.sh` (relay-setup writes `relay/slotN.env`; `write_descriptor`/
  `login` reject a per-slot file whose own `SLOT=` line disagrees with its filename; a stale unrelated
  `relay.env` is ignored in favor of the per-slot file; `grant_instant_logout_rbac` and `kick_via_soap`
  resolve by slot, including the legacy-fallback and different-slot-is-ignored cases), and
  `scripts/tests/test_coa_lab_relay.py` (`ResolveRelayEnvTest`: per-slot file preferred, legacy fallback
  matched/rejected by `SLOT=`, no slot recorded, `COA_LAB_RELAY_ENV` override). No Go test changes: nothing
  in `scripts/lab-character` reads relay configuration; it is driven entirely through `coa-client-lab`'s own
  shell functions.
