#!/usr/bin/env bash
# Build a CoA server release for the production host (Ubuntu 26.04) inside a coa-builder:26.04 container.
# Usage: coa-build-release.sh [git-ref]        (default: origin/main)
# Layout under COA_BUILD_ROOT (default /srv/coa-build): src/ (git clone), build/ (cmake cache, kept for incremental
# builds), stage/ (temporary), releases/<id>/ (output), DATA_VERSION (client data version the release expects).
# RELEASE.md compares with releases/shipped, the last release sent to production (set by coa-ship-release.sh).
set -euo pipefail

ROOT="${COA_BUILD_ROOT:-/srv/coa-build}"
IMAGE="${COA_BUILDER_IMAGE:-coa-builder:26.04}"
REF="${1:-origin/main}"
SRC="$ROOT/src"
BUILD="$ROOT/build"
STAGE="$ROOT/stage"
OUT="$ROOT/releases"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "$SRC/.git" ]] || die "$SRC is not a git clone"
[[ -s "$ROOT/DATA_VERSION" ]] || die "$ROOT/DATA_VERSION missing (client data version, e.g. repack release id)"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE missing (docker build -t $IMAGE builder/)"

git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet --detach "$REF"
REV="$(git -C "$SRC" rev-parse HEAD)"
ID="$(date -u +%Y%m%d-%H%M)-${REV:0:7}"
DATA_VERSION="$(head -n1 "$ROOT/DATA_VERSION")"

PREV_ID=""
PREV_REV=""
if [[ -L "$OUT/shipped" ]]; then
    PREV_ID="$(basename "$(readlink -f "$OUT/shipped")")"
    PREV_REV="$(sed -n 's/^REVISION=//p' "$OUT/shipped/release.env")"
fi

echo ">> building $REV as release $ID"
rm -rf "$STAGE"
mkdir -p "$BUILD" "$STAGE" "$OUT"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$SRC:/src:ro" -v "$BUILD:/build" -v "$STAGE:/stage" "$IMAGE" bash -ec '
    git config --global --add safe.directory /src
    cmake -S /src -B /build \
        -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_WARNINGS=1 -DTOOLS_BUILD=none \
        -DSCRIPTS=static -DMODULES=static \
        -DCMAKE_INSTALL_PREFIX=/opt/coa/current -DCONF_DIR=/opt/coa/etc > /build/cmake.log 2>&1 || { tail -30 /build/cmake.log; exit 1; }
    make -C /build -j"$(nproc)" > /build/make.log 2>&1 || { grep -m20 -E "error" /build/make.log; exit 1; }
    make -C /build install DESTDIR=/stage > /build/install.log 2>&1'

R="$OUT/$ID.partial"
rm -rf "$R"
mkdir -p "$R/bin" "$R/etc" "$R/source/data" "$R/source/modules"
cp -a "$STAGE/opt/coa/current/bin/." "$R/bin/"
cp -a "$STAGE/opt/coa/etc/." "$R/etc/"
rsync -a --exclude '/old/' "$SRC/data/sql" "$R/source/data/"
for dir in "$SRC"/modules/*/data/sql; do
    module="$(basename "$(dirname "$(dirname "$dir")")")"
    mkdir -p "$R/source/modules/$module/data"
    rsync -a "$dir" "$R/source/modules/$module/data/"
done

cat > "$R/release.env" <<EOF
RELEASE_ID=$ID
REVISION=$REV
PREVIOUS_RELEASE_ID=$PREV_ID
PREVIOUS_REVISION=$PREV_REV
BUILD_IMAGE=$IMAGE
BUILD_OS=ubuntu-26.04
DATA_VERSION=$DATA_VERSION
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

sql_changes() {
    git -C "$SRC" diff --name-status -M "$PREV_REV" "$REV" -- \
        'data/sql/updates/*.sql' 'data/sql/archive/*.sql' 'data/sql/custom/*.sql' 'modules/*/data/sql/db-*/*.sql' \
        | awk -v want="$1" -F'\t' '
            want == "new"      && $1 == "A"                 { print "- `" $2 "`" }
            want == "modified" && $1 == "M"                 { print "- `" $2 "`" }
            want == "modified" && $1 ~ /^R/ && $1 != "R100" { print "- `" $3 "` (moved from `" $2 "`)" }
            want == "moved"    && $1 == "R100"              { print "- `" $2 "` -> `" $3 "`" }
            want == "removed"  && $1 == "D"                 { print "- `" $2 "`" }'
}

conf_keys() {
    find "$1" -name '*.conf.dist' -printf '%P\n' | sort | while read -r f; do
        grep -E '^[A-Za-z][A-Za-z0-9._]* *=' "$1/$f" | sed "s| *=.*||; s|^|$f: |"
    done | sort -u
}

{
    echo "# Release $ID"
    echo
    echo "- Revision: \`$REV\`"
    echo "- Previous release: ${PREV_ID:-none (first release)}"
    echo "- Client data version expected: \`$DATA_VERSION\`"
    if [[ -n "$PREV_ID" ]]; then
        prev_data="$(sed -n 's/^DATA_VERSION=//p' "$OUT/$PREV_ID/release.env")"
        [[ "$prev_data" != "$DATA_VERSION" ]] && echo "- **Client data changed** (\`$prev_data\` -> \`$DATA_VERSION\`): ship and install it before deploying"
    fi
    echo
    if [[ -n "$PREV_REV" ]]; then
        echo "## Commits"
        echo
        git -C "$SRC" log --no-merges --format='- %h %s' "$PREV_REV..$REV"
        echo
        echo "## New SQL updates (applied by worldserver at startup)"
        echo
        sql_changes new
        echo
        modified="$(sql_changes modified)"
        if [[ -n "$modified" ]]; then
            echo "## WARNING: modified SQL updates"
            echo
            echo "These files already existed. If the production database applied them, worldserver will re-apply them"
            echo "(\"Reapplying update ... (it changed)\"). Check they are safe to run twice before deploying."
            echo
            echo "$modified"
            echo
        fi
        moved="$(sql_changes moved)"
        if [[ -n "$moved" ]]; then
            echo "## Moved SQL updates (unchanged content, not re-applied)"
            echo
            echo "$moved"
            echo
        fi
        deleted="$(sql_changes removed)"
        if [[ -n "$deleted" ]]; then
            echo "## Removed SQL updates"
            echo
            echo "$deleted"
            echo
        fi
        echo "## Configuration keys"
        echo
        added="$(comm -13 <(conf_keys "$OUT/$PREV_ID/etc") <(conf_keys "$R/etc"))"
        removed="$(comm -23 <(conf_keys "$OUT/$PREV_ID/etc") <(conf_keys "$R/etc"))"
        echo "Added (copy them from the .conf.dist into the live .conf if the default is not wanted):"
        echo
        [[ -n "$added" ]] && sed 's/^/- /' <<<"$added" || echo "- none"
        echo
        echo "Removed:"
        echo
        [[ -n "$removed" ]] && sed 's/^/- /' <<<"$removed" || echo "- none"
    else
        echo "First release: install the production host first (prod-server.md, first installation)."
    fi
} > "$R/RELEASE.md"

(cd "$R" && find . -type f ! -name SHA256SUMS -printf '%P\0' | sort -z | xargs -0 sha256sum > SHA256SUMS)
mv "$R" "$OUT/$ID"
ln -sfn "$ID" "$OUT/latest"
rm -rf "$STAGE"
echo ">> release ready: $OUT/$ID"
