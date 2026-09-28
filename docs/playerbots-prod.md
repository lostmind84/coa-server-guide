# Production server: run 2000 CoA bots with mod-playerbots

[mod-playerbots](https://github.com/Zyth45/mod-playerbots/blob/coa/README_COA.md), branch `coa`, fills the realm
with bots of the CoA classes. This page adds them to a production host installed with
[prod-server.md](prod-server.md). The bots are compiled into worldserver, so the release must come from a build
server that has the module ([playerbots-build.md](playerbots-build.md)); nothing is compiled here.

Status: run on 2026-09-28 in an Ubuntu 26.04 container standing in for production (repack database
`main-20260919-b3717c137`, core `d2c61f17c`): first deployment with the module (`f765cbb8`) and 200 bots, then 2000
bots, then an update of the module (`46e3d5f8`) deployed while the 2000 bots were online. The container shared a
32-thread workstation with other work: the figures below are an order of magnitude, not a benchmark. Not tested:
real players connected alongside 2000 bots, more than an hour at 2000 bots, a rollback with `--restore` of a set
holding `acore_playerbots`.

## Sizing

Measured with 2000 bots, `MapUpdate.Threads = 8`, all other settings at the module's defaults:

| | 200 bots | 2000 bots |
| --- | --- | --- |
| worldserver memory (RSS), steady | 6.2 GB | 9.8 GB |
| CPU (worldserver + MySQL) | about 2.5 cores | 2 to 3.5 cores |
| world update time (`server info`) | mean 4 ms, 99th percentile 14 ms | mean 15 to 25 ms, 99th percentile 40 to 220 ms |
| MySQL memory (defaults) | 0.9 GB | 0.7 GB |

- Memory grows with each bot that logs in and stays flat once they are all online (9.73 → 9.77 GB over 8 minutes at
  2000). The bots were young (average level 15 to 20, they spread over levels 1-60 and level up while playing);
  how memory evolves over days was not measured.
- The module's own figures differ: its README says about 10 GB for 1000 bots, `playerbots.conf.dist` says
  "1000 needs about 32 GB" (of machine memory). Plan **32 GB of RAM** for 2000 bots and watch the first days.
- CPU: the module README advises `MapUpdate.Threads` at half the CPU threads. The test had 8 threads available to the
  maps and the mean update time stayed under 25 ms (50 ms is where `SmartScale` starts to put bots to sleep, see
  below). A host with at least 8 cores is the tested shape.
- Disk after the first hour: `acore_characters` 357 MB (5250 bot characters in 250 accounts: the module keeps a pool
  larger than the number online), `acore_playerbots` 81 MB.

Bots do not count as connected players: with 2000 bots online, `server info` printed
`Connected players: 0. Characters in world: 1995.` `PlayerLimit` therefore still applies to real players only.

## Before the first release with bots

### Database

As root, once:

```bash
sudo mysql <<'SQL'
CREATE DATABASE acore_playerbots DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
GRANT ALL PRIVILEGES ON acore_playerbots.* TO 'acore'@'localhost';
SQL
```

Leave it empty: at the first start worldserver logs `Database Playerbots is empty, auto populating it...` and fills
it from the release (`source/modules/mod-playerbots/data/sql/playerbots/`). The module's `world/` and `characters/`
SQL files are applied to `acore_world` and `acore_characters` by the same updater, like any release update.

### Scripts

Copy the current `coa-deploy-release.sh` and `coa-backup.sh` to `/opt/coa/` (as in prod-server.md). The versions
from 2026-09-28 on:

- `coa-backup.sh` adds `acore_playerbots` to the daily and pre-deploy sets when the database exists, so a rollback
  restores it with the rest. Hourly sets stay `acore_auth` + `acore_characters`.
- `coa-deploy-release.sh` waits for worldserver to exit before switching releases (see [Stopping](#stopping)).

### Firewall

The module starts a "command server" listening on **all addresses, TCP 8888**
(`AiPlayerbot.CommandServerPort`), without authentication. It only answers read requests about bots (state,
position), but it has no reason to be reachable from outside: keep 8888 closed like 3306, or set
`AiPlayerbot.CommandServerPort = 0`.

## Configuration

`coa-deploy-release.sh` refuses to deploy while a shipped `.conf.dist` has no live `.conf`: create
`modules/playerbots.conf` with the loop of prod-server.md ("Live configuration"), then set:

| File | Setting | Value |
| --- | --- | --- |
| `modules/playerbots.conf` | `PlayerbotsDatabaseInfo` | `"127.0.0.1;3306;acore;CHANGE_ME;acore_playerbots"` |
| `modules/playerbots.conf` | `AiPlayerbot.MinRandomBots`, `AiPlayerbot.MaxRandomBots` | `2000` |
| `modules/playerbots.conf` | `AiPlayerbot.CommandServerPort` | `0` if you do not use it (see Firewall) |
| `modules/playerbots.conf` | `AiPlayerbot.RandomBotRandomPassword` | `1`, **mandatory, before the first start** (see below) |
| `worldserver.conf` | `MapUpdate.Threads` | half the CPU threads (8 in the test) |

With the default `AiPlayerbot.RandomBotRandomPassword = 0`, each bot account is created with its own name as
password (`rndbot1` / `rndbot1`, `RandomPlayerbotFactory.cpp`): anyone who knows the prefix can log in to 250
accounts holding thousands of characters, and the accounts stay after the module is removed. The setting only applies
to accounts created afterwards; accounts already created keep their password. `coa-deploy-release.sh` refuses to
deploy a release that contains the module unless the live `playerbots.conf` has
`AiPlayerbot.RandomBotRandomPassword = 1`.

Everything else in `playerbots.conf.dist` is already what a CoA realm wants (module README, "Recommended settings").
The module README also recommends `CharacterCreating.Disabled.ClassMask = 2047` in `worldserver.conf`, which stops
**players** from creating the nine WotLK classes; bots stay on CoA classes on their own.

The live `playerbots.conf` is kept across releases and a module update may add keys. `RELEASE.md` lists them under
**Configuration keys**, and the deploy script prints keys missing from the live file under `note:`; a missing key
uses its compiled default. After a large module update, the simplest is to copy `playerbots.conf.dist` again and set
the values of the table above.

To go up gradually, start with 200 bots, check the figures, then raise `MinRandomBots`/`MaxRandomBots` and restart
worldserver (`.playerbots rndbot reload` re-reads the file, but bot accounts are created at startup).

## First start

In the test, from a deployment with the module until 2000 bots were online:

1. worldserver fills `acore_playerbots` and applies the module updates, builds its caches
   (`Loaded playerbots config in 163197 ms` the first time, 11 s afterwards), then prints `ready`. The deploy
   script's `ready` wait allows 30 minutes (`COA_READY_TIMEOUT`).
2. it creates the bot accounts and characters it needs (`Creating random bot accounts...`, 180 accounts when going
   from 200 to 2000 bots);
3. bots log in at about 60 to 90 per minute (`AiPlayerbot.RandomBotsPerInterval = 60` per
   `RandomBotUpdateInterval = 20` seconds): 2000 bots took about 24 minutes. Update time peaks (up to 1.5 s) during
   that climb, then settles.

Each bot gets a random level on its first login and only moves to a zone of its level on the next automatic
teleport (module README, "Things that surprise people").

## Stopping

worldserver keeps working after the `server shutdown` countdown: it saves the bots and writes what its database
queues still hold.

- **Right after the first start**: 17 minutes in the test, with 200 bots. The module had just built its item caches
  and was writing them (`Closing down DatabasePool 'acore_playerbots'. Waiting for 4270 queries to finish...`).
- **In normal operation with 2000 bots**: about 1.5 minutes.

Never start worldserver again while the previous one is still running (`pgrep -x worldserver` prints a pid): two
instances would write to the same databases. The deploy script now waits up to `COA_STOP_TIMEOUT` (1800 s) and, if
worldserver is still saving, stops **without** switching anything (`worldserver still saving after …s; nothing was
switched`); run it again once worldserver has exited. The older script sent `SIGTERM` after 120 s and started the new
release 5 s later, which with bots could run both at once.

## Updating

Same procedure as any release (prod-server.md, "Deploying a release"). In the test, deploying a module update
while 2000 bots were online took the deploy script 2 min 3 s from confirmation to its end: pre-deploy backup (125 MB
with `acore_playerbots`), 1.5 min of shutdown, restart until `ready`. The bots then log in again at the same pace as
the first time (1425 back online 15 minutes later): the realm is thinly populated for about 25 minutes after each
deployment or restart. `RELEASE.md` has an **External modules** section with the module
commits; a **modified SQL files** warning there works like the core one. Example seen:
`data/sql/playerbots/custom/zz_coa_rotation_corrections.sql`, written to be re-applied (it matches rows by content),
which the updater re-applied (`Reapplying update "zz_coa_rotation_corrections.sql" … (it changed)`).

## Backups

With bots, the hourly set grew from a few KB to 18 MB (5 s to take) because bot characters live in
`acore_characters`; the pre-deploy set was 125 MB. `acore_playerbots` is only in daily and pre-deploy sets.

## Monitoring and load control

| What | How |
| --- | --- |
| update time | `server info` in the worldserver console: `Mean`, `Percentiles (95, 99, max)` |
| bots online, by class, level, role, activity | `.playerbots rndbot stats` |
| memory | `ps -o rss= -C worldserver` (KB) |

When the server slows down, `AiPlayerbot.botActiveAloneSmartScale = 1` (default) puts idle bots to sleep: none are
reduced below a 50 ms update time, all non-forced bots are paused at 200 ms (`…DiffLimitfloor`,
`…DiffLimitCeiling`). Bots near a real player, in combat, in a group or in a dungeon stay active regardless. The
other levers, all in `playerbots.conf`: fewer bots (`MaxRandomBots`), `AiPlayerbot.BotActiveAlone` (60 % of the
bots away from players stay active), or `AiPlayerbot.DisabledWithoutRealPlayer = 1` (bots only log in when a real
player is online).

## Removing the bots

Deploying a release built without the module stops the bots: that worldserver has no bot code and never opens
`acore_playerbots`. The live `modules/playerbots.conf` is then no longer read and can be deleted. What the bots left
behind stays, because nothing removes it:

| Left behind | Where | Effect without the module |
| --- | --- | --- |
| bot accounts (`rndbot…`) and their characters, items, mail | `acore_auth`, `acore_characters` | ordinary offline accounts; with the default password setting, anyone can log in to them |
| guilds and arena teams created by bots, which players may have joined | `acore_characters` | kept, led by an offline bot |
| `playerbots_*` tables, `charsections_dbc`, `emotetextsound_dbc`, spell 30758 in `spell_dbc` | `acore_world`, `acore_characters` | unused tables and one extra spell row |
| random emblems given once to guilds whose emblem was empty (including player guilds) | `guild` | kept |
| `acore_playerbots` | its own database | unused; can be dropped |

To remove the bots themselves, do it **with the module still in place**, one start before the release without it:

1. take a backup (`coa-backup.sh daily`);
2. set `AiPlayerbot.DeleteRandomBotAccounts = 1` and restart worldserver. The module deletes the bot characters and
   accounts, then rows left without an owner: items, mail, arena teams, and **guilds whose leader was a bot**
   (players in such a guild lose it). It then asks for the setting to go back to 0;
3. set it back to 0, then deploy the release without the module.

Not tested here: the deletion itself, and how long it takes with 5000 characters. Restoring a backup taken before the
bots is the only complete way back, but it also discards everything real players did since.
