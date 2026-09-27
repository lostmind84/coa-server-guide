#!/usr/bin/env bash
# Send a release (and, when needed, its client data) to the production host with rsync.
# Usage: coa-ship-release.sh <release-id|latest> <user@prod-host>
# Remote layout: /opt/coa/releases/<id>/, /opt/coa/data/<data-version>/ (override with COA_PROD_ROOT).
# The client data source is COA_DATA_SOURCE (default $COA_BUILD_ROOT/data/<data-version>).
set -euo pipefail

ROOT="${COA_BUILD_ROOT:-/srv/coa-build}"
PROD_ROOT="${COA_PROD_ROOT:-/opt/coa}"
OUT="$ROOT/releases"

die() { echo "error: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <release-id|latest> <user@prod-host>"
ID="$(basename "$(readlink -f "$OUT/$1")")"
HOST="$2"
REL="$OUT/$ID"
[[ -f "$REL/release.env" ]] || die "release $REL not found"
DATA_VERSION="$(sed -n 's/^DATA_VERSION=//p' "$REL/release.env")"
DATA_SOURCE="${COA_DATA_SOURCE:-$ROOT/data/$DATA_VERSION}"

if ssh "$HOST" test -d "$PROD_ROOT/data/$DATA_VERSION/dbc"; then
    echo ">> client data $DATA_VERSION already on $HOST"
else
    [[ -d "$DATA_SOURCE/dbc" ]] || die "client data $DATA_SOURCE missing (needs dbc, maps, vmaps, mmaps, Cameras)"
    echo ">> sending client data $DATA_VERSION"
    rsync -a --info=progress2 "$DATA_SOURCE/" "$HOST:$PROD_ROOT/data/$DATA_VERSION.partial/"
    ssh "$HOST" mv "$PROD_ROOT/data/$DATA_VERSION.partial" "$PROD_ROOT/data/$DATA_VERSION"
fi

link_dest=()
remote_prev="$(ssh "$HOST" "ls -1d $PROD_ROOT/releases/*/.complete 2>/dev/null | sort | tail -n1 | xargs -r dirname")"
[[ -n "$remote_prev" ]] && link_dest=(--link-dest="$remote_prev")

echo ">> sending release $ID"
rsync -a --delete "${link_dest[@]}" "$REL/" "$HOST:$PROD_ROOT/releases/$ID/"
ssh "$HOST" touch "$PROD_ROOT/releases/$ID/.complete"
ln -sfn "$ID" "$OUT/shipped"
echo ">> shipped $ID to $HOST:$PROD_ROOT/releases/$ID (read RELEASE.md there, then run coa-deploy-release.sh $ID)"
