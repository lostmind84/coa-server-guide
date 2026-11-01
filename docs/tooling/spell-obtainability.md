# Is this spell obtainable? (spell reference snapshots)

Outside evidence for one question: **could a player ever acquire this spell?**

The CoA server is a reconstruction. Project Ascension shut down and took part of the server-side data with it, so
the repository's own database is *not* authority. A spell with no acquisition row is exactly what lost data looks
like. Answering the question therefore means comparing the checkout against captures taken while the game was
running — and, crucially, calibrating each source before trusting its silence.

Everything here is a community snapshot, never the live server. Use it to find the right spell, support an
interpretation, or raise a question. When the installed DBC, DB and code carry a value, they win, and a snapshot
that disagrees is a finding to report, not a licence to change the value.

## Setup

`scripts/coa-reference` and `scripts/coa-obtainable` (linked into your `PATH` by `scripts/install-agent-tools.sh`) keep their
data in `COA_REFERENCE_DIR` (default `~/CoaServer/reference`: `snapshots/` and `MANIFEST.json`). **This guide ships
no snapshot.** `coa-reference --update` downloads them from the third-party sources listed below (about 180 MB at
the time of writing); those sources have their own terms, and nothing fetched is ever committed here. Without
snapshots `coa-obtainable` still runs and says that no source covers the class, so every "not found" is unknown.

The defaults assume `--repo ~/Projects/azerothcore-wotlk-coa` and `--dbc /srv/coa/server-data/dbc`.

## Tools

    coa-reference               # what is cached, and when it was fetched
    coa-reference --update      # re-fetch (accepts source names)
    coa-obtainable --class 19   # how much of this class each source covers
    coa-obtainable 300503 705249 --repo ~/Projects/azerothcore-wotlk-coa
    coa-obtainable --issues list.json --json    # [{"issue":N,"spellId":S}, ...]

`coa-obtainable` never reports a bare absence. It first measures each source against the spells the checkout
already knows the class can acquire, prints that calibration, and says in one sentence what an absence is worth.
`scripts/coa_obtainable.py` is importable if you need the sets directly.

## Sources, strongest first

| Source | What it is | What an absence proves |
|---|---|---|
| `ascension-data/extracted/advancement.tsv` | `CharacterAdvancement` harvested through the live client's `GetAllEntries` API (30,753 rows, realm slices Darkmoon / Dawnrise / unattributed). Class column uses tokens, so the Templar appears as `Monk`. Covers talent nodes *and* ability nodes. | A great deal, where it covers the class. For 17 of the 21 custom classes it contains every spell the shipped table offers. It has no rows at all for Fleshwarden, Prophet, Wildwalker and Spiritmage, where an absence proves nothing. |
| `ascension-data/tables/*.csv` | PostgreSQL/CSV export of the db.exil.es CoA database (2026-09-13): `class_spell`, `npc_trainer`, `skill_line_ability`, `talent`, `talent_tab`, `skillline`, `mind_of_ascension_*`. Real server-side tables. | Little on its own. `class_spell` holds only `ability` rows and covers about 30 of a class's ~175 acquirable spells, so its silence is weak. |
| `bindmysoul/talents.normalized.json` | Snapshot of the fan-maintained CoA Build Hub talent calculator (3,612 nodes, 21 classes, 70 specs, fetched 2026-07-22). Full tooltip text with numbers, point costs, dependencies. Its spec/tab IDs are not the server's `.localspec` IDs: match on `spellId`. | A fair amount. It holds roughly 90% of each class's acquirable spells. |
| `sidekick/data.js` | `window.ASC.coaKits[class].specs[].abilities[]`: names, levels, talent flags, descriptions without numbers or IDs. | Nothing. It lists more names than the game had live nodes (216 against 155 for the Templar), so it evidently includes dead client entries. Presence here is not evidence of acquisition. |
| `ascension-data/cachepacks/`, `coabuildhub/`, `exiles-db-export/*.md` | Captured WDB caches, talent scrapes, and the export's own schema documentation. | Context, read the schema notes before drawing conclusions. |

Also useful and not cached here: <https://ascension-db.ascension-archive.workers.dev/> searches the same
ascension-data repository by name or ID in a browser, and <https://github.com/hertigservices/Ascension_preservation>
documents the client protocol (opcode names and numbers only; no captured payloads).

## Worked example

The 2026-09-18 Templar audit asked whether 73 spells sitting on the three Templar specialization skill lines,
with no `CharacterAdvancement` row, were lost data or dead client records:

    coa-obtainable --class 19
    class 19 (MONK): {"ours": 172, "capture": {"covers": 172, "of": 172, "extra_in_capture": 0, "identical": true},
                      "calculator": {"covers": 157, "of": 172}, "class_spell": {"covers": 29, "of": 172}}

The captured set and the shipped table hold the same 172 spells, in both directions. That is what makes the
absence of the 73 meaningful: the acquisition table is complete for this class, so they were not acquirable.
Without that line, 0 matches would have meant nothing.

Running the same calibration across the custom classes also turned up the opposite case: 12 spells that the live
capture offers and the shipped table does not, in Barbarian, Witch Hunter, Pyromancer, Cultist and Sun Cleric.
Those are real gaps in this fork.
