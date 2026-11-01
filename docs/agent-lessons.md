# Lessons for agents working with this tooling

Technical pitfalls that cost real time in past runs, each with what to do about it. They describe the behaviour of the
tools in this guide and of the CoA server's test harness at the time they were recorded: when a tool has changed,
check before relying on an item. Nothing here is specific to one person or machine.

## A result is only worth what its environment is worth

- **Run the preflight before concluding anything.** `coa-slot preflight N` (or `scripts/coa-preflight.py`) checks that
  the build clone contains `origin/main`, that the worldserver was built from `HEAD`, that shipped SQL is applied and
  that the server's DBC set matches the client's. Run it before reproducing a defect and after every fetch, rebase,
  rebuild, restart, SQL import or client patch. A FAIL means no result is trustworthy. Past false conclusions all came
  from an unsynchronised environment: an issue filed against a binary older than its fix, a defect that "looked
  unfixed" because the local `main` was dozens of commits behind, a client text table ahead of the server's.
- **The gameplay-test image bakes its own copy of the worldserver.** `coa-slot deploy` rebuilds the worldserver image
  but not the `coa-gameplay-test` image, so scenarios keep running the old binary until it is rebuilt
  (`coa-slot compose N -f <clone>/apps/coa-gameplay-test/docker/compose.yml --profile tests build ac-gameplay-test`).
  The preflight reports this as `harness`. A scenario result that does not move after a C++ change is an
  image-staleness suspicion first, not a wrong fix; `strings` on the binary inside the container shows what shipped.
  One batch lost most of a day to this: fixes looked like failures, and an unrelated pass looked like proof.
- **Probe reads of `C_CharacterAdvancement` can measure the client's patch, not the server.** The lab client runs the
  merged client patch, whose Lua replaces several `C_CharacterAdvancement` functions (rank getters among them), so
  `probe ca` and `probe eval` on those return the patch's reconstruction. Check the `shim` field of the answer and the
  installed patch's Lua for an override of that exact function before concluding. Membership checks (`IsKnownID`,
  `IsLockedID`) are native. Swapping in the original patch archive does not work: the client's realm list and
  character creation ship in the same archive.

## Spend the expensive cycle once

- **One verification cycle per batch of changes, never per file.** `coa-slot deploy`, the harness image rebuild and
  the preflight take 5 to 10 minutes together. Write all the SQL and C++ a batch needs, run the cycle once, then run
  every affected scenario back to back. The exception is fail-before/pass-after proof, which needs two cycles for
  the batch, not two per issue. When dispatching a subagent, say "per batch of changes, never per file": a subagent
  applies the rule literally and cannot see the batch's total cost.
- **Scope a re-run to what changed.** Before re-running a suite, run `git diff --stat <measured-commit>..HEAD`.
  Documentation-only difference: re-run nothing and say in the PR that the suite was measured at that commit. One
  narrow fix: re-run only the scenarios it can reach plus any that share the touched spell, aura or stat path. A
  shared core file (stats, `Unit`, `SpellMgr`, a load-time contract) or an upstream merge touching what the scenarios
  exercise: re-run the whole suite. A reflexive full re-run of a two-hour suite after two documentation commits has
  zero information value.

## Harness and slot pitfalls

- **"Not ready after 10 minutes" can be a log problem.** `coa-slot deploy` waits for the `(worldserver-daemon) ready`
  line. If module `.conf` files are missing (only `.conf.dist` copies exist), every tick logs "Config: Missing
  property" and the ready line rolls out of `docker logs` even though the server is up. Copy the `.conf.dist` files
  to `.conf`.
- **`docker` inside a `while read` loop eats the loop's input.** Add `</dev/null` to the docker command, or the loop
  stops after the first item.
- **A restart is only finished when the server logs `ready` afterwards.** `docker logs --since` needs a UTC
  timestamp ending in `Z`; without it the filter matches old lines and the wait returns early.
- **Never `docker stop` a harness container.** It leaves the world-cache lease "building" and later runs fail with
  "World cache was not released cleanly"; add `--fresh-databases` after `run` to bypass it.
- **With `mod-playerbots` in a slot build, gameplay-test runs hang** while the disposable worldserver creates the bot
  pool, ending in a readiness timeout. Disable bots by environment for those runs
  (`-e AC_AI_PLAYERBOT_ENABLED=0 -e AC_AI_PLAYERBOT_RANDOM_BOT_AUTOLOGIN=0`). Raising `AiPlayerbot.MaxRandomBots`
  makes the next normal boot create bot characters for over an hour; `Server.log` looks frozen then, so watch
  database activity (`SHOW PROCESSLIST`).
- **Validate scenarios before the slow runs.** `validate` runs in under a second per file through the same compose
  service.

## Keep the test data honest

- **Use CoA classes only.** Only the CoA custom classes (ids 12 to 32) exist for this client and this server's
  content. The Ghost harness defaults to a Human Warrior when race and class are 0, so always pass a CoA class and a
  race, including for throwaway setup bots, and delete throwaway characters afterwards
  (`coa-client-lab erase CHARACTER --slot N`, or `.character delete` from a GM bot). A non-CoA character distorts a
  test and looks like a real one in a player's list.
- **A "no effect" reading needs a positive control.** Before trusting a null result from a lab measurement, run the
  same protocol on a case known to show the effect (for example a dash while standing still against the same dash
  while moving).
