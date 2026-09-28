#!/usr/bin/env bash
# Load backup sets into the databases of a (new) production host. Run as the service user (coa); needs ~/.my.cnf.
# Usage: coa-restore-backup.sh <full-set-dir> [<hourly-set-dir>]
#   <full-set-dir>    a daily or predeploy set (all three databases)
#   <hourly-set-dir>  optional newer hourly set: replaces acore_auth and acore_characters with their newer state
# The servers must be stopped. Existing databases are dropped and recreated from the sets.
# The live configuration (etc.tar.gz of the newest set) is extracted to /opt/coa/etc only if that folder holds no file.
set -euo pipefail

ROOT="${COA_PROD_ROOT:-/opt/coa}"
FULL="${1:?usage: $0 <full-set-dir> [<hourly-set-dir>]}"
HOURLY="${2:-}"

die() { echo "error: $*" >&2; exit 1; }

pgrep -x worldserver >/dev/null && die "worldserver is running, stop it first"
pgrep -x authserver >/dev/null && die "authserver is running, stop it first"

for set in "$FULL" $HOURLY; do
    [[ -f "$set/manifest.env" ]] || die "$set is not a backup set"
    (cd "$set" && sha256sum --quiet -c SHA256SUMS) || die "checksum mismatch in $set"
done
grep -q '^DATABASES=.*acore_world' "$FULL/manifest.env" || die "$FULL does not contain acore_world (use a daily or predeploy set)"
if [[ -n "$HOURLY" ]]; then
    full_at="$(sed -n 's/^CREATED_AT=//p' "$FULL/manifest.env")"
    hourly_at="$(sed -n 's/^CREATED_AT=//p' "$HOURLY/manifest.env")"
    [[ "$hourly_at" > "$full_at" ]] || die "hourly set $hourly_at is not newer than full set $full_at"
fi

newest="${HOURLY:-$FULL}"
echo ">> restoring all databases from $FULL"
gunzip < "$FULL/databases.sql.gz" | mysql
if [[ -n "$HOURLY" ]]; then
    echo ">> restoring acore_auth and acore_characters from $HOURLY"
    gunzip < "$HOURLY/databases.sql.gz" | mysql
fi

if [[ -z "$(find "$ROOT/etc" -type f 2>/dev/null | head -n 1)" ]]; then
    echo ">> extracting configuration from $newest"
    tar -xzf "$newest/etc.tar.gz" -C "$ROOT"
else
    echo ">> $ROOT/etc is not empty: configuration left as is (the backup copy is $newest/etc.tar.gz)"
fi
[[ -f "$newest/deploy.log" && ! -f "$ROOT/deploy.log" ]] && cp "$newest/deploy.log" "$ROOT/deploy.log"

# shellcheck disable=SC1090,SC1091
source "$newest/manifest.env"
accounts="$(mysql -N -B -e 'SELECT COUNT(*) FROM acore_auth.account')"
characters="$(mysql -N -B -e 'SELECT COUNT(*) FROM acore_characters.characters')"
echo ">> accounts: $accounts (backup: $ACCOUNTS), characters: $characters (backup: $CHARACTERS)"
[[ "$accounts" == "$ACCOUNTS" && "$characters" == "$CHARACTERS" ]] || die "counts differ from the backup manifest"
echo ">> restored. Backup taken at $CREATED_AT on $HOST, release $RELEASE_ID ($REVISION), client data $DATA_VERSION,"
echo "   realm address was $REALM_ADDRESS. Next: install release $RELEASE_ID and run coa-deploy-release.sh $RELEASE_ID"
