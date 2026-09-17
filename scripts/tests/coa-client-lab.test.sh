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

# same-path guard in create
if COA_LAB_PREFIX="$COA_USER_PREFIX" run_lab create; then fail "create over user prefix refused"; else pass "create over user prefix refused"; fi
assert_contains "same-path guard message" "$WORK/out" "lab paths equal user paths"
assert_file "user prefix protected" "$COA_USER_PREFIX/system.reg"
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
assert_contains "status shows running" "$WORK/out" "running"

# INPUT TESTS (Task 3)

# STOP TESTS (Task 4)

printf '\n%s failure(s)\n' "$FAILURES"
exit $((FAILURES > 0))
