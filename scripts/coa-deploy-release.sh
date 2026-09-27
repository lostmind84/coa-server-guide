#!/usr/bin/env bash
# Deploy a received release on the production host. Run as the service user (coa) that owns /opt/coa.
# Usage: coa-deploy-release.sh <release-id>
#        coa-deploy-release.sh --rollback <release-id> [--restore <backup.sql.gz>]
#        (rollback skips the checksum and RELEASE.md steps; --restore loads the backup while the servers are stopped)
# Needs ~/.my.cnf with the database user credentials (used for the backup) and /opt/coa/etc/*.conf in place.
set -euo pipefail

ROOT="${COA_PROD_ROOT:-/opt/coa}"
KEEP="${COA_KEEP_RELEASES:-3}"
READY_TIMEOUT="${COA_READY_TIMEOUT:-1800}"

die() { echo "error: $*" >&2; exit 1; }

ROLLBACK=0
RESTORE=""
if [[ "${1:-}" == "--rollback" ]]; then
    ROLLBACK=1
    shift
    [[ "${2:-}" == "--restore" && -n "${3:-}" ]] && { RESTORE="$3"; set -- "$1"; }
fi
[[ $# -eq 1 ]] || die "usage: $0 <release-id> | --rollback <release-id> [--restore <backup.sql.gz>]"
[[ -z "$RESTORE" || -s "$RESTORE" ]] || die "backup $RESTORE not found"
REL_ID="$1"
REL="$ROOT/releases/$REL_ID"

[[ -f "$REL/.complete" ]] || die "$REL is incomplete or missing (.complete not found)"
# shellcheck disable=SC1091
source "$REL/release.env"
[[ "$RELEASE_ID" == "$REL_ID" ]] || die "release.env names $RELEASE_ID, not $REL_ID"

if [[ $ROLLBACK -eq 0 ]]; then
    echo ">> verifying checksums"
    (cd "$REL" && sha256sum --quiet -c SHA256SUMS) || die "checksum mismatch in $REL"
    . /etc/os-release
    [[ "$BUILD_OS" == "$ID-$VERSION_ID" ]] || die "release built for $BUILD_OS, host is $ID-$VERSION_ID"
    missing="$(ldd "$REL/bin/worldserver" "$REL/bin/authserver" | grep 'not found' || true)"
    [[ -z "$missing" ]] || die "missing runtime libraries: $missing"
    ${PAGER:-less} "$REL/RELEASE.md"
fi

[[ -d "$ROOT/data/$DATA_VERSION/dbc" ]] || die "client data $DATA_VERSION missing in $ROOT/data"

for dist in $(cd "$REL/etc" && find . -name '*.conf.dist' -printf '%P\n'); do
    conf="$ROOT/etc/${dist%.dist}"
    [[ -f "$conf" ]] || die "$conf missing: create it from $REL/etc/$dist before deploying"
    new_keys="$(comm -23 \
        <(grep -E '^[A-Za-z][A-Za-z0-9._]* *=' "$REL/etc/$dist" | sed 's/ *=.*//' | sort -u) \
        <(grep -E '^[A-Za-z][A-Za-z0-9._]* *=' "$conf" | sed 's/ *=.*//' | sort -u))"
    [[ -z "$new_keys" ]] || echo "note: ${dist%.dist} lacks keys (their code defaults apply): $(tr '\n' ' ' <<<"$new_keys")"
done

read -r -p "Deploy $REL_ID now? Players will be disconnected. [y/N] " answer
[[ "$answer" == [yY] ]] || die "aborted"

current=""
[[ -L "$ROOT/current" ]] && current="$(basename "$(readlink -f "$ROOT/current")")"

mkdir -p "$ROOT/backups" "$ROOT/logs"
backup="$ROOT/backups/$(date +%Y%m%d-%H%M%S)-before-$REL_ID.sql.gz"
echo ">> backing up databases to $backup"
mysqldump --single-transaction --no-tablespaces --routines --events --add-drop-database \
    --databases acore_auth acore_characters acore_world | gzip > "$backup" \
    || { rm -f "$backup"; die "database backup failed, nothing was changed"; }

echo ">> stopping servers"
if screen -list | grep -q '\.coa-world\b'; then
    screen -S coa-world -p 0 -X stuff $'server shutdown 5\r'
    for _ in $(seq 120); do pgrep -u "$(id -u)" -x worldserver >/dev/null || break; sleep 1; done
fi
pkill -u "$(id -u)" -x worldserver && sleep 5 || true
pkill -u "$(id -u)" -x authserver || true
screen -wipe >/dev/null || true

if [[ -n "$RESTORE" ]]; then
    echo ">> restoring $RESTORE"
    gunzip < "$RESTORE" | mysql || die "restore failed; servers are stopped, current release unchanged"
fi

ln -sfn "releases/$REL_ID" "$ROOT/current.new" && mv -T "$ROOT/current.new" "$ROOT/current"
ln -sfn "$DATA_VERSION" "$ROOT/data/current.new" && mv -T "$ROOT/data/current.new" "$ROOT/data/current"
echo "$(date -Is) $current -> $REL_ID backup=$backup${RESTORE:+ restored=$RESTORE}" >> "$ROOT/deploy.log"

log="$ROOT/logs/world-console-$REL_ID-$(date +%Y%m%d-%H%M%S).log"
echo ">> starting worldserver (SQL updates are applied now), log: $log"
screen -dmS coa-world -L -Logfile "$log" "$ROOT/current/bin/worldserver"
for _ in $(seq "$READY_TIMEOUT"); do
    grep -qE 'worldserver-daemon\) ready' "$log" 2>/dev/null && break
    pgrep -u "$(id -u)" -x worldserver >/dev/null || break
    sleep 1
done
sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E 'Applying update|Reapplying update|Applied [0-9]+ quer|up-to-date|Could not update|ERROR [0-9]+' || true
if ! grep -qE 'worldserver-daemon\) ready' "$log"; then
    echo "worldserver is not ready. Database backup: $backup"
    echo "Roll back: $0 --rollback ${current:-<previous-id>} --restore $backup"
    exit 1
fi
grep -q 'Reapplying update' "$log" && echo "WARNING: updates were re-applied, check the list above"

screen -dmS coa-auth "$ROOT/current/bin/authserver"
sleep 3
pgrep -u "$(id -u)" -x authserver >/dev/null || die "authserver did not start"
echo ">> $REL_ID is live (previous: ${current:-none})"

ls -1d "$ROOT"/releases/*/ | sort | head -n -"$KEEP" | while read -r old; do
    [[ "$(readlink -f "$ROOT/current")" == "$(readlink -f "$old")" ]] || rm -rf "$old"
done
