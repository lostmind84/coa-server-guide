#!/usr/bin/env bash
# Set up a Conquest of AzerothCore (CoA) server with Docker, using the data and
# database dump of a CoA repack. Automates steps 8 to 11 of the guide (README.md).
#
# Safe to re-run: existing files are kept, an existing world database is never
# overwritten, and already running servers are not restarted.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: setup-coa-server.sh --repo DIR --repack DIR [--root DIR] [--skip-build]

  --repo DIR     azerothcore-wotlk-coa checkout (contains docker-compose.yml)
  --repack DIR   extracted CoA-Repack folder (contains Data/ and Database/Clean/)
  --root DIR     server data root, must exist and be writable (default: /srv/coa)
  --skip-build   do not run "docker compose build"
  -h, --help     show this help
EOF
}

REPO=""
REPACK=""
COA_ROOT="/srv/coa"
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs a directory}"; shift 2 ;;
        --repack) REPACK="${2:?--repack needs a directory}"; shift 2 ;;
        --root) COA_ROOT="${2:?--root needs a directory}"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Run the MySQL client inside ac-database; the root password never leaves the container.
db() {
    docker compose exec -T ac-database sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"' sh "$@" \
        2> >(grep -v "Using a password on the command line" >&2)
}

container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

# ---------------------------------------------------------------------------
step "Preflight checks"
[[ -n "$REPO" && -n "$REPACK" ]] || { usage >&2; exit 2; }
for cmd in docker openssl zcat sha1sum sha256sum sed grep; do
    command -v "$cmd" >/dev/null || die "missing command: $cmd"
done
docker compose version >/dev/null || die "the docker compose plugin is required"

REPO="$(cd "$REPO" && pwd)"
REPACK="$(cd "$REPACK" && pwd)"
DUMP="$REPACK/Database/Clean/databases.sql.gz"
[[ -f "$REPO/docker-compose.yml" && -f "$REPO/conf/dist/env.ac" ]] || die "$REPO is not an azerothcore-wotlk-coa checkout"
[[ -f "$DUMP" && -f "$REPACK/Database/Clean/snapshot.json" ]] || die "database dump not found in $REPACK/Database/Clean"
[[ -f "$REPACK/Data/dbc/Ascension/Appearances.dbc" ]] || die "server data not found in $REPACK/Data"
[[ -d "$COA_ROOT" && -w "$COA_ROOT" ]] || die "$COA_ROOT must exist and be writable, e.g.: sudo mkdir -p $COA_ROOT && sudo chown $(id -u):$(id -g) $COA_ROOT"

expected=$(grep -oE '"gzipSHA256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' "$REPACK/Database/Clean/snapshot.json" | grep -oE '[0-9a-f]{64}')
actual=$(sha256sum "$DUMP" | cut -c1-64)
[[ "$expected" == "$actual" ]] || die "database dump checksum does not match snapshot.json"
info "repack dump checksum OK"

[[ "$(id -u)" == "1000" ]] || info "WARNING: uid $(id -u) != 1000; DOCKER_USER_ID/DOCKER_GROUP_ID in .env must match the owner of $COA_ROOT"

cd "$REPO"

# ---------------------------------------------------------------------------
step "Directory layout in $COA_ROOT"
mkdir -p "$COA_ROOT"/{etc/modules,logs,backups,server-data}

step "Docker Compose settings ($REPO/.env)"
if [[ -e .env ]]; then
    info "kept existing .env"
else
    (
        umask 077
        cat > .env <<EOF
DOCKER_DB_ROOT_PASSWORD=$(openssl rand -hex 16)
DOCKER_DB_EXTERNAL_PORT=127.0.0.1:3306
DOCKER_AUTH_EXTERNAL_PORT=127.0.0.1:3724
DOCKER_WORLD_EXTERNAL_PORT=127.0.0.1:8085
DOCKER_SOAP_EXTERNAL_PORT=127.0.0.1:7878
DOCKER_VOL_ETC=$COA_ROOT/etc
DOCKER_VOL_LOGS=$COA_ROOT/logs
DOCKER_VOL_DATA=$COA_ROOT/server-data
DOCKER_AC_ENV_FILE=$COA_ROOT/coa.env
DOCKER_USER_ID=$(id -u)
DOCKER_GROUP_ID=$(id -g)
EOF
    )
    info "created .env with a random MySQL root password"
fi

step "Server settings ($COA_ROOT/coa.env)"
if [[ -e "$COA_ROOT/coa.env" ]]; then
    info "kept existing coa.env"
else
    {
        cat conf/dist/env.ac
        cat <<'EOF'

# CoA settings from the repack (Settings/*.template)
AC_ASCENSION_COMPAT_ALLOW_REMOTE_CLIENTS=1
AC_ASCENSION_MANASTORM_ENABLE=1
AC_PLAYER_START_CUSTOM_SPELLS=1
EOF
    } > "$COA_ROOT/coa.env"
    info "created coa.env"
fi

step "Server data ($COA_ROOT/server-data)"
if [[ -d "$COA_ROOT/server-data/dbc" ]]; then
    info "kept existing server data"
else
    cp -a "$REPACK/Data/." "$COA_ROOT/server-data/"
    info "copied repack Data ($(du -sh "$COA_ROOT/server-data" | cut -f1))"
fi
# ac-client-data-init skips its stock download when this version file matches (apps/installer).
echo "INSTALLED_VERSION=v20.0" > "$COA_ROOT/server-data/data-version"

if cmp -s "$REPACK/Data/dbc/Spell.dbc" "$COA_ROOT/server-data/dbc/Spell.dbc"; then
    info "WARNING: server-data/dbc is the repack copy; the worldserver needs the CoA client DBC set (#1498)."
    info "         Install it before starting: README step 8 (apps/coa-dbc/client_dbc.py extract --original)."
fi

step "Module configuration ($COA_ROOT/etc/modules)"
# worldserver loads <name>.conf only; the containers create no module .conf from .conf.dist.
for dist in modules/*/conf/*.conf.dist; do
    [[ -e "$dist" ]] || continue
    target="$COA_ROOT/etc/modules/$(basename "${dist%.dist}")"
    if [[ -e "$target" ]]; then
        info "kept $(basename "$target")"
    else
        cp "$dist" "$target"
        info "created $(basename "$target")"
    fi
done

# ---------------------------------------------------------------------------
if [[ "$SKIP_BUILD" == "1" ]]; then
    step "Build skipped (--skip-build)"
else
    step "Building images (long on the first run)"
    docker compose build 2>&1 | tee "$COA_ROOT/logs/build-$(date +%F-%H%M%S).log"
fi

step "Starting MySQL"
docker compose up -d ac-database
status=""
for _ in $(seq 1 60); do
    status=$(docker inspect -f '{{.State.Health.Status}}' ac-database 2>/dev/null || true)
    [[ "$status" == "healthy" ]] && break
    sleep 5
done
[[ "$status" == "healthy" ]] || die "ac-database did not become healthy"
info "ac-database is healthy"

step "Database import"
world_tables=$(db -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'acore_world'")
if [[ "$world_tables" != "0" ]]; then
    info "acore_world already has $world_tables tables: import skipped"
else
    info "importing $(basename "$DUMP") (auth, characters, world)"
    zcat "$DUMP" | db
    db -e "UPDATE acore_auth.realmlist SET port = 8085 WHERE id = 1"
    info "imported; realm port set to 8085"
fi

step "Converting Windows update hashes to Linux hashes"
# The repack was built on Windows, where the updater hashes CRLF files after converting
# them to LF. On Linux the raw bytes are hashed, and a different hash makes dbimport
# reapply the file. Only rows still holding the Windows hash are changed.
sql="SET @converted = 0;"
while IFS= read -r -d '' file; do
    name=$(basename "$file")
    [[ "$name" =~ ^[A-Za-z0-9_.-]+\.sql$ ]] || continue
    lf=$(sed 's/\r$//' "$file" | sha1sum | cut -c1-40 | tr 'a-f' 'A-F')
    raw=$(sha1sum < "$file" | cut -c1-40 | tr 'a-f' 'A-F')
    for schema in acore_auth acore_characters acore_world; do
        sql+="UPDATE $schema.updates SET hash = '$raw' WHERE name = '$name' AND hash = '$lf';"
        sql+="SET @converted = @converted + ROW_COUNT();"
    done
done < <(grep -rlZ $'\r' --include='*.sql' data/sql/updates data/sql/custom modules/*/data/sql 2>/dev/null || true)
converted=$(printf '%s SELECT @converted;' "$sql" | db -N)
info "$converted update hash(es) converted"

step "Applying pending SQL updates (dbimport)"
import_log="$COA_ROOT/logs/db-import-$(date +%F-%H%M%S).log"
docker compose up ac-db-import 2>&1 | tee "$import_log"
[[ "$(docker inspect -f '{{.State.ExitCode}}' ac-db-import)" == "0" ]] || die "dbimport failed, see $import_log"
if grep -q "Reapplying update" "$import_log"; then
    info "WARNING: dbimport reapplied at least one update, check $import_log"
fi

# ---------------------------------------------------------------------------
step "Starting authserver and worldserver"
if container_running ac-worldserver && container_running ac-authserver; then
    info "already running: not restarted"
else
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker compose up -d ac-authserver ac-worldserver
    ready=0
    for _ in $(seq 1 120); do
        if docker compose logs --no-color --since "$since" ac-worldserver 2>/dev/null \
            | grep -q "(worldserver-daemon) ready"; then
            ready=1
            break
        fi
        container_running ac-worldserver || die "ac-worldserver stopped, see: docker compose logs ac-worldserver"
        sleep 5
    done
    [[ "$ready" == "1" ]] || die "worldserver not ready after 10 minutes, see: docker compose logs ac-worldserver"
    sleep 5
    logs=$(docker compose logs --no-color --since "$since" ac-worldserver)
    grep -E "World Initialized|Loaded Ascension collection data" <<<"$logs" | sed 's/^/    /' || true
    if grep -qE "Unable to open Ascension DBC|Failed open" <<<"$logs"; then
        info "WARNING: missing DBC or configuration file, see: docker compose logs ac-worldserver"
    fi
fi

docker compose ps -a

cat <<EOF

Server is up. Next steps:
  1. Change the published password of the "local" GM account:
       docker compose attach ac-worldserver
       account set password local NEW_PASSWORD NEW_PASSWORD
     Detach with Ctrl+P then Ctrl+Q (Ctrl+C stops the server).
  2. Point the client's Data/enUS/realmlist.wtf to 127.0.0.1 and log in.
Never run "docker compose pull": it replaces the locally built images.
EOF
