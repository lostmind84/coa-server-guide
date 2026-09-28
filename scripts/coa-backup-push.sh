#!/usr/bin/env bash
# Send verified backup sets from the build server to the offsite S3 bucket through an rclone crypt remote,
# with a GOVERNANCE object lock on every uploaded object. Runs after coa-backup-pull.sh, on the build server.
# Usage: coa-backup-push.sh <config-file>        coa-backup-push.sh <config-file> --status
# The bucket's lifecycle rules delete expired sets; this script never deletes anything remote.
# LOCK_* are GNU date offsets ("2 days", "15 minutes"): each object is locked until now + offset.
set -euo pipefail

CONFIG="${1:?usage: $0 <config-file> [--status]}"
# shellcheck disable=SC1090
source "$CONFIG"

: "${SETS:?SETS missing (local backup root written by coa-backup-pull.sh)}"
: "${REMOTE:?REMOTE missing (rclone crypt remote, e.g. coa-backups:)}"
RCLONE="${RCLONE:-rclone}"
LOCK_HOURLY="${LOCK_HOURLY:-2 days}"
LOCK_DAILY="${LOCK_DAILY:-30 days}"
LOCK_WEEKLY="${LOCK_WEEKLY:-84 days}"
LOCK_PREDEPLOY="${LOCK_PREDEPLOY:-90 days}"
LOCK_STATIC="${LOCK_STATIC:-365 days}"
STATIC_PATHS="${STATIC_PATHS:-}"
MAX_HOURLY_AGE_HOURS="${MAX_HOURLY_AGE_HOURS:-2}"
STATE="$SETS/.pushed"
FAILED=0

die() { echo "error: $*" >&2; exit 1; }
stamp_epoch() { date -u -d "$(sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$/\1-\2-\3 \4:\5:\6/' <<<"$1")" +%s; }
sets() { ls -1 "$SETS/$1" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort || true; }

status() {
    local newest age rc=0
    newest="$(ls -1 "$STATE" 2>/dev/null | sed -n 's/^hourly-//p' | sort | tail -n 1 || true)"
    if [[ -z "$newest" ]]; then
        echo "offsite hourly: none"; rc=1
    else
        age=$(( ($(date -u +%s) - $(stamp_epoch "$newest")) / 3600 ))
        echo "offsite hourly: newest $newest (${age}h old)"
        (( age < MAX_HOURLY_AGE_HOURS )) || { echo "ALERT: newest offsite hourly set is older than ${MAX_HOURLY_AGE_HOURS}h"; rc=1; }
    fi
    for kind in daily weekly predeploy static; do
        echo "offsite $kind: newest $(ls -1 "$STATE" 2>/dev/null | sed -n "s/^$kind-//p" | sort | tail -n 1 || true)"
    done
    return $rc
}

if [[ "${2:-}" == "--status" ]]; then status; exit $?; fi

mkdir -p "$STATE"
exec 9>"$STATE/.lock"
flock -n 9 || die "another push is running"

push() {
    local src="$1" dest="$2" until
    until="$(date -u -d "+$3" +%Y-%m-%dT%H:%M:%SZ)"
    "$RCLONE" copy "$src" "$REMOTE$dest" \
        --s3-object-lock-mode GOVERNANCE --s3-object-lock-retain-until-date "$until" --s3-object-lock-set-after-upload \
        && "$RCLONE" cryptcheck "$src" "$REMOTE$dest" --one-way
}

lock_for() {
    case "$1" in
        hourly) echo "$LOCK_HOURLY" ;;
        daily) echo "$LOCK_DAILY" ;;
        predeploy) echo "$LOCK_PREDEPLOY" ;;
    esac
}

for kind in hourly daily predeploy; do
    for set in $(sets "$kind"); do
        [[ -e "$STATE/$kind-$set" ]] && continue
        if push "$SETS/$kind/$set" "$kind/$set" "$(lock_for "$kind")"; then
            touch "$STATE/$kind-$set"
            echo "pushed $kind/$set"
        else
            echo "ALERT: push of $kind/$set failed" >&2
            FAILED=1
            continue
        fi
        if [[ "$kind" == daily && "$(date -u -d "@$(stamp_epoch "$set")" +%u)" == 7 && ! -e "$STATE/weekly-$set" ]]; then
            push "$SETS/daily/$set" "weekly/$set" "$LOCK_WEEKLY" && touch "$STATE/weekly-$set" && echo "pushed weekly/$set" \
                || { echo "ALERT: push of weekly/$set failed" >&2; FAILED=1; }
        fi
    done
done

for path in $STATIC_PATHS; do
    name="$(basename "$path")"
    [[ -e "$STATE/static-$name" ]] && continue
    [[ -d "$path" ]] || { echo "ALERT: static folder $path not found" >&2; FAILED=1; continue; }
    if push "$path" "static/$name" "$LOCK_STATIC"; then
        touch "$STATE/static-$name"
        echo "pushed static/$name"
    else
        echo "ALERT: push of static/$name failed" >&2
        FAILED=1
    fi
done

for marker in $(ls -1 "$STATE"); do
    kind="${marker%%-*}"
    set="${marker#*-}"
    [[ "$kind" == hourly || "$kind" == daily || "$kind" == predeploy ]] || continue
    [[ -d "$SETS/$kind/$set" ]] || rm -f "$STATE/$marker"
done

status || FAILED=1
exit "$FAILED"
