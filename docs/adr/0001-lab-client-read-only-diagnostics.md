# 0001. Read-only diagnostics for the lab client: Lua errors, process memory, server packet log

- Status: proposed
- Date: 2026-10-26

## Context

The client lab (`docs/design/client-lab-level3.md`) already drives a headless lab client and answers
read-only probes through an addon-message relay to the server, without `/reload`. Three gaps stayed open
after that work (`client-lab-memory-diagnostics` plan, `design.md`):

1. **Lua error text.** The CoaProbe addon used to call `seterrorhandler` to install its own handler, but it
   never ran: the CoA UI overwrites the global `seterrorhandler` with a no-op after login and keeps the real
   native under `_seterrorhandler` (`SharedXML/Util/SharedOverwrites.lua:89-95` in the extracted stock UI
   corpus); only the client's own `ErrorHandler.lua:62` calls `_seterrorhandler`. So an addon's own handler
   is dead code on this client, and the level 3 design document recorded Lua errors as detectable (a system
   message, a count) but not readable (no text). The client's own `ErrorHandler:HandleError`
   (`ErrorHandler.lua:472-577`) still stores every error as `{message, stack, locals, time, counter}` in the
   plain global `ERROR_HANDLER_DATABASE.errors.current` (`ErrorHandler.lua:11-16, 290-318`), rotated into
   `.errors.previous` at `PLAYER_ENTERING_WORLD`. Nothing wraps that table in a taint guard, so any addon can
   read it without installing a handler.
2. **Client-side unit/aura/spell state independent of the Lua API.** The relay can only ask Lua
   (`UnitHealth`, `UnitAura`, …), which is exactly the thing a comparison needs an independent source for: the
   object manager, `CGUnitData` (health, max health), the aura array and the player name cache, and the
   client's loaded `Spell.dbc` row (`g_spellDB`), as the client's own engine holds them in process memory.
3. **What the server actually sent.** Neither the relay nor the Lua API prove what bytes left the server;
   only the worldserver's own packet log does.

## Options considered

### Lua error text (use case 1)

| Option | Verdict |
|---|---|
| **A. Read `ERROR_HANDLER_DATABASE.errors` directly** (plain global read, no handler install, no protected call) | **chosen** |
| B. `ErrorHandler:RegisterCallback("OnError", ...)` to keep a live copy across the `/reload` wipe | not needed: the wipe at `PLAYER_ENTERING_WORLD` clears `.current` into `.previous` either way, so a callback buys nothing a plain read of both arrays does not already give |
| C. Walk the Lua heap from outside (the global `_G`, `TString` records, Blizzard-modified Lua 5.1 layout) | rejected: large, fragile, unnecessary while A works |

### Client unit/aura/spell state (use cases 2 and 4)

| Option | Verdict |
|---|---|
| **A. External read with `process_vm_readv`/`/proc/<pid>/mem`**, resolving the object manager, unit data, aura array and `g_spellDB` from outside the process | **chosen**: no injection, no write, Warden stays out of the loop |
| B. Addon API only (`UnitAura`, `UnitHealth`, the existing relay) | already available (`probe auras`/`probe state`); it is the Lua view this diagnostic exists to check against, not a substitute for it |
| C. In-process reader (injected DLL) | rejected: injection was already ruled out for every slot when the relay was designed |

### Server-to-client packets (use case 3)

| Option | Verdict |
|---|---|
| **A. Worldserver `PacketLogFile` + `.packetlog <character> on|off` over SOAP, read with a PKT 3.1 file reader** | **chosen**: one session only, plaintext, logged before compression and encryption |
| B. Client-side capture (hook `NetClient::ProcessMessage` or similar) | rejected: requires code injection into the client |
| C. CoaProbe `pkwatch` (the existing Extensions `RegisterPacket` hook) | kept as is; it only shows what the Lua packet API surfaces, not the raw wire bytes, and stays the lighter-weight option when that is enough |

## Decision

1. **CoaProbe `errors`** (`addons/CoaProbe/Commands.lua`) reads `ERROR_HANDLER_DATABASE.errors.current`
   (or `.previous`) directly, with no `seterrorhandler`/`_seterrorhandler` call anywhere. It answers through
   the relay like the other read-only probes: newest entries first, message/stack truncated to the relay's
   byte budget, a `locals` opt-in left out by default. The dead own-handler path (`addons/CoaProbe/Errors.lua`)
   is removed.
2. **`scripts/coa-lab-mem`**: a read-only external reader, Python 3 standard library, `process_vm_readv` only
   (never a write syscall, never a `ptrace` attach, never injected code). Before any read it refuses unless:
   - the target process's executable is under `~/CoaServer/client-lab` (never the user's own client);
   - the lab lock names a slot other than 1;
   - that slot's `worldserver.conf` has `Warden.Enabled = 0`.

   Every value the tool reports carries its own `"validated": true|false`: `true` only once this diagnostic
   matched it, this session, against an independent known value (a server database row, a `probe
   state`/`probe auras` answer, a `/target` GUID); otherwise the value is a hypothesis from the decompilation
   or from structural inference, reported as such, never silently upgraded.
3. **`scripts/coa-lab-packets`**: reads the worldserver's own `PacketLogFile` (`.packetlog <character> on`,
   SOAP) with a PKT 3.1 parser, decoding at least `SMSG_AURA_UPDATE(_ALL)`. This shows what the server sent,
   which is a different claim from use case 2 (what the client's engine kept) or the Lua API (what the UI
   shows); none of the three substitutes for the others.

`wowdecomp` (a client decompilation, no license) is used only as an **offset and layout reference** to form a
hypothesis to test; no code from it is copied into either tool. Every offset actually used was independently
confirmed live against the lab client before being reported as validated.

## Consequences

- No write, no `ptrace` attach, no injected code, no change to Warden or any anti-cheat path. The lab-only,
  `Warden.Enabled = 0`, slot-not-1 guards stay phase-1 restrictions by design, not an incidental limitation:
  loosening any of them needs its own decision.
- `ERROR_HANDLER_DATABASE` is readable without a handler, but an addon's own `seterrorhandler` callback stays
  dead on this client; `coa-client-lab probe log` remains the only source for a *live* notification the moment
  an error happens, while `probe errors` is the source for its *text*.
- `coa-lab-mem`'s offsets are specific to the validated client build; a client update can change them without
  crashing the reader (wrong field, not a fault), which is why every value stays tied to an explicit
  `validated` flag and an independent comparison rather than being reported on trust.
- `coa-lab-packets` only proves what the server sent in one logged session; a mismatch between what it shows
  and what `coa-lab-mem`/the Lua API show is itself a finding (client dropped or mis-processed a packet), not
  something either tool resolves on its own.
- The server repository keeps an independent copy of the same offsets and guards
  (`apps/coa-tests/client_lab/lab_memory.py`, `docs/adr/0007-client-lab-reads-lab-client-memory.md` there) so
  its own verification harness does not execute scripts from this public guide; the two copies must change
  together when an offset, a guard rule or the client build changes.
