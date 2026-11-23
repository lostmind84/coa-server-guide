# 0020. One per-machine client folder, no built-in default

- Status: accepted
- Date: 2026-11-23

## Context

Four tools defaulted to the same client folder, `~/CoaServer/client/ascension-live`, each with its own override:
`coa-client` (`COA_CLIENT_DIR`), `coa-client-lab` (`COA_USER_CLIENT`), `coa-lab-mem` (`COA_USER_CLIENT`, a Python
constant) and `coa-preflight.py` (`--client-data`, the `Data/` directory). README and QUICKSTART used the same folder
name in their commands.

The default named one developer's folder layout, and on that machine it had become a stale copy nobody played on.
On 2026-11-23 a preflight reported "368 of 368 client tables identical" after comparing the server with that stale
copy: a silent default made a check pass against the wrong client.

## Considered options

1. Keep the defaults and document the overrides better.
2. One variable, set per machine in a file outside the repository, with no default.
3. One variable with a guessed default (first folder found holding `Ascension.exe`).

## Decision

Option 2 (owner decisions of 2026-11-23):

- One variable, `COA_CLIENT_DIR`, read by all four tools.
- Its per-machine value lives in `~/.config/coa/client.env` (`COA_CLIENT_DIR=/path` lines, parsed, never executed),
  loaded when present. An exported variable wins over the file. `COA_USER_CLIENT` stays accepted as a deprecated
  alias with a one-line warning; `--client-data` stays an explicit override of the preflight.
- No fallback. Set nowhere, the tool stops with a message naming the variable, the file and an example line. A set
  folder that does not exist or has no `Data/` directory also stops it.
- One parser, `scripts/coa_client_dir.py`. The Python tools import it from their own (link-resolved) directory;
  the bash tools run it and read the folder on its standard output, so the file format and the precedence live in
  one place.
- Only the commands that read the client resolve it: `coa-client` (launch and `--kill`), `coa-client-lab` `create`,
  `destroy` and the instance commands (their path-aliasing guard compares with the user's folder),
  `coa-lab-mem`'s pid guard, and the preflight unless `--skip-dbc`. `coa-client-lab stop` never refuses to stop:
  without a folder it skips its "user's client changed" check with a warning.
- `coa-client --kill` and its "already running" check match the configured folder's name in the Wine process path,
  instead of the fixed `ascension-live`.
- The docs speak of "your client folder" and the variable, never of a machine path.

Option 1 keeps the silent wrong answer. Option 3 can pick the stale copy again, which is the failure that started
this.

## Consequences

- A fresh machine needs one line in `~/.config/coa/client.env` before the client tools work; the error message says
  what to write.
- `coa-client` needs `scripts/coa_client_dir.py` next to it, so it is installed as a link (`ln -s`) like the other
  tools. A copy installed with `cp` keeps its old built-in path until it is replaced by the link.
- The preflight report starts with an `INFO client` line naming the client data it compares with and where that
  setting came from.
- Scripts that exported `COA_USER_CLIENT` keep working and see one warning line on standard error.
