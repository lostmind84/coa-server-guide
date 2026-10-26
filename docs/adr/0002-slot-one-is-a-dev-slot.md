# 0002. Slot 1 is a development slot for the lab tools

- Status: accepted
- Date: 2026-10-26
- Supersedes: the "slot other than 1" guard of [ADR 0001](0001-lab-client-read-only-diagnostics.md)

## Context

ADR 0001 made `coa-lab-mem` refuse a lab lock naming slot 1, and `coa-client-lab character` refused slot 1,
because slot 1 was the server the user's own game client played on: test accounts, GM characters or a lab
client there would have mixed with real play. On 2026-10-26 the user stated that slot 1 is no longer used as a
game server and is dedicated to development like the other slots.

## Options considered

1. Keep refusing slot 1: one slot fewer for parallel client checks, for a risk that no longer exists.
2. Allow slot 1 with the same guards as every other slot.

## Decision

Option 2. The lab tools accept any slot `coa-slot` knows. The guards that protect the user and the official
servers stay unchanged:

- `coa-lab-mem` reads only a process running `Ascension.exe` from the lab directory, never the user's own client;
- it still requires `Warden.Enabled = 0` in the slot's `worldserver.conf`, now located through `coa-slot env N`
  (`ETC`), since slot 1 keeps its configuration in `/srv/coa/etc` rather than `~/CoaServer/slots/s1/etc`.

## Consequences

- Slot 1 can host lab checks once it is configured like the others (Warden off, `relay-setup 1`).
- Lab accounts (`COALAB*`) and test characters may now appear in slot 1's database.
- `coa-slot` itself still treats slot 1 specially (`reset-db` and `destroy` cover slots 2-4 only); that is
  unchanged here.
