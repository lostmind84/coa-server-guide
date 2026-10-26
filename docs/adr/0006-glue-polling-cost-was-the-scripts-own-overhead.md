# 0006. The glue-wait overhead was the script's own polling, not the client or server

- Status: accepted
- Date: 2026-10-26
- Corrects: ADR 0005's "credential+realm-connect phase (~15-26s) is server/network-bound" -- that attribution
  was wrong; see Context.

## Context

The controller's own traces (PS4, `bash -x`, fresh client and an in-world switch) showed the client and
server are fast: login-screen -> character-select ~3s, Enter -> in-world ~2-4s, `/camp`/Back a few seconds
each. The 15-26s and 42.9-49.6s totals ADR 0004/0005 measured were the script's own cost:

- `coa-lab-mem glue` cost ~1.5s per call (measured, `time`: real 1.49s, user 1.04s). The cause: resolving the
  object manager scans every rw-anonymous memory region page by page (`find_teb64_candidates`) to locate the
  game thread's TEB, ~300k `process_vm_readv` calls. `login`'s polling loop called `glue` once per
  `GLUE_POLL_INTERVAL` (2s) tick, plus extra `python3 -c` spawns per field (`glue_field`, and two more inside
  `select_character_via_memory`), on every wait of every step.
- Six post-login `cmd_chat "/console Sound_... 0"` calls, each a full chat-box open/type/Return/sleep round
  trip, added ~12s after every login, muting a client that was already loaded with sound on.

## Decision

1. **Cache the TEB/TLS resolution** (`coa-lab-mem`'s `resolve_object_manager`): once a (teb64, tls_array) pair
   is found whose tls_index slot is the game thread's, it never moves for the life of the process. Persist it
   in `teb-cache.json` under the lab's state dir, keyed by (pid, `/proc/<pid>/stat` field 22 start time) so a
   restarted client (new pid, or a reused pid after a crash) never reuses a stale address. A null `mgr` read
   through the cache is treated as a legitimate "not in world right now" answer, never as cache invalidation,
   and is never itself cached as a failure.
2. **Skip the object-manager resolution entirely when the glue state does not need it.** `current_screen` alone
   (no TLS/TEB work at all) is a reliable signal for `login`/`charselect`/`charselect-loaded`:
   `CGlueMgr::SetScreen` runs on the transition *into* charselect (unlike the stale-on-entering-world case
   ADR 0004 already documented), so only `in-world` needs the object manager.
3. **`coa-lab-mem glue --until {login,charselect,charselect-loaded,in-world} --timeout S`**: runs the guards
   once, then polls *inside one Python process* at 0.1s, instead of `coa-client-lab` spawning a fresh `glue`
   (plus `glue_field` spawns) on every tick. A single in-process `scan_cache` dict is shared across every tick
   of one `--until in-world` wait, so a cold persistent cache (the very first world-entry of a lab session)
   does not rescan on every 0.1s tick while waiting -- the expensive scan runs at most once per `--until`
   invocation, not once per tick.
4. **Sound CVars move from six post-login `/console` chat commands into `Config.wtf`, written by
   `apply_profile` at every `start`** (both profiles, not just `minimal`): the client rewrites its own
   Config.wtf on exit, discarding whatever `create` wrote once, so this has to be reasserted on every start
   rather than relying on the file `create` wrote at lab-creation time. Live proof the client starts silent:
   `coa-client-lab probe eval 'GetCVar("Sound_EnableAllSound"), GetCVar("Sound_MasterVolume")'` read back `"0"`,
   `"0"` while in world, having never sent a `/console` command (see the session report for the full probe
   answer). `eval` uses the slower `/reload` probe transport (not in `RELAY_COMMANDS`), acceptable for a
   one-time proof; it is not on any hot path.
5. **`is_login_screen` retries for up to `COA_LAB_LOGIN_SCREEN_RETRY_WAIT` (2s, 0.2s steps), was single-shot.**
   Found live: with the waits now resolving almost instantly, the pixel check sometimes ran before the client
   had finished fading the login scene in -- memory confirms `CGlueMgr::m_currentScreen` before the frame is
   visually bright. The old `GLUE_POLL_INTERVAL` (2s) plus its own `python3` spawns had absorbed this delay by
   accident; removing that slack exposed the race. The retry is a ceiling, not a new fixed sleep.

## Measured (live, slot 2, 2026-10-26, minimal profile 1024x768 headless; see
`.agents/plans/client-lab-memory-diagnostics/reports/l7-login-overhead.md` for every run)

| Scenario | Before (controller trace / ADR 0005) | After |
|---|---|---|
| `coa-lab-mem glue` (single call, cold) | 1.49s | 1.49s (unchanged; one-time per process) |
| `coa-lab-mem glue` (single call, cached) | 1.49s | 0.19s |
| Fresh client, `login` | 36.5s (trace) | 17.0s |
| In-world account switch, `login` (success) | 42.9-49.6s (ADR 0005 table) | 8.6s / 14.9s / 14.0s (3 successful runs) |

`click_charselect_back_xtest`'s pre-existing unreliability (ADR 0005, "cause never established") is unchanged
by this ADR: a failed click still falls back to `restart_client`, whose cost is the client's own process
relaunch, not glue polling, and was out of this ADR's scope.

## Consequences

- `coa-client-lab`'s `wait_or_sleep` and the three `glue_check_*` predicate functions are removed, replaced by
  `glue_until` (one `coa-lab-mem glue --until` call per wait, same ceilings, same "fall back to a plain sleep
  when coa-lab-mem is unusable" contract).
- `coa-lab-mem`'s JSON output for `glue` carries `"validated": {"in_world": false, ...}` whenever `need_world`
  was not requested (the login/charselect/charselect-loaded fast paths): a caller must not read `in_world` from
  such a result as a measured fact, only `glue_matches`' own per-state logic does.
- `select_character_via_memory`'s own per-Down-press `python3 -c` spawns were not converted (out of this
  session's scope: already cheap now that the `glue_state` call underneath it is cache-accelerated); a future
  session could fold its two spawns into one parse the same way `glue --until` did for the waits.
