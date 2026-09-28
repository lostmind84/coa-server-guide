#!/usr/bin/env bash
# Pull CoA backup sets (and the release they run on) from the production host, verify them and apply retention.
# Runs on the build server, which then uploads the sets offsite with coa-backup-push.sh (see docs/backup.md).
# Usage: coa-backup-pull.sh <config-file>        coa-backup-pull.sh <config-file> --status
# The production side is read through a read-only rrsync key rooted at /opt/coa, so remote paths are relative.
set -euo pipefail

CONFIG="${1:?usage: $0 <config-file> [--status]}"
# shellcheck disable=SC1090
source "$CONFIG"

: "${SOURCE:?SOURCE missing (e.g. coa-backup@prod.example)}"
: "${DEST:?DEST missing (e.g. /srv/coa-backup)}"
KINDS="${KINDS:-hourly daily predeploy}"
LATEST_ONLY="${LATEST_ONLY:-0}"
KEEP_HOURLY_HOURS="${KEEP_HOURLY_HOURS:-48}"
KEEP_DAILY_DAYS="${KEEP_DAILY_DAYS:-30}"
KEEP_WEEKLY_WEEKS="${KEEP_WEEKLY_WEEKS:-12}"
KEEP_PREDEPLOY="${KEEP_PREDEPLOY:-5}"
PULL_RELEASES="${PULL_RELEASES:-1}"
MAX_HOURLY_AGE_HOURS="${MAX_HOURLY_AGE_HOURS:-2}"

die() { echo "error: $*" >&2; exit 1; }
stamp_epoch() { date -u -d "$(sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$/\1-\2-\3 \4:\5:\6/' <<<"$1")" +%s; }
sets() { ls -1 "$DEST/$1" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort || true; }

status() {
    local newest age rc=0
    newest="$(sets hourly | tail -n 1)"
    if [[ -z "$newest" ]]; then
        echo "hourly: none"; rc=1
    else
        age=$(( ($(date -u +%s) - $(stamp_epoch "$newest")) / 3600 ))
        echo "hourly: newest $newest (${age}h old), $(sets hourly | wc -l) kept"
        (( age < MAX_HOURLY_AGE_HOURS )) || { echo "ALERT: newest hourly backup is older than ${MAX_HOURLY_AGE_HOURS}h"; rc=1; }
    fi
    for kind in daily predeploy; do
        echo "$kind: $(sets "$kind" | wc -l) kept, newest $(sets "$kind" | tail -n 1)"
    done
    if [[ -n "$(ls -A "$DEST/unverified" 2>/dev/null)" ]]; then
        ls -1 "$DEST/unverified" | sed 's/^/UNVERIFIED: /'; rc=1
    fi
    [[ -d "$DEST/releases" ]] && echo "releases: $(ls -1 "$DEST/releases" | tr '\n' ' ')"
    [[ -d "$DEST/data" ]] && echo "client data: $(ls -1 "$DEST/data" | tr '\n' ' ')"
    return $rc
}

if [[ "${2:-}" == "--status" ]]; then status; exit $?; fi

mkdir -p "$DEST"
exec 9>"$DEST/.lock"
flock -n 9 || die "another pull is running"

verify() {
    local set="$1"
    (cd "$set" && sha256sum --quiet -c SHA256SUMS) || return 1
    gzip -t "$set/databases.sql.gz" || return 1
    zcat "$set/databases.sql.gz" | tail -n 1 | grep -q '^-- Dump completed' || return 1
    tar -tzf "$set/etc.tar.gz" >/dev/null || return 1
}

for kind in $KINDS; do
    mkdir -p "$DEST/$kind"
    remote="$(rsync --list-only "$SOURCE:backups/$kind/" 2>/dev/null \
        | awk '$1 ~ /^d/ {print $NF}' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort || true)"
    [[ "$LATEST_ONLY" == 1 ]] && remote="$(tail -n 1 <<<"$remote")"
    for set in $remote; do
        [[ -d "$DEST/$kind/$set" ]] && continue
        rsync -a "$SOURCE:backups/$kind/$set/" "$DEST/$kind/$set.partial/"
        if verify "$DEST/$kind/$set.partial"; then
            mv "$DEST/$kind/$set.partial" "$DEST/$kind/$set"
            echo "pulled $kind/$set"
        else
            mkdir -p "$DEST/unverified"
            mv "$DEST/$kind/$set.partial" "$DEST/unverified/$kind-$set"
            echo "ALERT: $kind/$set failed verification, kept in $DEST/unverified" >&2
        fi
    done
done

now=$(date -u +%s)
for set in $(sets hourly); do
    (( now - $(stamp_epoch "$set") > KEEP_HOURLY_HOURS * 3600 )) && rm -rf "${DEST:?}/hourly/$set"
done
declare -A weekly_kept=()
for set in $(sets daily | sort -r); do
    age=$(( now - $(stamp_epoch "$set") ))
    (( age <= KEEP_DAILY_DAYS * 86400 )) && continue
    week="$(date -u -d "@$(stamp_epoch "$set")" +%G-%V)"
    if (( age <= KEEP_WEEKLY_WEEKS * 7 * 86400 )) && [[ -z "${weekly_kept[$week]:-}" ]]; then
        weekly_kept[$week]=1
        continue
    fi
    rm -rf "${DEST:?}/daily/$set"
done
sets predeploy | head -n -"$KEEP_PREDEPLOY" | while read -r set; do rm -rf "${DEST:?}/predeploy/$set"; done

if [[ "$PULL_RELEASES" == 1 ]]; then
    mkdir -p "$DEST/releases" "$DEST/data"
    needed_releases="$(cat "$DEST"/{hourly,daily,predeploy}/*/manifest.env 2>/dev/null | sed -n 's/^RELEASE_ID=//p' | sort -u || true)"
    needed_data="$(cat "$DEST"/{hourly,daily,predeploy}/*/manifest.env 2>/dev/null | sed -n 's/^DATA_VERSION=//p' | sort -u || true)"
    for id in $needed_releases; do
        [[ -f "$DEST/releases/$id/.complete" ]] && continue
        link_dest=()
        previous="$(ls -1 "$DEST/releases" | grep -v '\.partial$' | sort | tail -n 1 || true)"
        [[ -n "$previous" ]] && link_dest=(--link-dest="$DEST/releases/$previous")
        if rsync -a "${link_dest[@]}" "$SOURCE:releases/$id/" "$DEST/releases/$id.partial/" \
            && (cd "$DEST/releases/$id.partial" && sha256sum --quiet -c SHA256SUMS); then
            mv "$DEST/releases/$id.partial" "$DEST/releases/$id"
            echo "pulled release $id"
        else
            rm -rf "$DEST/releases/$id.partial"
            echo "ALERT: release $id could not be pulled (rebuild it from its REVISION if it is ever needed)" >&2
        fi
    done
    for version in $needed_data; do
        [[ -d "$DEST/data/$version/dbc" ]] && continue
        if rsync -a "$SOURCE:data/$version/" "$DEST/data/$version.partial/"; then
            mv "$DEST/data/$version.partial" "$DEST/data/$version"
            echo "pulled client data $version"
        else
            echo "ALERT: client data $version could not be pulled" >&2
        fi
    done
    for id in $(ls -1 "$DEST/releases"); do
        grep -qx "$id" <<<"$needed_releases" || { rm -rf "${DEST:?}/releases/$id"; echo "dropped release $id"; }
    done
    for version in $(ls -1 "$DEST/data"); do
        grep -qx "$version" <<<"$needed_data" || { rm -rf "${DEST:?}/data/$version"; echo "dropped client data $version"; }
    done
fi

date -u +%Y-%m-%dT%H:%M:%SZ > "$DEST/LAST_PULL"
status
