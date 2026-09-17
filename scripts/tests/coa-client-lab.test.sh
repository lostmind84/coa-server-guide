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
case "$1" in
    search) echo 4242 ;;
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
assert_contains "status shows running" "$WORK/out" "gamescope: running (pid"

: > "$FAKE_LOG"
run_lab chat "/say hello lab"
assert_contains "chat opens the edit box" "$FAKE_LOG" "xdotool DISPLAY=:77 key --window 4242 Return"
assert_contains "chat types text" "$FAKE_LOG" "xdotool DISPLAY=:77 type --window 4242 --delay 40 /say hello lab"

: > "$FAKE_LOG"
run_lab key Escape Tab
assert_contains "key sends keys" "$FAKE_LOG" "xdotool DISPLAY=:77 key --window 4242 Escape Tab"

: > "$FAKE_LOG"
run_lab login labspike secretpw
assert_contains "login clicks the account field" "$FAKE_LOG" "mousemove --window 4242 640 378 click 1"
assert_contains "login types account" "$FAKE_LOG" "type --window 4242 --delay 60 labspike"
assert_contains "login types password" "$FAKE_LOG" "type --window 4242 --delay 60 secretpw"
assert_eq "login enters world twice Return" "$(grep -c 'key --window 4242 Return$' "$FAKE_LOG")" "2"

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

printf '\n%s failure(s)\n' "$FAILURES"
exit $((FAILURES > 0))
