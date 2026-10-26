# Client lab, level 3: headless instances probed through a server relay

Date: 2026-10-26
Status: built and measured on one workstation; numbers below are the only ones that count

## Design delta

The [client issue agent design](client-issue-agent.md) answers every probe through SavedVariables, which the client
writes on `/reload`: each answer costs a UI reload and clears the target. Level 3 removes that cost without touching
the client's code or memory:

- **Relay transport.** The worldserver (a CoA server script, `.labprobe` admin command reached over SOAP) whispers
  `CoaProbe\tQ:<req>:<command line>` to the lab character as an addon message, in the character's own name. The
  CoaProbe addon (`Relay.lua`) runs read-only commands only and whispers the JSON answer back to itself in chunks
  `R:<req>:<i>:<n>:<data>` (200 bytes of data, at most 64 chunks); the server swallows those whispers and
  reassembles them, and `coa-lab-relay probe` polls `.labprobe result`. No `/reload`, no SavedVariables write.
  Every answer carries a `loadId` that changes on each UI load.
- **Cheaper client.** `COA_LAB_PROFILE=minimal` writes an 800x600 window and low-cost CVars before every start;
  `COA_LAB_DISPLAY=headless` runs gamescope's headless backend (no window on the desktop, no Hyprland).
- **Instances.** `COA_LAB_INSTANCE=1..9` selects a reflinked copy of the lab client and prefix with its own state
  directory, so several lab clients can run side by side against one slot with different accounts.
- **New probes.** `frame <GlobalName>` (type, shown, visible, text) and `errors` (Lua errors seen by the addon's own
  error handler, chained to the previous handler).

Out of scope, by decision of 2026-10-25: injected or proxy DLLs, reading or writing client memory, lifting
protected Lua functions, anti-cheat or Warden changes, and building a client from decompiled sources. The relay
is ordinary addon-message traffic between the client and our own server.

## Server side

The relay lives in the server repository (`src/server/coa/CoAProbeRelay*`, documented in
`docs/coa/client-lab-probe-relay.md` there). It is off by default; `coa-client-lab relay-setup N` turns it and
SOAP on for one slot (SOAP listens on `0.0.0.0` inside the container, published on the host's `127.0.0.1` only).
Only accounts whose name starts with `COALAB` can be probed, and the relay and the addon each refuse anything
outside the read-only command list.

## Measurements

Filled in from the runs below; every figure names its command.

Setup for every row: slot 2, server `feat/client-lab-probe-relay` `19fc3ccd81` (server repo), `coa-client-lab
preflight 2` PASS (368 of 368 client tables identical), character `Coalabone` (Orc Barbarian, level 1, Valley of
Trials), host 32 threads / 125 GiB, NVIDIA RTX 5070 Ti, load average 5-20 during the runs (other agents were
compiling earlier). Memory from `coa-lab-footprint sample --seconds 60`: Pss and Rss summed over the gamescope tree
and every process of the lab prefix; CPU 100 % = one core. GPU memory from
`nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv`.

### Baseline (readable profile, nested 1920x1080, `/reload` probes)

| Measure | Value |
|---|---|
| `start 2` until the window is found | 10.0 s |
| `login` (fixed sleeps 20 + 25 + 45 s plus typing; not a readiness measure) | 105.5 s |
| `probe ping` on the `/reload` path, twice | 14.8 s, 14.9 s (includes `COA_LAB_RELOAD_WAIT=10`) |
| Login screen, 60 s | Pss 1,557,966 KiB, Rss 1,921,928 KiB, CPU 112.5 % |
| In world, idle, 60 s | Pss 1,974,678 KiB, Rss 2,338,488 KiB, CPU 49.7 % |
| GPU memory in world | Ascension.exe 627 MiB, gamescope 170 MiB |
| Relay `probe spell 501281` in the same session, three times | 428, 229, 242 ms |

### Minimal profile, nested 800x600

CVar check: `strings -n 4 Ascension.exe | grep -xF <name>` in the lab exe. Kept: `maxFPS` (10), `maxFPSBk` (5),
`groundEffectDensity` (16), `environmentDetail` (0.5), `particleDensity` (0.1), `weatherDensity` (0),
`spellEffectLevel` (0), `specular` (0), `projectedTextures` (0), `textureFilteringMode` (0), `baseMip` (1),
`ffxGlow` (0), `ffxDeath` (0), `showfootprints` (0), and `farclip` (177, already in the lab Config.wtf). Dropped:
`gxMultisample` (absent from the exe).

| Measure | Value |
|---|---|
| `start 2` until the window | 7.2 s |
| Login screen, 60 s | Pss 1,374,569 KiB, Rss 1,725,068 KiB, CPU 109.9 % |
| In world, idle, 60 s | Pss 1,806,198 KiB, Rss 2,158,680 KiB, CPU 13.5 % |
| GPU memory in world | Ascension.exe 235 MiB, gamescope 166 MiB |
| Relay `probe spell 501281`, three times | 463, 214, 221 ms |
| Largest process (from `/proc/<pid>/smaps_rollup`) | Ascension.exe Pss 1,304,308 KiB, of which anonymous 1,080,716 KiB |
| 640x480 (`COA_LAB_WIDTH=640 COA_LAB_HEIGHT=480`) | accepted: login screen rendered, screenshot 640x480 |

The login screen keeps a core busy in both profiles; `maxFPS` does not seem to apply there (not investigated).

### Headless + minimal (the level 3 milestone run)

`COA_LAB_PROFILE=minimal COA_LAB_DISPLAY=headless coa-client-lab start 2`, then
`coa-client-lab login COALAB1 <pw> Coalabone`, then `coa-lab-relay probe ...`. Raw answers:
`~/CoaServer/client-lab/evidence/level3-2026-10-26/milestone-1/` (outside git).

| Measure | Value |
|---|---|
| `start 2` until the window on gamescope's Xwayland display (`:1`) | 7.3 s; `hyprctl clients` lists no gamescope window |
| `login` with the default sleeps | returned after 112.8 s; first relay `ping` 0.3 s later, at the first attempt |
| `probe spell 501281`, three in a row | 243, 246, 249 ms; same `loadId` `1792972222-144495`; tooltip line 1 `Fel Fireball` |
| Server DBC `SpellName[enUS]` of 501281 (`coa-dbc-viewer record --id 501281` on a copy of `Spell.dbc`) | `Fel Fireball` |
| `WTF/Account/COALAB1/SavedVariables/CoaProbe.lua` mtime and size, before and after the three probes | `1792971706 856`, unchanged |
| `probe spell 999999999` | `error = "unknown spell 999999999"`, 239 ms |
| `.labprobe send Coalabone r1 eval 1` over SOAP | SOAP fault `not a read-only probe request` |
| In world, idle, 60 s | Pss 1,755,257 KiB, Rss 2,101,924 KiB, CPU 13.0 % |
| GPU memory | Ascension.exe 233 MiB, gamescope 68 MiB (the GPU is still used) |
| `screenshot` | 800x600 PNG, mean intensity 0.133 (not black) |
| `probe frame GameTooltip` | `exists, type GameTooltip, shown false, visible false` |
| `probe errors` after login, and after `chat "/run error('coaprobe-test')"` | `installed false, total 0` both times |

With shorter login sleeps (`COA_LAB_LOGIN_WAIT`, `COA_LAB_REALM_WAIT`, `COA_LAB_WORLD_WAIT`), time from `start`
to the first relay answer: 10/12/0 s → 45.0 s; 6/8/0 s → 36.9 s. Both logins worked at the first try; two runs
are not enough to change the defaults.

Lua errors: the addon's handler is replaced after login and stays replaced. `geterrorhandler()` differs from the
addon's handler while `issecurevariable("seterrorhandler")` and `issecurevariable("geterrorhandler")` are both 1
(read once through the `/reload` path's `eval`), so secure client code takes the handler; a post-hook on
`seterrorhandler` never fired, and both sessions that loaded it showed a "UI Error" line at login (the sessions
without it did not), so it was dropped. What does work: the
client's own reporter prints `|Huierror:|h ... UI Error: an interface error occured ...` as a system message, and
`probe log` captured it one second after `/run error('coaprobe-test')`. Lua errors are therefore detectable
(count and time), not readable (text).

### Three instances in parallel (headless + minimal, sleeps 6/8/0)

`COA_LAB_INSTANCE=1..3 coa-client-lab create-instance` (reflink, under a second each; `df` unchanged), accounts
`COALAB1..3` (characters `Coalabone`, `Coalabtwo`, `Coalabthree`), all started at the same moment.

| Measure | Value |
|---|---|
| Start to first relay answer | 38.8 s, 38.8 s, 38.8 s |
| `probe spell 501281` sent to the three at the same moment | 243, 252, 41 ms; each answer names its own character; tooltip line 1 `Fel Fireball` |
| Pss / CPU per instance in world, 60 s | 1,672,548 KiB / 15.8 %, 1,671,645 KiB / 15.5 %, 1,646,134 KiB / 16.2 % |
| Host `MemAvailable` before and after (`free -m`) | 73,538 → 68,328 MiB (−5,210 MiB for three; the first run: −5,269 MiB) |
| GPU memory | Ascension.exe 235 MiB and gamescope 68-72 MiB each |

The first parallel run showed the same `loadId` on all three clients (`1792972625-176494`): `math.random` repeats
across client processes (`176494` also appeared in two separate loads of one client). The id now adds
`GetTime()` milliseconds; the second run gave three different ids.

### Design targets

| Target | Result |
|---|---|
| Less than 1 GB of RAM per instance | **not met**: Pss 1.6-1.9 GiB per instance; the client's own heap (Ascension.exe anonymous memory, about 1.03 GiB) is the largest part, the Proton/gamescope/Xwayland processes about 0.5 GiB |
| No GPU | **not met** on this host: the headless backend still renders on the NVIDIA GPU. Software rendering needs `vulkan-swrast` (lavapipe) or `xorg-server-xvfb`, neither installed, by decision |
| Ready in game in less than 60 s | **met with shorter login sleeps**: 45.0 s (10/12/0) and 36.9-38.8 s (6/8/0: one single run, two runs of three clients); not met with the default sleeps (113 s) |
| At least 3 instances in parallel | **met** (three headless instances on one slot, simultaneous probes answered correctly) |
