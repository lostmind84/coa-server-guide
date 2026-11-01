#!/usr/bin/env bash
# Link the guide's agent tooling into place and report which prerequisites are missing.
#
#   scripts/install-agent-tools.sh --check          report only, change nothing
#   scripts/install-agent-tools.sh                  link scripts, Claude Code skills and the triage command
#   scripts/install-agent-tools.sh --codex          also link the Codex skills
#
# Options: --bin-dir DIR (default ~/.local/bin), --claude-dir DIR (default ~/.claude),
#          --codex-dir DIR (default ~/.agents).
# Idempotent: an existing correct link is left alone, a real file or a link to elsewhere is never replaced.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
CLAUDE_DIR="${HOME}/.claude"
CODEX_DIR="${HOME}/.agents"
CHECK=0
CODEX=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK=1; shift ;;
        --codex) CODEX=1; shift ;;
        --bin-dir) BIN_DIR="${2:?--bin-dir needs a directory}"; shift 2 ;;
        --claude-dir) CLAUDE_DIR="${2:?--claude-dir needs a directory}"; shift 2 ;;
        --codex-dir) CODEX_DIR="${2:?--codex-dir needs a directory}"; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

PROBLEMS=0
say() { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
problem() { printf 'MISS  %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
ok() { printf 'ok    %s\n' "$*"; }

platform_check() {
    local kernel
    kernel=$(uname -s 2> /dev/null || echo unknown)
    case "$kernel" in
        Linux)
            if grep -qi microsoft /proc/version 2> /dev/null; then
                warn "WSL detected: the lab client needs gamescope, X11 input and a reflink filesystem, which a default WSL"
                warn "install lacks. Adapt the setup (see below) before relying on the lab tools."
                adapt_notice
            fi
            ;;
        *)
            warn "platform '$kernel': the tooling was written and tested on Linux only."
            adapt_notice
            ;;
    esac
}

adapt_notice() {
    cat <<'EOF'
NOTE for the agent reading this: the tools in this guide (coa-slot, coa-client-lab, coa-lab-*) are bash scripts for
Linux (Docker, /srv/coa and ~/CoaServer paths, reflink copies, gamescope, xdotool, Wine/Proton). They were never run
on this platform. Adapt the setup so it works here: translate paths and commands, replace what does not exist with
an equivalent (for example the lab client copy: on Windows the client runs natively), and keep going. Tell the user
what you changed, and report as "not verified" any result that rests on an adaptation you could not test.
EOF
}

have() { command -v "$1" > /dev/null 2>&1; }

need() { # need COMMAND "used by" [optional]
    if have "$1"; then
        ok "$1 ($2)"
    elif [[ "${3:-}" == optional ]]; then
        warn "$1 not found ($2; optional)"
    else
        problem "$1 not found ($2)"
    fi
}

check_prerequisites() {
    say "== Prerequisites"
    need git "everything"
    need python3 "coa-preflight.py, coa-lab-*, tests"
    need docker "coa-slot, the server stack"
    if have docker && docker compose version > /dev/null 2>&1; then
        ok "docker compose (coa-slot)"
    else
        problem "docker compose not available (coa-slot)"
    fi
    need gh "triage and PR workflow" optional
    need go "coa-slot create, coa-client-lab character (Ghost e2e harness)"
    need mpqcli "preflight DBC checks (--skip-dbc skips them)"
    need lua5.1 "CoaProbe addon tests only" optional
    need gamescope "coa-client-lab"
    need xdotool "coa-client-lab"
    need magick "coa-client-lab screenshots"
    need ffmpeg "coa-client-lab screenshot --video-seconds" optional
    need umu-run "launching the Windows client under Proton" optional
    need hyprctl "coa-client-lab nested display only; the headless display needs gamescope alone" optional
    need pactl "muting the lab client" optional
    local fs
    fs=$(stat -f -c %T "$HOME" 2> /dev/null || echo unknown)
    case "$fs" in
        btrfs|xfs) ok "home filesystem is $fs (reflink copies for coa-client-lab create)" ;;
        *) warn "home filesystem is $fs: coa-client-lab create needs reflink copies (btrfs or xfs); other filesystems were not tested" ;;
    esac
    for dir in "${COA_MAIN_REPO:-$HOME/Projects/azerothcore-wotlk-coa}" "${COA_GHOST_REPO:-$HOME/Projects/ConquestOfAzerothGhost}"; do
        if [[ -d "$dir" ]]; then ok "found $dir"; else warn "missing $dir (defaults assume this layout; override with COA_MAIN_REPO or COA_GHOST_REPO)"; fi
    done
}

link() { # link TARGET LINKPATH
    local target="$1" path="$2" current
    if [[ -L "$path" ]]; then
        current=$(readlink "$path")
        if [[ "$current" == "$target" ]]; then ok "linked $path"; return 0; fi
        warn "$path is a link to $current, left alone (remove it to relink)"
        return 0
    fi
    if [[ -e "$path" ]]; then
        warn "$path exists and is not a link, left alone"
        return 0
    fi
    if [[ "$CHECK" == 1 ]]; then
        problem "not linked: $path -> $target"
        return 0
    fi
    mkdir -p "$(dirname "$path")" && ln -s "$target" "$path" && ok "linked $path -> $target"
}

link_all() {
    local script skill
    say "== Scripts into $BIN_DIR"
    for script in coa-slot coa-client-lab coa-lab-relay coa-lab-footprint coa-lab-mem coa-lab-packets coa-worktree-cleanup coa-obtainable coa-reference; do
        link "$ROOT/scripts/$script" "$BIN_DIR/$script"
    done
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) warn "$BIN_DIR is not on PATH" ;;
    esac
    say "== Claude Code skills and command into $CLAUDE_DIR"
    for skill in coa-slot-workflow coa-client-check coa-triage coa-fix-issues-batch; do
        [[ -d "$ROOT/skills/$skill" ]] && link "$ROOT/skills/$skill" "$CLAUDE_DIR/skills/$skill"
    done
    link "$ROOT/agents/coa-triage.md" "$CLAUDE_DIR/commands/coa-triage.md"
    if [[ "$CODEX" == 1 ]]; then
        say "== Codex skills into $CODEX_DIR"
        for skill in coa-triage coa-fix-issues-batch; do
            [[ -d "$ROOT/skills/$skill" ]] && link "$ROOT/skills/$skill" "$CODEX_DIR/skills/$skill"
        done
    fi
}

platform_check
check_prerequisites
link_all
say
if [[ "$CHECK" == 1 ]]; then
    say "Check done: $PROBLEMS item(s) missing."
else
    say "Done. $PROBLEMS prerequisite(s) missing; the links above are in place."
fi
say "Next: read AGENTS.md, then docs/tooling/slots-and-preflight.md."
[[ "$PROBLEMS" == 0 ]]
