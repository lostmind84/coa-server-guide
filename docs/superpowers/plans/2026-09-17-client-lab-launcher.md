# Client Lab Launcher (Milestone 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `coa-client-lab` command that creates a separate lab copy of the CoA client, runs it in nested
gamescope on its own Hyprland workspace against a `coa-slot` server, drives it by keyboard, takes screenshots,
stops it cleanly and runs the preflight against the lab client.

**Architecture:** One bash script in `scripts/`, modelled on `scripts/coa-slot` (usage text, `die`, one
`cmd_*` function per command, `main` dispatcher). State lives in `~/CoaServer/client-lab/state`. External
programs (`hyprctl`, `xdotool`, `magick`, `coa-slot`, `gamescope`) are called by name, so a bash test script puts
fakes first on `PATH` and exercises every command without a real client. A final task runs the real client.

**Tech Stack:** bash, gamescope 3.16.28, Hyprland 0.56 (`hyprctl eval` + Lua `hl.exec_cmd`), xdotool,
ImageMagick `magick import`, umu-run / GE-Proton, `coa-slot`, `coa-preflight.py`.

**Spec:** `docs/superpowers/specs/2026-09-17-client-issue-agent-design.md` (component 2, "Launcher") and
`docs/superpowers/specs/2026-09-17-client-issue-agent-spike-findings.md` (every command form below comes from it).

## Global Constraints

- The user's client (`~/CoaServer/client/ascension-live`) and prefix (`~/Games/umu/coa-client`) are never
  modified. Only `create` reads them.
- Never stop processes with `pkill -f <pattern>`: during the spike it killed the calling shell. Stop by PID.
- Keyboard input only inside gamescope; mouse clicks are unreliable (findings Q2). The single exception is the
  login field click proven in the spike.
- Lab client resolution: `gxResolution "1920x1080"`, gamescope `-W 1920 -H 1080 -w 1920 -h 1080`.
- Launch form (Hyprland 0.56 Lua config): `hyprctl eval "hl.exec_cmd([[<cmd>]], { workspace = \"<N> silent\" })"`.
- One lab client at a time: a lock file; a held lock means wait or give up, never take over.
- Repository text (code, comments, docs, commits) is English. `README.md` and `README.fr.md` stay in sync.
- Style: 4-space indent, `set -euo pipefail`, same helpers and layout as `scripts/coa-slot`.
- Conventional Commits; no session links or `Claude-Session` trailers in commits.
- Code navigation: use Serena's symbolic tools where its language server supports the file; bash files in this
  repository fall back to Read/Edit.
- No `shellcheck` is installed: syntax checks use `bash -n`.

## File Structure

| Path | Role |
|---|---|
| `scripts/coa-client-lab` | the launcher (create, destroy, start, login, type, key, chat, screenshot, stop, status, preflight) |
| `scripts/tests/coa-client-lab.test.sh` | bash test script with fake `hyprctl`, `xdotool`, `magick`, `coa-slot`, `gamescope` |
| `README.md`, `README.fr.md` | new section "Client lab for agents" / "Client de labo pour les agents" |
| `docs/superpowers/specs/2026-09-17-client-issue-agent-design.md` | Milestone 1 marked done |

Environment overrides (used by the tests, also useful by hand): `COA_USER_CLIENT`, `COA_USER_PREFIX`,
`COA_LAB_ROOT`, `COA_LAB_PREFIX`, `COA_PROTONPATH`, `COA_LAB_WORKSPACE`, `COA_LAB_WINDOW_TIMEOUT`, `COA_LAB_SLEEP`.

---

### Task 1: Test harness, `create` and `destroy`

**Files:**
- Create: `scripts/tests/coa-client-lab.test.sh`
- Create: `scripts/coa-client-lab`

**Interfaces:**
- Produces: `coa-client-lab create`, `coa-client-lab destroy --yes`; variables `USER_CLIENT`, `USER_PREFIX`,
  `LAB_ROOT`, `LAB_CLIENT`, `LAB_PREFIX`, `STATE_DIR`, `LOCK`; helpers `die`, `step`, `set_wtf <file> <key>
  <value>`; test helpers `assert_eq`, `assert_file`, `assert_absent`, `assert_contains`, `run_lab`.

- [ ] **Step 1: Write the test harness and the create/destroy tests**

`scripts/tests/coa-client-lab.test.sh`:
```bash
#!/usr/bin/env bash
# Tests for scripts/coa-client-lab with fake hyprctl, xdotool, magick, coa-slot and gamescope.
# The work directory is under ~/.cache because `create` needs a filesystem with reflink support (btrfs here).
# No `set -e`: a failing command must be reported by an assertion, not abort the run.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/coa-client-lab"
WORK="$(mktemp -d "$HOME/.cache/coa-client-lab-test.XXXXXX")"
FAILURES=0
cleanup() {
    local pid
    pid=$(cat "$WORK/lab/state/gamescope.pid" 2>/dev/null) || pid=""
    if [[ -n "$pid" ]]; then
        pkill -P "$pid" 2>/dev/null
        kill "$pid" 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

export COA_USER_CLIENT="$WORK/user/ascension-live"
export COA_USER_PREFIX="$WORK/user/prefix"
export COA_LAB_ROOT="$WORK/lab"
export COA_LAB_PREFIX="$WORK/lab-prefix"
export COA_PROTONPATH="$WORK/proton"
export COA_LAB_WINDOW_TIMEOUT=10
export COA_LAB_SLEEP=true
export FAKE_LOG="$WORK/fake.log"

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1: expected [$3], got [$2]"; }
assert_file() { [[ -e "$2" ]] && pass "$1" || fail "$1: missing $2"; }
assert_absent() { [[ ! -e "$2" ]] && pass "$1" || fail "$1: still present $2"; }
assert_contains() { grep -qF -- "$3" "$2" 2>/dev/null && pass "$1" || fail "$1: [$3] not in $2"; }
run_lab() { "$SCRIPT" "$@" > "$WORK/out" 2>&1; }

make_user_client() {
    mkdir -p "$COA_USER_CLIENT"/{Data/enUS,WTF/Account/LOCAL,WTF/Custom,Cache,Interface/AddOns} "$COA_USER_PREFIX"
    touch "$COA_USER_CLIENT/Ascension.exe" "$COA_USER_CLIENT/WTF/Account/LOCAL/SavedVariables.lua" \
        "$COA_USER_CLIENT/WTF/Custom/GlueConfig.json" "$COA_USER_CLIENT/Cache/wdb" "$COA_USER_PREFIX/system.reg"
    printf 'set realmlist 127.0.0.1:3824\r\n' > "$COA_USER_CLIENT/Data/enUS/realmlist.wtf"
    printf 'SET realmList "127.0.0.1:3824"\nSET gxResolution "800x600"\n' > "$COA_USER_CLIENT/WTF/Config.wtf"
    cp "$COA_USER_CLIENT/WTF/Config.wtf" "$WORK/user-config-before.wtf"
}

make_fakes() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf 'hyprctl %s\n' "$*" >> "$FAKE_LOG"
if [[ "$1" == eval ]]; then
    cmd=$(sed -n 's/^hl\.exec_cmd(\[\[\(.*\)\]\], .*/\1/p' <<< "$2")
    setsid bash -c "$cmd" > /dev/null 2>&1 &
fi
echo ok
EOF
    cat > "$WORK/bin/gamescope" <<'EOF'
#!/usr/bin/env bash
DISPLAY=:77 bash -c "exec -a 'X:\\lab\\Ascension.exe' sleep 600" &
wait
EOF
    cat > "$WORK/bin/xdotool" <<'EOF'
#!/usr/bin/env bash
printf 'xdotool DISPLAY=%s %s\n' "$DISPLAY" "$*" >> "$FAKE_LOG"
case "$1" in
    search) echo 4242 ;;
    getwindowgeometry) printf 'WINDOW=4242\nX=0\nY=0\nWIDTH=1920\nHEIGHT=1080\nSCREEN=0\n' ;;
esac
EOF
    cat > "$WORK/bin/magick" <<'EOF'
#!/usr/bin/env bash
printf 'magick DISPLAY=%s %s\n' "$DISPLAY" "$*" >> "$FAKE_LOG"
touch "${@: -1}"
EOF
    cat > "$WORK/bin/coa-slot" <<'EOF'
#!/usr/bin/env bash
printf 'coa-slot %s\n' "$*" >> "$FAKE_LOG"
[[ "$1" == env ]] && printf 'SLOT=%s\nAUTH_ADDR=127.0.0.1:3924\n' "$2"
exit 0
EOF
    cat > "$WORK/bin/umu-run" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$WORK/bin"/*
    export PATH="$WORK/bin:$PATH"
}

make_user_client
make_fakes

# create
run_lab create
assert_eq "create exits 0" "$?" "0"
assert_file "lab client copied" "$COA_LAB_ROOT/ascension-lab/Ascension.exe"
assert_file "lab prefix copied" "$COA_LAB_PREFIX/system.reg"
assert_absent "user accounts dropped" "$COA_LAB_ROOT/ascension-lab/WTF/Account"
assert_absent "glue config dropped" "$COA_LAB_ROOT/ascension-lab/WTF/Custom"
assert_absent "cache dropped" "$COA_LAB_ROOT/ascension-lab/Cache"
assert_contains "lab resolution" "$COA_LAB_ROOT/ascension-lab/WTF/Config.wtf" 'SET gxResolution "1920x1080"'
cmp -s "$COA_USER_CLIENT/WTF/Config.wtf" "$WORK/user-config-before.wtf" \
    && pass "user Config.wtf unchanged" || fail "user Config.wtf changed"

if run_lab create; then fail "second create refused"; else pass "second create refused"; fi
assert_contains "second create message" "$WORK/out" "already exists"

# destroy
if run_lab destroy; then fail "destroy without --yes refused"; else pass "destroy without --yes refused"; fi
run_lab destroy --yes
assert_absent "lab client removed" "$COA_LAB_ROOT"
assert_absent "lab prefix removed" "$COA_LAB_PREFIX"
assert_file "user client kept" "$COA_USER_CLIENT/Ascension.exe"
run_lab create

# LAUNCH TESTS (Task 2)

# INPUT TESTS (Task 3)

# STOP TESTS (Task 4)

printf '\n%s failure(s)\n' "$FAILURES"
exit $((FAILURES > 0))
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `chmod +x scripts/tests/coa-client-lab.test.sh && scripts/tests/coa-client-lab.test.sh`
Expected: FAIL lines (the script does not exist yet; `run_lab` fails with "No such file or directory").

- [ ] **Step 3: Write the script with `create` and `destroy`**

`scripts/coa-client-lab`:
```bash
#!/usr/bin/env bash
# Run a lab copy of the CoA client for agents: nested gamescope on its own Hyprland workspace, keyboard input
# and screenshots through gamescope's X display, one lab client at a time. The user's client is never modified;
# it is only read by `create`. Design: docs/superpowers/specs/2026-09-17-client-issue-agent-design.md.
set -euo pipefail

USER_CLIENT="${COA_USER_CLIENT:-$HOME/CoaServer/client/ascension-live}"
USER_PREFIX="${COA_USER_PREFIX:-$HOME/Games/umu/coa-client}"
LAB_ROOT="${COA_LAB_ROOT:-$HOME/CoaServer/client-lab}"
LAB_CLIENT="$LAB_ROOT/ascension-lab"
LAB_PREFIX="${COA_LAB_PREFIX:-$HOME/Games/umu/coa-client-lab}"
PROTON="${COA_PROTONPATH:-$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton11-6-x86_64}"
WORKSPACE="${COA_LAB_WORKSPACE:-9}"
WINDOW_TIMEOUT="${COA_LAB_WINDOW_TIMEOUT:-120}"
SLEEP="${COA_LAB_SLEEP:-sleep}"
WIDTH=1920
HEIGHT=1080
STATE_DIR="$LAB_ROOT/state"
LOCK="$STATE_DIR/lock"

usage() {
    cat <<'EOF'
Usage: coa-client-lab <command> [arguments]

Lab copy:
  create                   reflink-copy the user's client and Wine prefix, drop accounts, glue config and cache,
                           set 1920x1080
  destroy --yes            remove the lab client and prefix (refused while the lab client runs)

Running (one lab client at a time):
  start N                  point the lab client at slot N's authserver and launch it on the lab workspace
  login ACCOUNT PASSWORD   keyboard login and world entry; check the result with a screenshot
  type TEXT                type text into the client
  key KEY...               send keys (xdotool names: Return, Tab, Escape, BackSpace...)
  chat TEXT                Return, type TEXT, Return (slash commands, /say...)
  screenshot [PATH]        save a PNG of the client window and print its path
  stop                     stop the lab client by PID, release the lock, warn if the user's client changed
  status                   lock holder, process, display and window
  preflight N              coa-slot preflight N against the lab client's data
EOF
}

step() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Replace `SET key "value"` in a WTF file, or append it.
set_wtf() {
    local file="$1" key="$2" value="$3"
    if grep -qi "^SET $key " "$file"; then
        sed -i "s|^SET $key .*|SET $key \"$value\"|I" "$file"
    else
        printf 'SET %s "%s"\n' "$key" "$value" >> "$file"
    fi
}

cmd_create() {
    [[ -e "$LAB_CLIENT" || -e "$LAB_PREFIX" ]] && die "lab already exists: $LAB_CLIENT or $LAB_PREFIX"
    [[ -f "$USER_CLIENT/Ascension.exe" ]] || die "Ascension.exe not found in $USER_CLIENT"
    [[ -d "$USER_PREFIX" ]] || die "Wine prefix not found: $USER_PREFIX"
    mkdir -p "$LAB_ROOT" "$(dirname "$LAB_PREFIX")"
    step "Copying the client and its prefix (reflink: shared blocks, no full copy)"
    cp -a --reflink=always "$USER_CLIENT" "$LAB_CLIENT" || die "reflink copy failed (needs btrfs or xfs)"
    cp -a --reflink=always "$USER_PREFIX" "$LAB_PREFIX" || die "reflink copy failed (needs btrfs or xfs)"
    # The user's remembered account, characters, addon settings and caches stay out of the lab.
    rm -rf "$LAB_CLIENT/WTF/Account" "$LAB_CLIENT/WTF/Custom" "$LAB_CLIENT/Cache" "$LAB_CLIENT/Screenshots"
    set_wtf "$LAB_CLIENT/WTF/Config.wtf" gxResolution "${WIDTH}x${HEIGHT}"
    echo "lab created: $LAB_CLIENT"
}

cmd_destroy() {
    [[ "${1:-}" == --yes ]] || die "usage: coa-client-lab destroy --yes"
    [[ -e "$LOCK" ]] && die "the lab client is running or its lock is stale: coa-client-lab stop"
    [[ "$LAB_CLIENT" != "$USER_CLIENT" && "$LAB_PREFIX" != "$USER_PREFIX" ]] || die "lab paths equal user paths"
    rm -rf "$LAB_ROOT" "$LAB_PREFIX"
    echo "lab removed"
}

main() {
    local command="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "$command" in
        create) cmd_create ;;
        destroy) cmd_destroy "$@" ;;
        -h|--help|help|"") usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"; exit $?  # same line: an edit of this file cannot run half-read commands in a running copy
```
`chmod +x scripts/coa-client-lab`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `bash -n scripts/coa-client-lab && scripts/tests/coa-client-lab.test.sh`
Expected: every line `ok`, `0 failure(s)`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/coa-client-lab scripts/tests/coa-client-lab.test.sh
git commit -m "feat(client-lab): create and destroy a lab copy of the client"
```

---

### Task 2: `start`, `status` and the lock

**Files:**
- Modify: `scripts/coa-client-lab`
- Modify: `scripts/tests/coa-client-lab.test.sh` (replace the `# LAUNCH TESTS (Task 2)` line)

**Interfaces:**
- Consumes: `set_wtf`, `die`, `step`, `LOCK`, `STATE_DIR` from Task 1.
- Produces: `coa-client-lab start N`, `coa-client-lab status`; state files `$STATE_DIR/lock` (text
  `slot N since <date>`), `$STATE_DIR/gamescope.pid`, `$STATE_DIR/display`, `$STATE_DIR/window`,
  `$STATE_DIR/started` (timestamp file), `$STATE_DIR/client.log`; helpers `descendants <pid>`,
  `gamescope_pid` (prints PID or fails), `require_running`.

- [ ] **Step 1: Write the failing tests**

Replace `# LAUNCH TESTS (Task 2)` with:
```bash
run_lab start 3
assert_eq "start exits 0" "$?" "0"
assert_contains "lab realmList" "$COA_LAB_ROOT/ascension-lab/WTF/Config.wtf" 'SET realmList "127.0.0.1:3924"'
assert_contains "lab realmlist.wtf" "$COA_LAB_ROOT/ascension-lab/Data/enUS/realmlist.wtf" "set realmlist 127.0.0.1:3924"
assert_contains "user realmList untouched" "$COA_USER_CLIENT/WTF/Config.wtf" 'SET realmList "127.0.0.1:3824"'
assert_contains "launched on workspace 9" "$FAKE_LOG" 'workspace = "9 silent"'
assert_contains "gamescope size" "$FAKE_LOG" "gamescope -W 1920 -H 1080 -w 1920 -h 1080"
assert_contains "lock holder" "$COA_LAB_ROOT/state/lock" "slot 3"
assert_eq "display recorded" "$(cat "$COA_LAB_ROOT/state/display")" ":77"
assert_eq "window recorded" "$(cat "$COA_LAB_ROOT/state/window")" "4242"

if run_lab start 2; then fail "second start refused"; else pass "second start refused"; fi
assert_contains "second start names holder" "$WORK/out" "slot 3"

run_lab status
assert_contains "status shows display" "$WORK/out" "display: :77"
assert_contains "status shows running" "$WORK/out" "running"
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `scripts/tests/coa-client-lab.test.sh`
Expected: the Task 1 lines `ok`; `start exits 0` and following lines FAIL (unknown command, exit 2).

- [ ] **Step 3: Implement `start` and `status`**

Add after `cmd_destroy`:
```bash
descendants() {
    local child
    for child in $(pgrep -P "$1" || true); do
        echo "$child"
        descendants "$child"
    done
}

gamescope_pid() {
    local pid
    pid=$(cat "$STATE_DIR/gamescope.pid" 2>/dev/null) || return 1
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

# gamescope's Xwayland display, read from the environment of a process gamescope started.
find_display() {
    local pid value
    for pid in $(descendants "$1"); do
        value=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^DISPLAY=//p' | head -1)
        [[ -n "$value" ]] && { echo "$value"; return 0; }
    done
    return 1
}

require_running() {
    [[ -e "$LOCK" ]] || die "the lab client is not running: coa-client-lab start N"
    gamescope_pid > /dev/null || die "lock present but gamescope is gone: coa-client-lab stop"
    DISPLAY=$(cat "$STATE_DIR/display")
    WINDOW=$(cat "$STATE_DIR/window")
    export DISPLAY
}

cmd_start() {
    local n="${1:-}" auth pid display window waited
    [[ "$n" =~ ^[123]$ ]] || die "usage: coa-client-lab start N (slot 1, 2 or 3)"
    [[ -f "$LAB_CLIENT/Ascension.exe" ]] || die "no lab client: coa-client-lab create"
    # Paths go inside a Lua long string and a single-quoted bash -c: refuse characters that would break them.
    [[ "$LAB_CLIENT$LAB_PREFIX$PROTON$STATE_DIR" != *[[:space:]\'\]]* ]] || die "lab paths contain spaces, quotes or ]"
    auth=$(coa-slot env "$n" | sed -n 's/^AUTH_ADDR=//p')
    [[ -n "$auth" ]] || die "coa-slot env $n gave no AUTH_ADDR"
    mkdir -p "$STATE_DIR"
    if ! (set -o noclobber; echo "slot $n since $(date -Is)" > "$LOCK") 2>/dev/null; then
        die "lab client held: $(cat "$LOCK")"
    fi
    rm -f "$STATE_DIR/gamescope.pid" "$STATE_DIR/display" "$STATE_DIR/window"
    touch "$STATE_DIR/started"

    set_wtf "$LAB_CLIENT/WTF/Config.wtf" realmList "$auth"
    printf 'set realmlist %s\r\n' "$auth" > "$LAB_CLIENT/Data/enUS/realmlist.wtf"
    rm -rf "$LAB_CLIENT/Cache"

    step "Launching the lab client on workspace $WORKSPACE for slot $n ($auth)"
    local cmd="bash -c 'echo \$\$ > $STATE_DIR/gamescope.pid && cd $LAB_CLIENT && exec env WINEPREFIX=$LAB_PREFIX GAMEID=0 PROTONPATH=$PROTON WINEDLLOVERRIDES=divxtac=d gamescope -W $WIDTH -H $HEIGHT -w $WIDTH -h $HEIGHT -- umu-run Ascension.exe >>$STATE_DIR/client.log 2>&1'"
    hyprctl eval "hl.exec_cmd([[$cmd]], { workspace = \"$WORKSPACE silent\" })" > /dev/null

    for ((waited = 0; waited < WINDOW_TIMEOUT; waited++)); do
        if pid=$(gamescope_pid) && display=$(find_display "$pid") \
            && window=$(DISPLAY="$display" xdotool search --name '^Ascension$' 2>/dev/null | head -1) \
            && [[ -n "$window" ]]; then
            echo "$display" > "$STATE_DIR/display"
            echo "$window" > "$STATE_DIR/window"
            echo "lab client window $window on display $display (gamescope pid $pid)"
            return 0
        fi
        sleep 1
    done
    die "no client window after ${WINDOW_TIMEOUT}s, see $STATE_DIR/client.log; then: coa-client-lab stop"
}

cmd_status() {
    local pid
    if [[ ! -e "$LOCK" ]]; then
        echo "not running"
        return 0
    fi
    echo "lock: $(cat "$LOCK")"
    if pid=$(gamescope_pid); then
        echo "gamescope: running (pid $pid)"
    else
        echo "gamescope: not running (stale lock: coa-client-lab stop)"
    fi
    echo "display: $(cat "$STATE_DIR/display" 2>/dev/null || echo unknown)"
    echo "window: $(cat "$STATE_DIR/window" 2>/dev/null || echo unknown)"
}
```
Add to `main`: `start) cmd_start "$@" ;;` and `status) cmd_status ;;`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `bash -n scripts/coa-client-lab && scripts/tests/coa-client-lab.test.sh`
Expected: all `ok`, `0 failure(s)`. The EXIT trap stops the fake client by the PID in `state/gamescope.pid`
(`pkill -P` matches by parent PID, not by command line). Afterwards `pgrep -af 'X:.lab.Ascension'` prints nothing.

- [ ] **Step 5: Commit**

```bash
git add scripts/coa-client-lab scripts/tests/coa-client-lab.test.sh
git commit -m "feat(client-lab): start the lab client for a slot with a single-client lock"
```

---

### Task 3: Input and screenshots: `type`, `key`, `chat`, `login`, `screenshot`

**Files:**
- Modify: `scripts/coa-client-lab`
- Modify: `scripts/tests/coa-client-lab.test.sh` (replace the `# INPUT TESTS (Task 3)` line)

**Interfaces:**
- Consumes: `require_running` (sets `DISPLAY`, `WINDOW`), `SLEEP`, `STATE_DIR` from Task 2.
- Produces: `coa-client-lab type TEXT`, `key KEY...`, `chat TEXT`, `login ACCOUNT PASSWORD`,
  `screenshot [PATH]` (prints the PNG path on stdout).

- [ ] **Step 1: Write the failing tests**

Replace `# INPUT TESTS (Task 3)` with:
```bash
: > "$FAKE_LOG"
run_lab chat "/say hello lab"
assert_contains "chat opens the edit box" "$FAKE_LOG" "xdotool DISPLAY=:77 key --window 4242 Return"
assert_contains "chat types text" "$FAKE_LOG" "xdotool DISPLAY=:77 type --window 4242 --delay 40 /say hello lab"

: > "$FAKE_LOG"
run_lab key Escape Tab
assert_contains "key sends keys" "$FAKE_LOG" "xdotool DISPLAY=:77 key --window 4242 Escape Tab"

: > "$FAKE_LOG"
run_lab login labspike secretpw
assert_contains "login clicks the account field" "$FAKE_LOG" "mousemove --window 4242 960 567 click 1"
assert_contains "login types account" "$FAKE_LOG" "type --window 4242 --delay 60 labspike"
assert_contains "login types password" "$FAKE_LOG" "type --window 4242 --delay 60 secretpw"
assert_eq "login enters world twice Return" "$(grep -c 'key --window 4242 Return$' "$FAKE_LOG")" "2"

run_lab screenshot "$WORK/shot.png"
assert_eq "screenshot prints path" "$(cat "$WORK/out")" "$WORK/shot.png"
assert_file "screenshot written" "$WORK/shot.png"
assert_contains "screenshot uses the lab display" "$FAKE_LOG" "magick DISPLAY=:77 import -window 4242"

run_lab screenshot
assert_file "default screenshot written" "$(cat "$WORK/out")"
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `scripts/tests/coa-client-lab.test.sh`
Expected: Tasks 1-2 `ok`; the new lines FAIL (unknown commands).

- [ ] **Step 3: Implement the commands**

Add after `cmd_status`:
```bash
cmd_type() {
    [[ $# -eq 1 ]] || die "usage: coa-client-lab type TEXT"
    require_running
    xdotool type --window "$WINDOW" --delay 40 "$1"
}

cmd_key() {
    [[ $# -ge 1 ]] || die "usage: coa-client-lab key KEY..."
    require_running
    xdotool key --window "$WINDOW" "$@"
}

cmd_chat() {
    [[ $# -eq 1 ]] || die "usage: coa-client-lab chat TEXT"
    require_running
    xdotool key --window "$WINDOW" Return
    "$SLEEP" 0.5
    xdotool type --window "$WINDOW" --delay 40 "$1"
    xdotool key --window "$WINDOW" Return
}

# Sequence and delays from the spike findings (Q2). The account field sits at x = width / 2,
# y = 315 / 600 of the height; `Return` on the character list works only once the list is loaded.
cmd_login() {
    [[ $# -eq 2 ]] || die "usage: coa-client-lab login ACCOUNT PASSWORD"
    require_running
    local account="$1" password="$2" backspaces
    backspaces=$(printf 'BackSpace %.0s' $(seq 1 20))
    eval "$(xdotool getwindowgeometry --shell "$WINDOW")"
    "$SLEEP" 20
    xdotool mousemove --window "$WINDOW" $((WIDTH / 2)) $((HEIGHT * 315 / 600)) click 1
    "$SLEEP" 0.5
    # shellcheck disable=SC2086
    xdotool key --window "$WINDOW" --delay 30 $backspaces
    xdotool type --window "$WINDOW" --delay 60 "$account"
    xdotool key --window "$WINDOW" Tab
    "$SLEEP" 0.3
    # shellcheck disable=SC2086
    xdotool key --window "$WINDOW" --delay 30 $backspaces
    xdotool type --window "$WINDOW" --delay 60 "$password"
    xdotool key --window "$WINDOW" Return
    "$SLEEP" 25
    xdotool key --window "$WINDOW" Return
    "$SLEEP" 45
    echo "login sent for $account; check the world with: coa-client-lab screenshot"
}

cmd_screenshot() {
    require_running
    local path="${1:-$LAB_ROOT/screenshots/lab-$(date +%Y%m%d-%H%M%S).png}"
    mkdir -p "$(dirname "$path")"
    magick import -window "$WINDOW" "$path"
    echo "$path"
}
```
`eval "$(xdotool getwindowgeometry --shell ...)"` overwrites the global `WIDTH`/`HEIGHT` with the real window
size, which is intended here; nothing after `login` in the same process uses them.
Add to `main`: `type) cmd_type "$@" ;;`, `key) cmd_key "$@" ;;`, `chat) cmd_chat "$@" ;;`,
`login) cmd_login "$@" ;;`, `screenshot) cmd_screenshot "$@" ;;`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `bash -n scripts/coa-client-lab && scripts/tests/coa-client-lab.test.sh`
Expected: all `ok`, `0 failure(s)`.

- [ ] **Step 5: Commit**

```bash
git add scripts/coa-client-lab scripts/tests/coa-client-lab.test.sh
git commit -m "feat(client-lab): keyboard input, login and screenshots through gamescope's display"
```

---

### Task 4: `stop`, user-client guard and `preflight`

**Files:**
- Modify: `scripts/coa-client-lab`
- Modify: `scripts/tests/coa-client-lab.test.sh` (replace the `# STOP TESTS (Task 4)` line)

**Interfaces:**
- Consumes: `gamescope_pid`, `descendants`, `LOCK`, `STATE_DIR`, `started` stamp from Task 2.
- Produces: `coa-client-lab stop` (exit 0, prints `WARN: ...` lines when user-client files changed during the
  run), `coa-client-lab preflight N` (runs `coa-slot preflight N --client-data <lab>/Data`).

- [ ] **Step 1: Write the failing tests**

Replace `# STOP TESTS (Task 4)` with:
```bash
: > "$FAKE_LOG"
run_lab preflight 3
assert_contains "preflight on lab data" "$FAKE_LOG" "coa-slot preflight 3 --client-data $COA_LAB_ROOT/ascension-lab/Data"

gs_pid=$(cat "$COA_LAB_ROOT/state/gamescope.pid")
sleep 1
touch "$COA_USER_CLIENT/WTF/Account/LOCAL/SavedVariables.lua"
run_lab stop
assert_eq "stop exits 0" "$?" "0"
assert_contains "stop warns about user client" "$WORK/out" "WARN"
assert_contains "stop names changed file" "$WORK/out" "WTF/Account/LOCAL/SavedVariables.lua"
assert_absent "lock released" "$COA_LAB_ROOT/state/lock"
kill -0 "$gs_pid" 2>/dev/null && fail "gamescope stopped" || pass "gamescope stopped"

run_lab stop
assert_contains "stop when not running" "$WORK/out" "not running"

run_lab start 3
gs_pid=$(cat "$COA_LAB_ROOT/state/gamescope.pid")
pkill -P "$gs_pid"
kill "$gs_pid" 2>/dev/null
sleep 1
run_lab stop
assert_absent "stale lock released" "$COA_LAB_ROOT/state/lock"
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `scripts/tests/coa-client-lab.test.sh`
Expected: Tasks 1-3 `ok`; new lines FAIL.

- [ ] **Step 3: Implement `stop` and `preflight`**

Add after `cmd_screenshot`:
```bash
cmd_stop() {
    local pid child changed waited file
    if [[ ! -e "$LOCK" ]]; then
        echo "not running"
        return 0
    fi
    if pid=$(gamescope_pid); then
        # Stop the Windows client first: gamescope exits when its child does (spike findings).
        for child in $(descendants "$pid"); do
            if tr '\0' '\n' < "/proc/$child/cmdline" 2>/dev/null | head -1 | grep -q '\\Ascension\.exe$'; then
                kill "$child" 2>/dev/null || true
            fi
        done
        for ((waited = 0; waited < 30; waited++)); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 5
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    if [[ -e "$STATE_DIR/started" ]]; then
        changed=$(cd "$USER_CLIENT" && find WTF Interface -type f -newer "$STATE_DIR/started" 2>/dev/null | head -20)
        if [[ -n "$changed" ]]; then
            echo "WARN: the user's client changed during the lab run (the user playing, or a defect):"
            while IFS= read -r file; do
                echo "WARN:   $file"
            done <<< "$changed"
        fi
    fi
    rm -f "$LOCK" "$STATE_DIR/gamescope.pid" "$STATE_DIR/display" "$STATE_DIR/window" "$STATE_DIR/started"
    echo "lab client stopped"
}

cmd_preflight() {
    local n="${1:-}"
    [[ "$n" =~ ^[123]$ ]] || die "usage: coa-client-lab preflight N"
    shift
    exec coa-slot preflight "$n" --client-data "$LAB_CLIENT/Data" "$@"
}
```
Add to `main`: `stop) cmd_stop ;;`, `preflight) cmd_preflight "$@" ;;`.

Check that `coa-preflight.py` accepts `--client-data` after the arguments `coa-slot` adds: run
`python3 scripts/coa-preflight.py --help | grep client-data` (argparse options are order-independent).

- [ ] **Step 4: Run the tests to see them pass**

Run: `bash -n scripts/coa-client-lab && scripts/tests/coa-client-lab.test.sh`
Expected: all `ok`, `0 failure(s)`; `pgrep -af 'X:.lab.Ascension'` prints nothing afterwards.

- [ ] **Step 5: Commit**

```bash
git add scripts/coa-client-lab scripts/tests/coa-client-lab.test.sh
git commit -m "feat(client-lab): stop by PID, warn on user client changes, preflight the lab data"
```

---

### Task 5: Real client run and documentation

**Files:**
- Modify: `README.md`, `README.fr.md` (new section after "Parallel agents: server slots" / "Agents en parallèle :
  slots de serveur")
- Modify: `docs/superpowers/specs/2026-09-17-client-issue-agent-design.md` (Milestone 1 line)

**Interfaces:**
- Consumes: every command from Tasks 1-4.

- [ ] **Step 1: Link the command**

Run: `ln -sf ~/Projects/coa-server-guide/scripts/coa-client-lab ~/.local/bin/coa-client-lab && coa-client-lab --help`
Expected: the usage text.

- [ ] **Step 2: Replace the spike lab copy**

The spike left a lab copy with the throwaway `CoaProbeSpike` addon and the user's `WTF`. Check nothing runs, then
recreate it:
```bash
pgrep -af 'X:.CoaServer.client-lab' || echo "no lab client"
coa-client-lab destroy --yes
coa-client-lab create
ls ~/CoaServer/client-lab/ascension-lab/WTF ~/CoaServer/client-lab/ascension-lab/Interface/AddOns | head
```
Expected: `no lab client`, `lab removed`, `lab created`; `WTF` has no `Account` or `Custom`; no `CoaProbeSpike`.
Keep `~/CoaServer/client-lab-spike` (throwaway scripts and screenshots referenced by the findings).

- [ ] **Step 3: Claim a slot and preflight the lab client**

```bash
coa-slot list
coa-slot claim <free N> "client-lab milestone 1 real run"
coa-slot list | sed -n "/^slot <N>/,/worldserver/p"
```
If the deployed commit is not `origin/main` (`git -C ~/Projects/azerothcore-wotlk-coa fetch -q origin &&
git -C ~/Projects/azerothcore-wotlk-coa rev-parse origin/main`), run `coa-slot deploy <N> origin/main`. Then:
`coa-client-lab preflight <N>`
Expected: `RESULT: PASS`. A FAIL stops the task.

- [ ] **Step 4: Make sure the lab account exists on the slot**

The spike's scratch tool creates a GM account with the Ghost helpers:
```bash
set -a; . ~/CoaServer/slots/s<N>/ghost.env; set +a
cd ~/CoaServer/client-lab-spike/mkaccount && go run . labspike labspike
go test -run TestMakeLabCharacter -count=1 .
```
`TestMakeLabCharacter` uses `E2E_AUTH_ADDR` from the slot env and creates `Labspike` if missing.
Expected: `account labspike ready (GM 3)` and `ok`.

- [ ] **Step 5: Real run**

```bash
coa-client-lab start <N>
coa-client-lab status
coa-client-lab login labspike labspike
coa-client-lab screenshot /tmp/claude-lab-world.png
```
Open the screenshot with the Read tool. Expected: the world with the `Labspike` unit frame. If it shows the
character list, run `coa-client-lab key Return`, wait 45 s, take another screenshot, and record in the README that
the character-list delay needs raising (then raise the `"$SLEEP" 25` in `cmd_login` and rerun the tests).
Then:
```bash
coa-client-lab chat "/say lab-run-ok"
coa-client-lab screenshot /tmp/claude-lab-chat.png
```
Expected: `[Labspike] says: lab-run-ok` readable in the screenshot. Then:
```bash
coa-client-lab stop
coa-client-lab status
coa-slot release <N>
```
Expected: `lab client stopped` (a `WARN` is only acceptable if the user played meanwhile; ask them), `not running`,
and `pgrep -af 'X:.CoaServer.client-lab'` prints nothing. `stop` finds the Windows process among gamescope's
descendants; that the pressure-vessel processes are host-visible descendants is unverified. If the client
survives `stop`, stop it by the PID `pgrep` shows, record it, and fix `cmd_stop` (with a test) before
documenting.

- [ ] **Step 6: Document**

Add to `README.md` after the "Parallel agents: server slots" section:
```markdown
## Client lab for agents

[`scripts/coa-client-lab`](scripts/coa-client-lab) (linked as `~/.local/bin/coa-client-lab`) runs a separate copy
of the client so an agent can reproduce client-side issues without touching your client. The lab client runs in a
nested gamescope window (1920x1080) on Hyprland workspace 9; you can watch it there. Keyboard input and screenshots
go through gamescope's own X display, so your focus and mouse are never used. One lab client runs at a time.

```bash
coa-client-lab create                      # once: reflink copy of the client and prefix (near-zero disk space)
coa-slot claim 3 "client check"            # the lab client talks to a claimed slot
coa-client-lab preflight 3                 # server and lab client data must match
coa-client-lab start 3
coa-client-lab login <account> <password>  # GM account on that slot
coa-client-lab chat "/say hello"
coa-client-lab screenshot                  # prints the PNG path
coa-client-lab stop                        # warns if your own client changed meanwhile
```

The lab copy drops your accounts, remembered login and caches. After a client patch, recreate it:
`coa-client-lab destroy --yes && coa-client-lab create`. Tests: `scripts/tests/coa-client-lab.test.sh`. Design and
spike results: `docs/superpowers/specs/2026-09-17-client-issue-agent-*.md`.
```
Add the same section to `README.fr.md` after "Agents en parallèle : slots de serveur", translated:
```markdown
## Client de labo pour les agents

[`scripts/coa-client-lab`](scripts/coa-client-lab) (lié en `~/.local/bin/coa-client-lab`) lance une copie séparée
du client pour qu'un agent reproduise les issues côté client sans toucher à ton client. Le client de labo tourne
dans une fenêtre gamescope imbriquée (1920x1080) sur le workspace Hyprland 9 ; tu peux le regarder. Le clavier et
les captures passent par l'affichage X propre à gamescope : ton focus et ta souris ne sont jamais utilisés. Un seul
client de labo à la fois.

```bash
coa-client-lab create                      # une fois : copie reflink du client et du préfixe (quasi sans espace disque)
coa-slot claim 3 "client check"            # le client de labo parle à un slot réservé
coa-client-lab preflight 3                 # données serveur et client de labo identiques
coa-client-lab start 3
coa-client-lab login <compte> <mot de passe>  # compte GM sur ce slot
coa-client-lab chat "/say bonjour"
coa-client-lab screenshot                  # affiche le chemin du PNG
coa-client-lab stop                        # avertit si ton propre client a changé entre-temps
```

La copie de labo retire tes comptes, ton identifiant mémorisé et les caches. Après un patch client, la recréer :
`coa-client-lab destroy --yes && coa-client-lab create`. Tests : `scripts/tests/coa-client-lab.test.sh`.
Conception et résultats du spike : `docs/superpowers/specs/2026-09-17-client-issue-agent-*.md`.
```
If the real run needed different delays or commands, document what actually worked, not this text.

- [ ] **Step 7: Mark Milestone 1 done in the spec**

In `docs/superpowers/specs/2026-09-17-client-issue-agent-design.md`, replace the line starting with
`1. Lab client, \`coa-client-lab\`` by:
```markdown
1. **Lab client and launcher**: done 2026-09-17 (`scripts/coa-client-lab`, tests in
   `scripts/tests/coa-client-lab.test.sh`, preflight through `coa-client-lab preflight N`).
```

- [ ] **Step 8: Run the tests once more and commit**

Run: `scripts/tests/coa-client-lab.test.sh`
Expected: `0 failure(s)`.
```bash
git add README.md README.fr.md docs/superpowers/specs/2026-09-17-client-issue-agent-design.md
git commit -m "docs(client-lab): document the lab client launcher"
```
