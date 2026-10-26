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
export FAKE_ETC="$WORK/etc"
export FAKE_SLOT_STATE="$WORK/slot-state"
export FAKE_GHOST_ENV="$WORK/ghost.env"
export COA_GHOST_REPO="$WORK/fake-ghost-repo"
mkdir -p "$COA_GHOST_REPO"
: > "$COA_GHOST_REPO/go.mod"

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1: expected [$3], got [$2]"; }
assert_file() { [[ -e "$2" ]] && pass "$1" || fail "$1: missing $2"; }
assert_absent() { [[ ! -e "$2" ]] && pass "$1" || fail "$1: still present $2"; }
assert_contains() { grep -qF -- "$3" "$2" 2>/dev/null && pass "$1" || fail "$1: [$3] not in $2"; }
assert_not_contains() { grep -qF -- "$3" "$2" 2>/dev/null && fail "$1: [$3] still in $2" || pass "$1"; }
run_lab() { "$SCRIPT" "$@" > "$WORK/out" 2>&1; }

# C1: call the launcher's own gamescope_starttime() directly, without running main(). The script's last
# line runs `main "$@"; exit $?` on the same line by design, so it is dropped before sourcing.
gamescope_starttime_from_script() {
    local pid="$1" tmp out
    tmp=$(mktemp)
    sed '$d' "$SCRIPT" > "$tmp"
    out=$(bash -c "source \"$tmp\"; gamescope_starttime \"$pid\"")
    rm -f "$tmp"
    printf '%s' "$out"
}

make_user_client() {
    mkdir -p "$COA_USER_CLIENT"/{Data/enUS,WTF/Account/LOCAL,WTF/Custom,Cache,Interface/AddOns} "$COA_USER_PREFIX"
    touch "$COA_USER_CLIENT/Ascension.exe" "$COA_USER_CLIENT/WTF/Account/LOCAL/SavedVariables.lua" \
        "$COA_USER_CLIENT/WTF/Custom/GlueConfig.json" "$COA_USER_CLIENT/Cache/wdb" "$COA_USER_PREFIX/system.reg"
    printf 'set realmlist 127.0.0.1:3824\r\n' > "$COA_USER_CLIENT/Data/enUS/realmlist.wtf"
    printf 'SET realmList "127.0.0.1:3824"\nSET gxResolution "800x600"\nSET accountName "someone"\n' \
        > "$COA_USER_CLIENT/WTF/Config.wtf"
    cp "$COA_USER_CLIENT/WTF/Config.wtf" "$WORK/user-config-before.wtf"
}

make_fakes() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf 'hyprctl %s\n' "$*" >> "$FAKE_LOG"
if [[ "$1" == eval ]]; then
    cmd=$(sed -n 's/^hl\.exec_cmd(\[\[\(.*\)\]\], .*/\1/p' <<< "$2")
    if [[ "${FAKE_NO_LAUNCH:-}" != 1 ]]; then
        setsid bash -c "$cmd" > /dev/null 2>&1 &
    fi
fi
echo ok
EOF
    cat > "$WORK/bin/gamescope" <<'EOF'
#!/usr/bin/env bash
printf 'gamescope-argv %s\n' "$*" >> "$FAKE_LOG"
if [[ "${FAKE_STUBBORN:-}" == 1 ]]; then
    # Ignores SIGTERM itself, and its "Ascension.exe" child ignores SIGTERM too: only SIGKILL on both
    # PIDs stops this pair, exercising cmd_stop's escalation (Task 4 fix round 1).
    trap '' TERM
    DISPLAY=:77 bash -c 'exec -a "X:\ascension-lab\Ascension.exe" bash -c "trap : TERM; while :; do sleep 1; done"' &
else
    DISPLAY=:77 bash -c "exec -a 'X:\\ascension-lab\\Ascension.exe' sleep 600" &
fi
wait
EOF
    cat > "$WORK/bin/xdotool" <<'EOF'
#!/usr/bin/env bash
printf 'xdotool DISPLAY=%s %s\n' "$DISPLAY" "$*" >> "$FAKE_LOG"
if [[ "$1" == type && "${*: -1}" == /reload && "${FAKE_PROBE_SILENT:-}" != 1 ]]; then
    req=$(grep -o '/coaprobe [^ ]*' "$FAKE_LOG" | tail -1 | cut -d' ' -f2)
    dir="$COA_LAB_ROOT/ascension-lab/WTF/Account/LABSPIKE/SavedVariables"
    mkdir -p "$dir"
    printf 'CoaProbeDB = {\n\t"{\\"command\\":\\"ping\\",\\"req\\":\\"%s\\",\\"result\\":{\\"pong\\":true}}", -- [1]\n}\n' \
        "$req" > "$dir/CoaProbe.lua"
fi
case "$1" in
    search) [[ "${FAKE_NO_WINDOW:-}" == 1 ]] || echo 4242 ;;
    getwindowgeometry) printf 'WINDOW=4242\nX=0\nY=0\nWIDTH=1280\nHEIGHT=720\nSCREEN=0\n' ;;
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
[[ "$1" == env ]] && printf 'SLOT=%s\nAUTH_ADDR=127.0.0.1:3924\nETC=%s\nSTATE_FILE=%s\nGHOST_ENV=%s\n' \
    "$2" "$FAKE_ETC" "$FAKE_SLOT_STATE" "$FAKE_GHOST_ENV"
[[ "$1" == preflight && "${FAKE_PREFLIGHT_FAIL:-}" == 1 ]] && exit 1
exit 0
EOF
    : > "$FAKE_GHOST_ENV"
    # Fake `go`, standing in for the Ghost-harness-backed lab-character Go module: logs the full
    # invocation (so tests can assert the generated `go test -run ... .` command line) and answers
    # TestLabCharacterApply/TestLabCharacterIndex from FAKE_GO_* controls instead of touching a DB.
    cat > "$WORK/bin/go" <<'EOF'
#!/usr/bin/env bash
printf 'go %s SPEC=%s ACCOUNT=%s NAME=%s\n' "$*" "${COA_LAB_CHARACTER_SPEC:-}" \
    "${COA_LAB_CHARACTER_ACCOUNT:-}" "${COA_LAB_CHARACTER_NAME:-}" >> "$FAKE_LOG"
case "$*" in
    *TestLabCharacterApply*)
        [[ "${FAKE_GO_APPLY_FAIL:-}" == 1 ]] && { echo "fake go: apply refused" >&2; exit 1; }
        printf '%s\n' "${FAKE_GO_APPLY_OUT:-{\}}" > "$COA_LAB_CHARACTER_OUT"
        ;;
    *TestLabCharacterIndex*)
        [[ "${FAKE_GO_INDEX_FAIL:-}" == 1 ]] && { echo "fake go: index lookup failed" >&2; exit 1; }
        printf '%s\n' "${FAKE_GO_INDEX_OUT:-{\"found\": false\}}" > "$COA_LAB_CHARACTER_OUT"
        ;;
esac
exit 0
EOF
    # Answers `list sink-inputs` with two sink inputs: #50 carries the pid of the fake lab client's own
    # descendant process (read from the state dir the same way the real gamescope_pid/descendants would find
    # it), #51 carries this fake's own pid, which is never a descendant of the lab's gamescope. Tests can then
    # assert that only #50 gets muted.
    cat > "$WORK/bin/pactl" <<'EOF'
#!/usr/bin/env bash
printf 'pactl %s\n' "$*" >> "$FAKE_LOG"
case "$1" in
    list)
        if [[ "$2" == sink-inputs ]]; then
            in_tree=$(pgrep -P "$(cat "$COA_LAB_ROOT/state/gamescope.pid" 2>/dev/null)" 2>/dev/null | head -1)
            in_tree="${in_tree:-999999}"
            cat <<SINKS
Sink Input #50
	Driver: protocol-native.c
	Properties:
		application.process.id = "$in_tree"
Sink Input #51
	Driver: protocol-native.c
	Properties:
		application.process.id = "$$"
SINKS
        fi
        ;;
    set-sink-input-mute)
        echo "Mute: yes"
        ;;
esac
case "$1 ${2:-} ${3:-}" in
    "list short modules")
        printf '77\tmodule-null-sink\tsink_name=coa_client_lab_silence\n'
        ;;
esac
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
assert_not_contains "lab drops remembered account" "$COA_LAB_ROOT/ascension-lab/WTF/Config.wtf" "accountName"
assert_contains "user account kept" "$COA_USER_CLIENT/WTF/Config.wtf" 'SET accountName "someone"'
assert_file "lab root marker written" "$COA_LAB_ROOT/.coa-client-lab"
assert_file "lab prefix marker written" "$COA_LAB_PREFIX/.coa-client-lab"
cmp -s "$COA_USER_CLIENT/WTF/Config.wtf" "$WORK/user-config-before.wtf" \
    && pass "user Config.wtf unchanged" || fail "user Config.wtf changed"

if run_lab create; then fail "second create refused"; else pass "second create refused"; fi
assert_contains "second create message" "$WORK/out" "already exists"

# destroy
if run_lab destroy; then fail "destroy without --yes refused"; else pass "destroy without --yes refused"; fi
assert_file "destroy without --yes leaves lab client" "$COA_LAB_ROOT/ascension-lab/Ascension.exe"
run_lab destroy --yes
assert_absent "lab client removed" "$COA_LAB_ROOT"
assert_absent "lab prefix removed" "$COA_LAB_PREFIX"
assert_file "user client kept" "$COA_USER_CLIENT/Ascension.exe"

# same-path guard in create
if COA_LAB_PREFIX="$COA_USER_PREFIX" run_lab create; then fail "create over user prefix refused"; else pass "create over user prefix refused"; fi
assert_contains "same-path guard message" "$WORK/out" "aliases the user's path"
assert_file "user prefix protected" "$COA_USER_PREFIX/system.reg"

# I2: a trailing slash must not defeat the same-path guard (realpath -m normalizes it away)
if COA_LAB_PREFIX="$COA_USER_PREFIX/" run_lab create; then
    fail "create over user prefix with trailing slash refused"
else
    pass "create over user prefix with trailing slash refused"
fi
assert_contains "trailing-slash guard message" "$WORK/out" "aliases the user's path"
assert_file "user prefix protected (trailing slash)" "$COA_USER_PREFIX/system.reg"

# I2: destroy refused when the lab prefix override is an ancestor of the user prefix
if COA_LAB_PREFIX="$(dirname "$COA_USER_PREFIX")" run_lab destroy --yes; then
    fail "destroy over parent of user prefix refused"
else
    pass "destroy over parent of user prefix refused"
fi
assert_contains "destroy parent guard message" "$WORK/out" "aliases the user's path"
assert_file "user prefix protected (destroy parent)" "$COA_USER_PREFIX/system.reg"

# I2: destroy refuses a directory that create did not mark, even with --yes, and leaves it alone
mkdir -p "$COA_LAB_ROOT"
if run_lab destroy --yes; then fail "destroy without marker refused"; else pass "destroy without marker refused"; fi
assert_contains "destroy without marker message" "$WORK/out" "no .coa-client-lab marker"
assert_file "unmarked lab root kept" "$COA_LAB_ROOT"
rm -rf "$COA_LAB_ROOT"

run_lab create

if run_lab mute; then fail "mute without a running lab client fails"; else pass "mute without a running lab client fails"; fi
assert_contains "mute without running message" "$WORK/out" "the lab client is not running"

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
# I3: start mutes on its own (cmd_mute || true), and it must do so only through the fakes on PATH, never the
# host's real pactl.
assert_contains "start attempts to mute via the fake pactl" "$FAKE_LOG" "pactl list sink-inputs"

if run_lab start 2; then fail "second start refused"; else pass "second start refused"; fi
assert_contains "second start names holder" "$WORK/out" "slot 3"

run_lab status
assert_contains "status shows display" "$WORK/out" "display: :77"
assert_contains "status shows running" "$WORK/out" "gamescope: running (pid"

: > "$FAKE_LOG"
run_lab chat "/say hello lab"
assert_contains "chat opens the edit box" "$FAKE_LOG" "xdotool DISPLAY=:77 key --window 4242 Return"
assert_contains "chat types text" "$FAKE_LOG" "xdotool DISPLAY=:77 type --window 4242 --delay 40 /say hello lab"

: > "$FAKE_LOG"
run_lab key Escape Tab
assert_contains "key sends keys" "$FAKE_LOG" "xdotool DISPLAY=:77 key --window 4242 Escape Tab"

: > "$FAKE_LOG"
run_lab hold w 300
assert_eq "hold exits 0" "$?" "0"
assert_contains "hold sends keydown" "$FAKE_LOG" "xdotool DISPLAY=:77 keydown --window 4242 w"
assert_contains "hold sends keyup" "$FAKE_LOG" "xdotool DISPLAY=:77 keyup --window 4242 w"

if run_lab hold w abc; then fail "hold rejects a non-numeric duration"; else pass "hold rejects a non-numeric duration"; fi
assert_contains "hold duration message" "$WORK/out" "hold duration must be milliseconds"

# mute: only the sink input whose pid is in the lab client's process tree (id 50, from the fake pactl above)
# gets muted; the unrelated one (id 51) is left alone. This is the guard that keeps the user's own client from
# ever being muted, so it gets its own check beyond the "start calls mute" assertion above.
: > "$FAKE_LOG"
run_lab mute
assert_eq "mute exits 0" "$?" "0"
gs_pid=$(cat "$COA_LAB_ROOT/state/gamescope.pid")
tree_pid=$(pgrep -P "$gs_pid" | head -1)
assert_contains "mute mutes the pid in the lab's process tree" "$WORK/out" "muted sink input 50 (pid $tree_pid)"
assert_not_contains "mute leaves the unrelated pid alone" "$WORK/out" "muted sink input 51"
assert_contains "mute set-mute called for the matched id" "$FAKE_LOG" "pactl set-sink-input-mute 50 1"
assert_not_contains "mute set-mute not called for the unmatched id" "$FAKE_LOG" "pactl set-sink-input-mute 51 1"

# cmd_mute must still return 0 when pactl itself is not installed, even with a running lab client. Strip the
# fake bin dir (which is where the fake pactl lives) from PATH, keeping only what the script needs to start
# (bash via its #!/usr/bin/env shebang, plus dirname/readlink for its own SCRIPT_DIR resolution); cmd_mute's
# "pactl not installed" branch runs before anything else needs external tools.
nopactl_bin="$WORK/bin-no-pactl"
mkdir -p "$nopactl_bin"
for tool in bash dirname readlink; do
    ln -sf "$(command -v "$tool")" "$nopactl_bin/$tool"
done
PATH="$nopactl_bin" run_lab mute
assert_eq "mute without pactl on PATH still exits 0" "$?" "0"
assert_contains "mute without pactl message" "$WORK/out" "pactl not installed: cannot mute"

: > "$FAKE_LOG"
run_lab login labspike secretpw
assert_contains "login clicks the account field" "$FAKE_LOG" "mousemove --window 4242 640 378 click 1"
assert_contains "login types account" "$FAKE_LOG" "type --window 4242 --delay 60 labspike"
assert_contains "login types password" "$FAKE_LOG" "type --window 4242 --delay 60 secretpw"
# Two Returns reach the world (submit the password, then enter the world) on the FIRST login of a lab
# session: no dismiss Return yet, since nothing can have left a leftover dialog before any login was
# attempted (confirmed live on slot 2, 2026-10-26: an unconditional dismiss Return on an untouched login
# screen corrupted the account field instead of closing a dialog that was never there). The sound CVars
# typed afterwards each open the chat with a Return of their own, so stop counting at the first /console
# line and drop the Return that opened it.
assert_eq "login's first attempt sends two Returns (submit, enter world), no dismiss yet" \
    "$(awk '/--delay 40 \/console/ { print n - 1; found = 1; exit } /key --window 4242 Return$/ { n++ } END { if (!found) print n + 0 }' "$FAKE_LOG")" "2"
assert_contains "login silences the client" "$FAKE_LOG" "type --window 4242 --delay 40 /console Sound_EnableAllSound 0"
assert_contains "login zeroes the master volume" "$FAKE_LOG" "type --window 4242 --delay 40 /console Sound_MasterVolume 0"

# A SECOND login in the same lab session (state/account already exists from the one above) does send the
# dismiss Return, before the account field is clicked: only now could a leftover dialog exist.
: > "$FAKE_LOG"
run_lab login labspike secretpw
assert_eq "login's second attempt sends three Returns (dismiss, submit, enter world)" \
    "$(awk '/--delay 40 \/console/ { print n - 1; found = 1; exit } /key --window 4242 Return$/ { n++ } END { if (!found) print n + 0 }' "$FAKE_LOG")" "3"
dismiss_line=$(awk '/key --window 4242 Return$/ { print NR; exit }' "$FAKE_LOG")
click_line=$(awk '/mousemove --window 4242 640 378 click 1/ { print NR; exit }' "$FAKE_LOG")
if [[ -n "$dismiss_line" && -n "$click_line" && "$dismiss_line" -lt "$click_line" ]]; then
    pass "login's modal-dismiss Return happens before the account field click"
else
    fail "login's modal-dismiss Return happens before the account field click: dismiss=$dismiss_line click=$click_line"
fi

run_lab screenshot "$WORK/shot.png"
assert_eq "screenshot prints path" "$(cat "$WORK/out")" "$WORK/shot.png"
assert_file "screenshot written" "$WORK/shot.png"
assert_contains "screenshot uses the lab display" "$FAKE_LOG" "magick DISPLAY=:77 import -window 4242"

run_lab screenshot
assert_file "default screenshot written" "$(cat "$WORK/out")"

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

# I1: a stale gamescope.pid can survive a crash or reboot and later be reused by an unrelated process,
# possibly an ancestor of the user's own client. stop must leave it alone: gamescope_pid now requires the
# recorded pid's cmdline to mention gamescope and its current start time to match the one `start` recorded,
# not just kill -0.
mkdir -p "$COA_LAB_ROOT/state"
: > "$COA_LAB_ROOT/state/lock"
touch "$COA_LAB_ROOT/state/started"
bash -c 'exec -a "X:\ascension-live\Ascension.exe" sleep 600' &
unrelated_pid=$!
echo "$unrelated_pid" > "$COA_LAB_ROOT/state/gamescope.pid"
rm -f "$COA_LAB_ROOT/state/gamescope.starttime"
run_lab stop
assert_eq "stale pid stop exits 0" "$?" "0"
kill -0 "$unrelated_pid" 2>/dev/null && pass "stale pid: unrelated process left alone" \
    || fail "stale pid: unrelated process left alone"
assert_absent "stale pid: lock released" "$COA_LAB_ROOT/state/lock"
kill "$unrelated_pid" 2>/dev/null
wait "$unrelated_pid" 2>/dev/null

# C1: gamescope_starttime must read stat field 22 (process start time), not field 20 (thread count).
# Real gamescope and its Wine/Proton children are multi-threaded, and their thread count can change
# during the run (field 20 would then no longer match what was recorded at start); the bash fakes above
# are single-threaded bash and cannot expose that. This uses a real multi-threaded process (python3 with
# a background thread) run under an `exec -a` name containing "gamescope" so the cmdline check in
# gamescope_pid does not short-circuit the comparison, with a child whose argv0 is the lab client path
# and DISPLAY=:77.
cat > "$WORK/fake-gamescope-mt.py" <<'PYEOF'
import os
import shutil
import subprocess
import sys
import threading
import time

state_dir, sync_file = sys.argv[1], sys.argv[2]

with open(os.path.join(state_dir, "gamescope.pid"), "w") as f:
    f.write(str(os.getpid()))

env = dict(os.environ)
env["DISPLAY"] = ":77"
child = subprocess.Popen(
    ["X:\\ascension-lab\\Ascension.exe", "600"], executable=shutil.which("sleep"), env=env
)

# Wait for the test to record the start time while this process is still single-threaded.
while not os.path.exists(sync_file):
    time.sleep(0.05)

# Real gamescope/Wine processes are multi-threaded, and the thread count can change after start; that
# mismatch is exactly what a wrong stat field exposes. Add a second OS thread now.
threading.Thread(target=lambda: time.sleep(600), daemon=True).start()

child.wait()
PYEOF

mkdir -p "$COA_LAB_ROOT/state"
mt_sync="$WORK/fake-gamescope-mt.sync"
rm -f "$mt_sync"
( exec -a gamescope-fake python3 "$WORK/fake-gamescope-mt.py" "$COA_LAB_ROOT/state" "$mt_sync" ) &
mt_pid=$!

for _ in $(seq 1 50); do
    [[ -s "$COA_LAB_ROOT/state/gamescope.pid" ]] && break
    sleep 0.1
done
pid=$(cat "$COA_LAB_ROOT/state/gamescope.pid" 2>/dev/null)
assert_eq "C1 setup: fake gamescope pid recorded" "$pid" "$mt_pid"
threads_before=$(awk '{print $20}' "/proc/$pid/stat" 2>/dev/null)
assert_eq "C1 setup: fake starts single-threaded" "${threads_before:-}" "1"

recorded=$(gamescope_starttime_from_script "$pid")
printf '%s' "$recorded" > "$COA_LAB_ROOT/state/gamescope.starttime"

touch "$mt_sync"
threads_after=0
for _ in $(seq 1 50); do
    threads_after=$(awk '{print $20}' "/proc/$pid/stat" 2>/dev/null) || threads_after=0
    [[ "${threads_after:-0}" -gt 1 ]] && break
    sleep 0.1
done
[[ "${threads_after:-0}" -gt 1 ]] && pass "C1 setup: fake becomes multi-threaded" \
    || fail "C1 setup: fake becomes multi-threaded"

: > "$COA_LAB_ROOT/state/lock"
run_lab status
assert_contains "C1: status reports the multi-threaded fake as running" "$WORK/out" "gamescope: running (pid $pid)"

child_pid=$(pgrep -P "$pid" 2>/dev/null | head -1)
run_lab stop
assert_eq "C1: stop exits 0" "$?" "0"
assert_absent "C1: stop releases the lock" "$COA_LAB_ROOT/state/lock"
kill -0 "$pid" 2>/dev/null && fail "C1: stop kills the fake" || pass "C1: stop kills the fake"
if [[ -n "$child_pid" ]]; then
    kill -0 "$child_pid" 2>/dev/null && fail "C1: stop kills its child" || pass "C1: stop kills its child"
else
    fail "C1: stop kills its child (no child pid captured)"
fi

# Unconditional cleanup: under the bug, stop above does not kill the fake or its child.
kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
[[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null && kill -9 "$child_pid" 2>/dev/null
rm -f "$COA_LAB_ROOT/state/lock" "$COA_LAB_ROOT/state/gamescope.pid" "$COA_LAB_ROOT/state/gamescope.starttime"

if FAKE_NO_LAUNCH=1 COA_LAB_WINDOW_TIMEOUT=1 run_lab start 3; then
    fail "timed-out start refused"
else
    pass "timed-out start refused"
fi
assert_contains "timed-out start message" "$WORK/out" "no client window after 1s"
assert_file "timed-out start lock present" "$COA_LAB_ROOT/state/lock"
run_lab stop
assert_absent "timed-out start lock released" "$COA_LAB_ROOT/state/lock"

# I-A: the start time must be recorded as soon as gamescope is confirmed alive, before the window is
# found, so a start that times out (window never appears) still leaves `stop` able to find and kill the
# live gamescope and its child. The test above uses FAKE_NO_LAUNCH=1 (no process launches at all) and
# cannot exercise this; here the fake gamescope launches normally but xdotool search never finds a window.
if FAKE_NO_WINDOW=1 COA_LAB_WINDOW_TIMEOUT=2 run_lab start 3; then
    fail "no-window start refused"
else
    pass "no-window start refused"
fi
assert_contains "no-window start message" "$WORK/out" "no client window after"
gs_pid=$(cat "$COA_LAB_ROOT/state/gamescope.pid" 2>/dev/null) || gs_pid=""
[[ -n "$gs_pid" ]] && pass "no-window start recorded a gamescope pid" || fail "no-window start recorded a gamescope pid"
assert_file "no-window start recorded a start time" "$COA_LAB_ROOT/state/gamescope.starttime"
child_pid=$(pgrep -P "$gs_pid" 2>/dev/null | head -1)
[[ -n "$child_pid" ]] && pass "no-window start recorded a child" || fail "no-window start recorded a child"

run_lab stop
assert_eq "no-window stop exits 0" "$?" "0"
assert_absent "no-window stop releases the lock" "$COA_LAB_ROOT/state/lock"
kill -0 "$gs_pid" 2>/dev/null && fail "no-window stop kills gamescope" || pass "no-window stop kills gamescope"
if [[ -n "$child_pid" ]]; then
    kill -0 "$child_pid" 2>/dev/null && fail "no-window stop kills the child" || pass "no-window stop kills the child"
else
    fail "no-window stop kills gamescope child (no child pid captured)"
fi

# Unconditional cleanup: under the bug, gamescope.starttime is never written, so stop above does not
# recognise or kill the fake or its child.
kill -0 "$gs_pid" 2>/dev/null && kill -9 "$gs_pid" 2>/dev/null
[[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null && kill -9 "$child_pid" 2>/dev/null
rm -f "$COA_LAB_ROOT/state/lock" "$COA_LAB_ROOT/state/gamescope.pid" "$COA_LAB_ROOT/state/gamescope.starttime"

# escalation must reap the whole tree, not just gamescope (fix round 1): a gamescope and child that both
# ignore SIGTERM force the SIGKILL branch, which must not leave the child orphaned.
FAKE_STUBBORN=1 run_lab start 3
assert_eq "stubborn start exits 0" "$?" "0"
gs_pid=$(cat "$COA_LAB_ROOT/state/gamescope.pid")
child_pid=$(pgrep -P "$gs_pid" | head -1)
[[ -n "$child_pid" ]] && pass "stubborn child pid found" || fail "stubborn child pid found"
COA_LAB_STOP_TIMEOUT=1 run_lab stop
assert_absent "escalation lock released" "$COA_LAB_ROOT/state/lock"
kill -0 "$gs_pid" 2>/dev/null && fail "escalation kills gamescope" || pass "escalation kills gamescope"
kill -0 "$child_pid" 2>/dev/null && fail "escalation kills orphaned child" || pass "escalation kills orphaned child"

# PROBE TESTS (Milestone 2)
run_lab start 3
assert_file "addon installed" "$COA_LAB_ROOT/ascension-lab/Interface/AddOns/CoaProbe/CoaProbe.toc"
assert_absent "addon tests not installed" "$COA_LAB_ROOT/ascension-lab/Interface/AddOns/CoaProbe/tests"
run_lab login labspike secretpw
assert_eq "account recorded" "$(cat "$COA_LAB_ROOT/state/account")" "labspike"

: > "$FAKE_LOG"
run_lab probe ping
assert_eq "probe exits 0" "$?" "0"
assert_contains "probe types the request" "$FAKE_LOG" "type --window 4242 --delay 40 /coaprobe p"
assert_contains "probe reloads" "$FAKE_LOG" "type --window 4242 --delay 40 /reload"
assert_contains "probe prints the answer" "$WORK/out" '"pong": true'

if run_lab probe 'spell 1|2'; then fail "probe refuses a pipe"; else pass "probe refuses a pipe"; fi
assert_contains "pipe message" "$WORK/out" "cannot contain |"

if FAKE_PROBE_SILENT=1 COA_LAB_PROBE_TIMEOUT=1 run_lab probe ping; then
    fail "probe times out without an answer"
else
    pass "probe times out without an answer"
fi
assert_contains "probe timeout message" "$WORK/out" "no CoaProbe answer"

run_lab stop
assert_absent "account cleared by stop" "$COA_LAB_ROOT/state/account"

# Profiles: the minimal profile writes each low-cost setting once and the smaller window; readable keeps 1920x1080.
config="$COA_LAB_ROOT/ascension-lab/WTF/Config.wtf"
: > "$FAKE_LOG"
COA_LAB_PROFILE=minimal COA_LAB_DISPLAY=nested run_lab start 3
assert_eq "minimal start exits 0" "$?" "0"
assert_contains "minimal resolution" "$config" 'SET gxResolution "800x600"'
for setting in 'maxFPS "10"' 'maxFPSBk "5"' 'farclip "177"' 'groundEffectDensity "16"' 'environmentDetail "0.5"' \
    'particleDensity "0.1"' 'weatherDensity "0"' 'spellEffectLevel "0"' 'specular "0"' 'projectedTextures "0"' \
    'textureFilteringMode "0"' 'baseMip "1"' 'ffxGlow "0"' 'ffxDeath "0"' 'showfootprints "0"'; do
    assert_contains "minimal sets $setting" "$config" "SET $setting"
done
assert_contains "minimal gamescope size" "$FAKE_LOG" "gamescope -W 800 -H 600 -w 800 -h 600"
run_lab stop
COA_LAB_PROFILE=minimal run_lab start 3
assert_contains "minimal defaults to headless" "$FAKE_LOG" "gamescope-argv --backend headless -W 800 -H 600"
run_lab stop
assert_eq "minimal settings not duplicated" "$(grep -c '^SET maxFPS ' "$config")" "1"
assert_eq "minimal resolution not duplicated" "$(grep -c '^SET gxResolution ' "$config")" "1"

sed -i '/^SET \(maxFPS\|maxFPSBk\|farclip\|baseMip\) /d' "$config"
run_lab start 3
assert_contains "readable resolution" "$config" 'SET gxResolution "1920x1080"'
assert_not_contains "readable adds no minimal setting" "$config" 'SET maxFPS '
assert_not_contains "readable adds no baseMip" "$config" 'SET baseMip '
run_lab stop

# Headless display: gamescope's headless backend, no Hyprland, same window discovery.
: > "$FAKE_LOG"
COA_LAB_PROFILE=minimal COA_LAB_DISPLAY=headless run_lab start 3
assert_eq "headless start exits 0" "$?" "0"
assert_contains "headless backend" "$FAKE_LOG" \
    "gamescope-argv --backend headless -W 800 -H 600 -w 800 -h 600 -r 10 -- umu-run Ascension.exe"
assert_not_contains "headless does not use hyprctl" "$FAKE_LOG" "hyprctl"
run_lab status
assert_contains "headless status shows the window" "$WORK/out" "window: 4242"
run_lab stop
assert_absent "headless stop releases the lock" "$COA_LAB_ROOT/state/lock"

if COA_LAB_DISPLAY=bogus run_lab start 3; then fail "bogus display refused"; else pass "bogus display refused"; fi
assert_contains "bogus display message" "$WORK/out" "COA_LAB_DISPLAY must be nested or headless"
assert_absent "bogus display takes no lock" "$COA_LAB_ROOT/state/lock"
if COA_LAB_PROFILE=fancy run_lab start 3; then fail "bogus profile refused"; else pass "bogus profile refused"; fi
assert_contains "bogus profile message" "$WORK/out" "COA_LAB_PROFILE must be readable or minimal"

# relay-setup: one line per key after two runs, relay.env with slot 3's SOAP port.
mkdir -p "$FAKE_ETC/modules"
printf 'Ra.Enable = 0\nSOAP.Enabled = 0\nSOAP.IP = "127.0.0.1"\nSOAP.Port = 7878\n' > "$FAKE_ETC/worldserver.conf"
printf 'CoA.Enable = 1\n' > "$FAKE_ETC/modules/coa.conf"
printf 'PW\n' > "$WORK/soap.password"
run_lab relay-setup 3 --soap-account COALABSOAP --soap-password-file "$WORK/soap.password"
assert_eq "relay-setup exits 0" "$?" "0"
run_lab relay-setup 3 --soap-account COALABSOAP --soap-password-file "$WORK/soap.password"
assert_contains "relay-setup prints the restart" "$WORK/out" "coa-slot compose 3 restart ac-worldserver"
assert_eq "SOAP.Enabled once" "$(grep -c '^SOAP.Enabled = 1$' "$FAKE_ETC/worldserver.conf")" "1"
assert_eq "SOAP.IP once" "$(grep -c '^SOAP.IP = "0.0.0.0"$' "$FAKE_ETC/worldserver.conf")" "1"
assert_eq "SOAP.Port untouched" "$(grep -c '^SOAP.Port = 7878$' "$FAKE_ETC/worldserver.conf")" "1"
assert_eq "relay enabled once" "$(grep -c '^CoA.ProbeRelay.Enable = 1$' "$FAKE_ETC/modules/coa.conf")" "1"
assert_contains "relay.env url" "$COA_LAB_ROOT/relay.env" "SOAP_URL=http://127.0.0.1:8078/"
assert_contains "relay.env account" "$COA_LAB_ROOT/relay.env" "SOAP_ACCOUNT=COALABSOAP"
assert_contains "relay.env password file" "$COA_LAB_ROOT/relay.env" "SOAP_PASSWORD_FILE=$WORK/soap.password"
assert_eq "relay.env mode 600" "$(stat -c %a "$COA_LAB_ROOT/relay.env")" "600"
if run_lab relay-setup 3 --soap-account COALABSOAP; then
    fail "relay-setup needs a password file"
else
    pass "relay-setup needs a password file"
fi

# preflight records its result for the descriptor.
run_lab preflight 3
assert_contains "preflight records pass" "$COA_LAB_ROOT/state/preflight" "pass slot 3"
if FAKE_PREFLIGHT_FAIL=1 run_lab preflight 3; then
    fail "failed preflight exits non-zero"
else
    pass "failed preflight exits non-zero"
fi
assert_contains "preflight records fail" "$COA_LAB_ROOT/state/preflight" "fail slot 3"
run_lab preflight 3

# login with a character writes the descriptor; probe then goes through the relay; stop removes it.
printf 'feat/x 0123456789abcdef 2026-10-25T23:00:00+01:00\n' > "$FAKE_SLOT_STATE"
printf '#!/usr/bin/env bash\nprintf "relay %%s\\n" "$*" >> "$FAKE_LOG"\necho %s\n' \
    "'{\"pong\": true, \"via\": \"relay\"}'" > "$WORK/bin/fake-relay"
chmod +x "$WORK/bin/fake-relay"
export COA_LAB_RELAY="$WORK/bin/fake-relay"
run_lab start 3
run_lab login coalab1 secretpw Coalabone
assert_eq "login with character exits 0" "$?" "0"
lab_json="$COA_LAB_ROOT/state/lab.json"
assert_file "descriptor written" "$lab_json"
assert_eq "descriptor mode 600" "$(stat -c %a "$lab_json")" "600"
for key in '"instance": ""' '"slot": 3' '"soap_url": "http://127.0.0.1:8078/"' '"soap_account": "COALABSOAP"' \
    "\"soap_password_file\": \"$WORK/soap.password\"" '"account": "COALAB1"' '"character": "Coalabone"' \
    '"deployed_commit": "0123456789abcdef"' '"preflight": "pass"' \
    "\"client_dir\": \"$COA_LAB_ROOT/ascension-lab\"" "\"worldserver_conf\": \"$FAKE_ETC/worldserver.conf\""; do
    assert_contains "descriptor has $key" "$lab_json" "$key"
done
: > "$FAKE_LOG"
run_lab probe spell 501281
assert_eq "relay probe exits 0" "$?" "0"
assert_contains "relay probe calls the relay" "$FAKE_LOG" "relay --descriptor $lab_json probe spell 501281"
assert_not_contains "relay probe does not reload" "$FAKE_LOG" "/reload"
assert_contains "relay probe prints the answer" "$WORK/out" '"via": "relay"'
: > "$FAKE_LOG"
COA_LAB_TRANSPORT=reload run_lab probe ping
assert_contains "reload transport still reloads" "$FAKE_LOG" "/reload"
if run_lab login coalab1 secretpw 'Bad Name'; then
    fail "login refuses a bad character name"
else
    pass "login refuses a bad character name"
fi
run_lab stop
assert_absent "stop removes the descriptor" "$lab_json"
assert_absent "stop clears the preflight record" "$COA_LAB_ROOT/state/preflight"

# Routing: only the relay's read-only commands go through the relay once lab.json exists.
export COA_LAB_RELAY="$WORK/bin/fake-relay"
run_lab preflight 3
run_lab start 3
run_lab login coalab1 secretpw Coalabone
for command in "eval 1" "pksend 1617 u32:1" "pkwatch 1618" "evwatch X"; do
    : > "$FAKE_LOG"
    # shellcheck disable=SC2086
    run_lab probe $command
    assert_not_contains "probe $command does not use the relay" "$FAKE_LOG" "relay --descriptor"
    assert_contains "probe $command keeps the /reload path" "$FAKE_LOG" "/reload"
done
for command in ping "frame GameTooltip" errors "auras target"; do
    : > "$FAKE_LOG"
    # shellcheck disable=SC2086
    run_lab probe $command
    assert_contains "probe $command uses the relay" "$FAKE_LOG" "relay --descriptor $lab_json probe $command"
    assert_not_contains "probe $command does not reload" "$FAKE_LOG" "/reload"
done
assert_contains "fresh pass for this slot is pass" "$lab_json" '"preflight": "pass"'
assert_contains "descriptor records the preflight slot" "$lab_json" '"preflight_slot": 3'
assert_contains "descriptor records the deploy time" "$lab_json" '"deployed_at": "2026-10-25T23:00:00+01:00"'

# Stale preflight records never become "pass".
printf 'pass slot 2 %s\n' "$(date -Is)" > "$COA_LAB_ROOT/state/preflight"
run_lab login coalab1 secretpw Coalabone
assert_contains "pass from another slot is stale" "$lab_json" '"preflight": "stale"'
printf 'pass slot 3 2026-10-25T22:00:00+01:00\n' > "$COA_LAB_ROOT/state/preflight"
run_lab login coalab1 secretpw Coalabone
assert_contains "pass older than the deploy is stale" "$lab_json" '"preflight": "stale"'
printf 'fail slot 3 %s\n' "$(date -Is)" > "$COA_LAB_ROOT/state/preflight"
run_lab login coalab1 secretpw Coalabone
assert_contains "fail stays fail" "$lab_json" '"preflight": "fail"'
rm -f "$COA_LAB_ROOT/state/preflight"
run_lab login coalab1 secretpw Coalabone
assert_contains "missing preflight is unknown" "$lab_json" '"preflight": "unknown"'
run_lab stop

# start drops a preflight recorded for another slot.
printf 'pass slot 2 %s\n' "$(date -Is)" > "$COA_LAB_ROOT/state/preflight"
run_lab start 3
assert_absent "start drops a preflight of another slot" "$COA_LAB_ROOT/state/preflight"
run_lab stop

# relay.env set up for another slot: no descriptor that mixes two slots.
sed -i 's/^SLOT=3$/SLOT=2/' "$COA_LAB_ROOT/relay.env"
run_lab start 3
if run_lab login coalab1 secretpw Coalabone; then
    fail "login refuses a relay.env of another slot"
else
    pass "login refuses a relay.env of another slot"
fi
assert_contains "relay.env slot mismatch message" "$WORK/out" "relay.env is set up for slot 2"
assert_absent "no descriptor for a slot mismatch" "$lab_json"
run_lab stop
sed -i 's/^SLOT=2$/SLOT=3/' "$COA_LAB_ROOT/relay.env"
unset COA_LAB_RELAY

# Instances: separate client, prefix, state, lock and pid per COA_LAB_INSTANCE; the silent sink stays while any
# other lab client still holds its lock.
if COA_LAB_INSTANCE=1 COA_LAB_ROOT="$WORK/no-base" run_lab create-instance; then
    fail "create-instance without a base lab dies"
else
    pass "create-instance without a base lab dies"
fi
assert_contains "create-instance without base message" "$WORK/out" "no base lab"
if COA_LAB_INSTANCE=x run_lab status; then fail "bad instance refused"; else pass "bad instance refused"; fi
if COA_LAB_INSTANCE=1 run_lab create; then fail "create refuses an instance"; else pass "create refuses an instance"; fi
if COA_LAB_INSTANCE=1 run_lab start 3; then fail "start needs the instance"; else pass "start needs the instance"; fi
assert_contains "start without instance message" "$WORK/out" "no instance 1"

COA_LAB_INSTANCE=1 run_lab create-instance
assert_eq "create-instance 1 exits 0" "$?" "0"
COA_LAB_INSTANCE=2 run_lab create-instance
assert_file "instance 1 client" "$COA_LAB_ROOT/instances/1/ascension-lab/Ascension.exe"
assert_file "instance 2 prefix" "$COA_LAB_PREFIX-2/system.reg"
assert_file "instance 1 marker" "$COA_LAB_ROOT/instances/1/.coa-client-lab"
assert_file "instance 2 prefix marker" "$COA_LAB_PREFIX-2/.coa-client-lab"
if COA_LAB_INSTANCE=1 run_lab create-instance; then fail "second create-instance refused"; else pass "second create-instance refused"; fi

: > "$FAKE_LOG"
COA_LAB_INSTANCE=1 COA_LAB_DISPLAY=headless run_lab start 3
assert_eq "instance 1 start exits 0" "$?" "0"
COA_LAB_INSTANCE=2 COA_LAB_DISPLAY=headless run_lab start 3
assert_eq "instance 2 start exits 0" "$?" "0"
assert_file "instance 1 lock" "$COA_LAB_ROOT/state/1/lock"
assert_file "instance 2 lock" "$COA_LAB_ROOT/state/2/lock"
assert_absent "base lock untouched" "$COA_LAB_ROOT/state/lock"
pid1=$(cat "$COA_LAB_ROOT/state/1/gamescope.pid")
pid2=$(cat "$COA_LAB_ROOT/state/2/gamescope.pid")
[[ -n "$pid1" && -n "$pid2" && "$pid1" != "$pid2" ]] && pass "instances have distinct gamescope pids" \
    || fail "instances have distinct gamescope pids: [$pid1] [$pid2]"
assert_contains "instance 1 launched from its client" "$FAKE_LOG" "gamescope-argv --backend headless"
grep -q "WINEPREFIX=$COA_LAB_PREFIX-1" "/proc/$pid1/environ" 2>/dev/null \
    && pass "instance 1 runs in its own prefix" || fail "instance 1 runs in its own prefix"

: > "$FAKE_LOG"
COA_LAB_INSTANCE=1 run_lab stop
assert_absent "instance 1 lock released" "$COA_LAB_ROOT/state/1/lock"
kill -0 "$pid2" 2>/dev/null && pass "instance 2 still running" || fail "instance 2 still running"
assert_not_contains "sink kept while instance 2 runs" "$FAKE_LOG" "pactl unload-module"
if COA_LAB_INSTANCE=2 run_lab destroy-instance --yes; then
    fail "destroy-instance refused while running"
else
    pass "destroy-instance refused while running"
fi
: > "$FAKE_LOG"
COA_LAB_INSTANCE=2 run_lab stop
assert_contains "sink unloaded with the last client" "$FAKE_LOG" "pactl unload-module 77"

COA_LAB_INSTANCE=2 run_lab destroy-instance --yes
assert_eq "destroy-instance exits 0" "$?" "0"
assert_absent "instance 2 client removed" "$COA_LAB_ROOT/instances/2"
assert_absent "instance 2 prefix removed" "$COA_LAB_PREFIX-2"
assert_file "base lab kept" "$COA_LAB_ROOT/ascension-lab/Ascension.exe"
assert_file "base prefix kept" "$COA_LAB_PREFIX/system.reg"

rm -f "$COA_LAB_ROOT/instances/1/.coa-client-lab"
if COA_LAB_INSTANCE=1 run_lab destroy-instance --yes; then
    fail "destroy-instance without marker dies"
else
    pass "destroy-instance without marker dies"
fi
assert_file "unmarked instance kept" "$COA_LAB_ROOT/instances/1/ascension-lab/Ascension.exe"
touch "$COA_LAB_ROOT/instances/1/.coa-client-lab"
COA_LAB_INSTANCE=1 run_lab destroy-instance --yes

mkdir -p "$COA_LAB_PREFIX-1"
touch "$COA_LAB_PREFIX-1/user-data"
if COA_LAB_INSTANCE=1 COA_USER_PREFIX="$COA_LAB_PREFIX-1" run_lab create-instance; then
    fail "instance prefix aliasing the user's prefix refused"
else
    pass "instance prefix aliasing the user's prefix refused"
fi
assert_contains "instance alias message" "$WORK/out" "aliases the user's path"
assert_file "aliased user prefix untouched" "$COA_LAB_PREFIX-1/user-data"
rm -rf "$COA_LAB_PREFIX-1"

# --- character: argument validation, slot-1 refusal, class refusal, the generated request ---

if run_lab character --slot 1 --account A --character C --race 1 --class 23; then
    fail "character refuses slot 1"
else
    pass "character refuses slot 1"
fi
assert_contains "character slot-1 refusal message" "$WORK/out" "slot 1 is the user's own"

for bad_class in 0 1 11 33 999; do
    if run_lab character --slot 2 --account A --character C --race 1 --class "$bad_class"; then
        fail "character refuses class $bad_class"
    else
        pass "character refuses class $bad_class"
    fi
    assert_contains "character class $bad_class refusal message" "$WORK/out" "CoA class id 12-32"
done

if run_lab character --slot 2 --account A --class 23; then
    fail "character requires --character"
else
    pass "character requires --character"
fi

if run_lab character --slot 2 --account A --character 'Bad Name' --race 1 --class 23; then
    fail "character refuses a non-letters name"
else
    pass "character refuses a non-letters name"
fi

: > "$FAKE_LOG"
FAKE_GO_APPLY_OUT='{"account": "COALAB1", "character": "Coalabnecro", "class": 23, "created": true}' \
    run_lab character --slot 2 --account coalab1 --character Coalabnecro --race 5 --class 23 \
        --level 20 --learn 704723,704724 --items 9701803
assert_eq "character (valid request) exits 0" "$?" "0"
assert_contains "character runs go test for TestLabCharacterApply" "$FAKE_LOG" "go test -run ^TestLabCharacterApply\$ -v ."
assert_contains "character request has the account" "$FAKE_LOG" '"account": "coalab1"'
assert_contains "character request has the character name" "$FAKE_LOG" '"character": "Coalabnecro"'
assert_contains "character request has the class" "$FAKE_LOG" '"class": 23'
assert_contains "character request has the level" "$FAKE_LOG" '"level": 20'
assert_contains "character request has the learn list" "$FAKE_LOG" '"learn": [704723, 704724]'
assert_contains "character request has the items list" "$FAKE_LOG" '"items": [9701803]'
assert_contains "character prints the Go module's JSON result" "$WORK/out" '"created": true'

: > "$FAKE_LOG"
if FAKE_GO_APPLY_FAIL=1 run_lab character --slot 2 --account coalab1 --character Coalabnecro --race 5 --class 24; then
    fail "character surfaces a refused class change"
else
    pass "character surfaces a refused class change"
fi
assert_contains "character failure message" "$WORK/out" "character setup failed"

# --- character without --account: derives a dedicated account, generates and reuses a password,
#     passes it and dedicated=true through the request, and warns only on the --account path ---

: > "$FAKE_LOG"
FAKE_GO_APPLY_OUT='{"account": "COALABDEDIBOT", "character": "Dedibot", "class": 23, "created": true, "account_characters": ["Dedibot"]}' \
    run_lab character --slot 2 --character Dedibot --race 5 --class 23
assert_eq "character without --account exits 0" "$?" "0"
assert_contains "derived account: prefix + upper-cased name" "$FAKE_LOG" '"account": "COALABDEDIBOT"'
assert_contains "derived account request is marked dedicated" "$FAKE_LOG" '"dedicated": true'
assert_not_contains "character without --account does not warn (account_characters has 1 entry)" \
    "$WORK/out" "coa-client-lab login cannot"
pwfile="$COA_LAB_ROOT/secrets/coalabdedibot.password"
assert_file "dedicated account password file created" "$pwfile"
assert_eq "dedicated account password file is mode 600" "$(stat -c %a "$pwfile")" "600"
password1=$(cat "$pwfile")
[[ -n "$password1" ]] && pass "dedicated account password file is non-empty" || fail "dedicated account password file is empty"
assert_contains "generated password sent in the request" "$FAKE_LOG" "\"password\": \"$password1\""

# Truncation: LabAccountPrefix (3) + the character name, upper-cased, cut to MaxAccountLen (17):
# see DeriveAccount in scripts/lab-character/character_test.go (MAX_ACCOUNT_STR,
# src/server/game/Accounts/AccountMgr.h:34).
: > "$FAKE_LOG"
FAKE_GO_APPLY_OUT='{"account": "COALABSUPERCALIFR", "character": "Supercalifragilisticexpialidocious", "class": 23, "created": true, "account_characters": ["Supercalifragilisticexpialidocious"]}' \
    run_lab character --slot 2 --character Supercalifragilisticexpialidocious --race 5 --class 23
assert_eq "character with a long name exits 0" "$?" "0"
assert_contains "derived account is truncated to 17 characters" "$FAKE_LOG" '"account": "COALABSUPERCALIFR"'

# A second call for the same character reuses the same password instead of generating a new one.
: > "$FAKE_LOG"
FAKE_GO_APPLY_OUT='{"account": "COALABDEDIBOT", "character": "Dedibot", "class": 23, "created": false, "account_characters": ["Dedibot"]}' \
    run_lab character --slot 2 --character Dedibot --race 5 --class 23 --level 5
assert_eq "second call for the same character exits 0" "$?" "0"
assert_eq "dedicated account password file is reused, not regenerated" "$(cat "$pwfile")" "$password1"
assert_contains "second call sends the same reused password" "$FAKE_LOG" "\"password\": \"$password1\""

# With an explicit --account, today's behavior is kept: empty password (e2eharness.DefaultPassword
# applies), dedicated=false, and a warning once the account's final character count is 2+ (the Go
# module reports this; the fake stands in for its account_characters field).
: > "$FAKE_LOG"
FAKE_GO_APPLY_OUT='{"account": "SHARED1", "character": "Second", "class": 23, "created": true, "account_characters": ["First", "Second"]}' \
    run_lab character --slot 2 --account shared1 --character Second --race 5 --class 23
assert_eq "character with explicit --account exits 0" "$?" "0"
assert_contains "explicit --account request has no password override" "$FAKE_LOG" '"password": ""'
assert_contains "explicit --account request is not dedicated" "$FAKE_LOG" '"dedicated": false'
assert_contains "explicit --account warns once the account holds 2+ characters" "$WORK/out" \
    "account shared1 now holds 2 characters"
assert_absent "explicit --account does not create a secrets file" "$COA_LAB_ROOT/secrets/shared1.password"

: > "$FAKE_LOG"
FAKE_GO_APPLY_OUT='{"account": "SHARED1", "character": "First", "class": 23, "created": true, "account_characters": ["First"]}' \
    run_lab character --slot 2 --account shared1 --character First --race 5 --class 23
assert_not_contains "explicit --account with 1 character does not warn" "$WORK/out" "coa-client-lab login cannot"

# --- login: character-select lookup (navigation itself is disabled; see select_character's comment:
#     live on slot 2 the character list wraps circularly instead of clamping at the top, so a fixed
#     Up-then-Down sequence is not reliable and was found live to pick the WRONG character once) ---

run_lab start 3

: > "$FAKE_LOG"
FAKE_GO_INDEX_OUT='{"found": true, "index": 2}' run_lab login coalab1 secretpw Coalabnecro
assert_eq "login with a found character exits 0" "$?" "0"
assert_not_contains "login does not navigate (disabled: wraps on the real client)" "$FAKE_LOG" "key --window 4242 Up"
assert_not_contains "login does not send Down either" "$FAKE_LOG" "key --window 4242 Down"
assert_contains "login reports the found index instead of acting on it" "$WORK/out" \
    "Coalabnecro is at character-list index 2"

: > "$FAKE_LOG"
FAKE_GO_INDEX_FAIL=1 run_lab login coalab1 secretpw Coalabnecro
assert_eq "login still exits 0 when the index lookup fails" "$?" "0"
assert_contains "login warns and falls back to the default highlight" "$WORK/out" \
    "could not find Coalabnecro in coalab1's character list"

: > "$FAKE_LOG"
run_lab login coalab1 secretpw
assert_not_contains "login without CHARACTER never looks up or navigates" "$FAKE_LOG" "key --window 4242 Up"

# --- login CHARACTER: the dedicated-account form, resolving account and password the same way
#     `character` derived and stored them (password1/pwfile from the character tests above) ---

: > "$FAKE_LOG"
run_lab login Dedibot
assert_eq "login CHARACTER (dedicated account) exits 0" "$?" "0"
assert_contains "login CHARACTER types the derived account" "$FAKE_LOG" "type --window 4242 --delay 60 COALABDEDIBOT"
assert_contains "login CHARACTER types the stored password" "$FAKE_LOG" "type --window 4242 --delay 60 $password1"

if run_lab login Nodedicatedaccount; then
    fail "login CHARACTER refuses when no dedicated account exists"
else
    pass "login CHARACTER refuses when no dedicated account exists"
fi
assert_contains "login CHARACTER refusal names the missing account" "$WORK/out" "no dedicated lab account for Nodedicatedaccount"

if run_lab login 'Bad Name'; then
    fail "login CHARACTER refuses a non-letters name"
else
    pass "login CHARACTER refuses a non-letters name"
fi

if run_lab login one two three four; then
    fail "login refuses more than 3 arguments"
else
    pass "login refuses more than 3 arguments"
fi

printf '\n%s failure(s)\n' "$FAILURES"
exit $((FAILURES > 0))
