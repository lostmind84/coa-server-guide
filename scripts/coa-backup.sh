#!/usr/bin/env bash
# Create a backup set on the production host. Run as the service user (coa); needs ~/.my.cnf.
# Usage: coa-backup.sh hourly|daily|predeploy
#   hourly     acore_auth + acore_characters (irreplaceable player data), live configuration, manifest
#   daily      the same plus acore_world
#   predeploy  same as daily, taken by coa-deploy-release.sh before switching releases
# daily and predeploy also include acore_playerbots when it exists (mod-playerbots, see playerbots-prod.md).
# A set is /opt/coa/backups/<kind>/<UTC timestamp>/ with databases.sql.gz, etc.tar.gz, deploy.log, manifest.env
# and SHA256SUMS. It is written to <timestamp>.partial and renamed when complete; the path is printed on stdout.
# Only the newest sets are kept locally (COA_LOCAL_KEEP_*): the build server pulls them and sends them offsite.
set -euo pipefail

ROOT="${COA_PROD_ROOT:-/opt/coa}"
KIND="${1:-}"

die() { echo "error: $*" >&2; exit 1; }

case "$KIND" in
    hourly)             DATABASES=(acore_auth acore_characters); KEEP="${COA_LOCAL_KEEP_HOURLY:-24}" ;;
    daily)              DATABASES=(acore_auth acore_characters acore_world); KEEP="${COA_LOCAL_KEEP_DAILY:-2}" ;;
    predeploy)          DATABASES=(acore_auth acore_characters acore_world); KEEP="${COA_LOCAL_KEEP_PREDEPLOY:-2}" ;;
    *)                  die "usage: $0 hourly|daily|predeploy" ;;
esac
if [[ "$KIND" != hourly && -n "$(mysql -N -B -e "SHOW DATABASES LIKE 'acore_playerbots'")" ]]; then
    DATABASES+=(acore_playerbots)
fi

exec 9>"$ROOT/backups/.lock"
flock -w 600 9 || die "another backup is still running"

umask 077
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dir="$ROOT/backups/$KIND/$stamp"
mkdir -p "$dir.partial"
trap 'rm -rf "$dir.partial"' EXIT

mysqldump --single-transaction --no-tablespaces --routines --events --add-drop-database \
    --databases "${DATABASES[@]}" | gzip > "$dir.partial/databases.sql.gz"
tar -czf "$dir.partial/etc.tar.gz" -C "$ROOT" etc
[[ -f "$ROOT/deploy.log" ]] && cp "$ROOT/deploy.log" "$dir.partial/"

release_id=""
revision=""
data_version=""
if [[ -f "$ROOT/current/release.env" ]]; then
    release_id="$(sed -n 's/^RELEASE_ID=//p' "$ROOT/current/release.env")"
    revision="$(sed -n 's/^REVISION=//p' "$ROOT/current/release.env")"
    data_version="$(sed -n 's/^DATA_VERSION=//p' "$ROOT/current/release.env")"
fi
cat > "$dir.partial/manifest.env" <<EOF
KIND=$KIND
CREATED_AT=$stamp
HOST=$(hostname)
DATABASES="${DATABASES[*]}"
RELEASE_ID=$release_id
REVISION=$revision
DATA_VERSION=$data_version
ACCOUNTS=$(mysql -N -B -e 'SELECT COUNT(*) FROM acore_auth.account')
CHARACTERS=$(mysql -N -B -e 'SELECT COUNT(*) FROM acore_characters.characters')
REALM_ADDRESS=$(mysql -N -B -e 'SELECT CONCAT(address, ":", port) FROM acore_auth.realmlist WHERE id = 1')
EOF

zcat "$dir.partial/databases.sql.gz" | tail -n 1 | grep -q '^-- Dump completed' || die "dump is incomplete"
(cd "$dir.partial" && sha256sum databases.sql.gz etc.tar.gz manifest.env $([[ -f deploy.log ]] && echo deploy.log) > SHA256SUMS)
mv "$dir.partial" "$dir"
trap - EXIT

ls -1d "$ROOT/backups/$KIND"/*/ 2>/dev/null | grep -v '\.partial/$' | sort | head -n -"$KEEP" | xargs -r rm -rf
echo "$dir"
