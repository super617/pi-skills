#!/bin/bash
# board-skills.sh -- manage the board-side skill set on this machine.
#
# Two layers, and keeping them separate is the whole point:
#
#   /usr/share/pi-skills      read-only snapshot shipped by the firmware
#                             (the pi-skills package). Baseline: always there,
#                             never needs the network.
#   ~/.pi/agent/pi-skills     a newer checkout owned by the user, created only
#                             when they accept an update. Overrides the snapshot.
#
# ~/.pi/agent/skills/<name> is a symlink into whichever layer is active, so pi
# picks the skills up from its normal user skills directory with no settings
# change, and switching layers is just repointing the links.
#
#   board-skills status            what is installed, from which layer
#   board-skills sync              (re)create the links; safe to rerun
#   board-skills check             exit 0 = newer version exists, 1 = none
#   board-skills update            fetch the newer version and relink
#   board-skills autostart         sync, then prompt only if an update exists
#   board-skills dismiss           do not ask again for the current remote version
#
# No root anywhere: the system snapshot is only read.

set -u

REPO_SLUG="${PI_SKILLS_SLUG:-super617/pi-skills}"
REPO_URL="${PI_SKILLS_REPO:-https://github.com/$REPO_SLUG}"
HOME_DIR="${PI_AGENT_HOME:-$HOME}"
AGENT_DIR="$HOME_DIR/.pi/agent"
SKILLS_DIR="$AGENT_DIR/skills"
USER_CHECKOUT="$AGENT_DIR/pi-skills"
SYSTEM_SNAPSHOT="${PI_SKILLS_SYSTEM:-/usr/share/pi-skills}"
STATE_FILE="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/pi-agent-setup/skills.json"
NET_TIMEOUT="${PI_SKILLS_NET_TIMEOUT:-12}"

say()  { printf '%s\n' "$*"; }
warn() { printf 'board-skills: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

local_version() {
    if [ -r "$USER_CHECKOUT/VERSION" ]; then
        tr -d ' \n' < "$USER_CHECKOUT/VERSION"
    elif [ -r "$SYSTEM_SNAPSHOT/VERSION" ]; then
        tr -d ' \n' < "$SYSTEM_SNAPSHOT/VERSION"
    else
        echo unknown
    fi
}

active_root() {
    # The user checkout wins when it exists: it is the newer one by definition.
    if [ -d "$USER_CHECKOUT/skills" ]; then
        echo "$USER_CHECKOUT"
    elif [ -d "$SYSTEM_SNAPSHOT/skills" ]; then
        echo "$SYSTEM_SNAPSHOT"
    fi
}

state_get() {
    [ -r "$STATE_FILE" ] || return 1
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STATE_FILE" | head -1
}

state_put() {
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || return 1
    # Build the body without its braces: "k": v, "k": v
    local body=""
    if [ -r "$STATE_FILE" ]; then
        body=$(tr -d '\n' < "$STATE_FILE")
        body="${body#\{}"; body="${body%\}}"
    fi
    local key
    while [ $# -ge 2 ]; do
        key="$1"
        # Replace rather than append: repeated syncs must not grow the file with
        # duplicate keys (valid JSON, but confusing to read and ambiguous).
        body=$(printf '%s' "$body" | sed \
            "s/\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"[[:space:]]*,\{0,1\}[[:space:]]*//")
        body=$(printf '%s' "$body" | sed 's/[[:space:]]*,[[:space:]]*$//')
        if [ -z "$body" ]; then body="\"$key\": $2"
        else body="$body, \"$key\": $2"; fi
        shift 2
    done
    printf '{%s}\n' "$body" > "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# sync: point ~/.pi/agent/skills/* at the active layer
# ---------------------------------------------------------------------------
do_sync() {
    local root
    root=$(active_root)
    if [ -z "$root" ]; then
        warn "no skill tree found in $USER_CHECKOUT or $SYSTEM_SNAPSHOT"
        return 1
    fi
    mkdir -p "$SKILLS_DIR" || return 1

    local linked=0 d name target
    for d in "$root"/skills/*/; do
        [ -f "$d/SKILL.md" ] || continue
        name=$(basename "$d")
        target="$SKILLS_DIR/$name"
        if [ -L "$target" ]; then
            rm -f "$target"
        elif [ -e "$target" ]; then
            warn "skip $name: $target exists and is not a symlink"
            continue
        fi
        ln -s "${d%/}" "$target" || continue
        linked=$((linked + 1))
    done

    # Prune links whose skill no longer exists in the active layer (e.g. an
    # update removed one), but never touch anything that is not our symlink.
    for target in "$SKILLS_DIR"/*; do
        [ -L "$target" ] || continue
        name=$(basename "$target")
        [ -e "$target" ] && continue          # still points at something
        if [ -e "$root/skills/$name" ] || [ -e "$SYSTEM_SNAPSHOT/skills/$name" ]; then
            continue
        fi
        rm -f "$target"
    done

    state_put synced_at "\"$(date +%s)\"" synced_from "\"$root\"" 2>/dev/null || true
    say "skills synced from $root ($linked linked) -> $SKILLS_DIR"
}

# ---------------------------------------------------------------------------
# remote version: one string from raw.githubusercontent, no git needed
# ---------------------------------------------------------------------------
fetch_remote() {
    # Prints the remote version, or fails. Every branch must fail on empty
    # output: a pipeline's status is the status of its last command (tr/head),
    # so a curl timeout would otherwise look like success with an empty string.
    local url="https://raw.githubusercontent.com/$REPO_SLUG/main/VERSION"
    local out=""
    if have curl; then
        out=$(timeout "$NET_TIMEOUT" curl -fsS -m "$NET_TIMEOUT" "$url" 2>/dev/null | tr -d ' \n')
    elif have python3; then
        out=$(timeout "$NET_TIMEOUT" python3 -c '
import sys, urllib.request
try:
    print(urllib.request.urlopen(sys.argv[1], timeout=10).read().decode().strip())
except Exception:
    sys.exit(1)
' "$url" 2>/dev/null | tr -d ' \n')
    elif have wget; then
        out=$(timeout "$NET_TIMEOUT" wget -qO- "$url" 2>/dev/null | tr -d ' \n')
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

version_gt() {
    # "1.2.10" > "1.2.9". Returns 0 when $1 is newer than $2.
    [ "$1" = "$2" ] && return 1
    local IFS=.
    # shellcheck disable=SC2206
    local a=($1) b=($2) i
    for i in 0 1 2 3; do
        local x=${a[$i]:-0} y=${b[$i]:-0}
        case "$x$y" in
            *[!0-9]*)
                # Not numeric somewhere: fall back to a plain inequality, which
                # the caller already established.
                return 0 ;;
        esac
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 1
}

needs_update() {
    # 0 = yes, 1 = no, 2 = cannot tell (offline)
    local local_v remote_v
    local_v=$(local_version)
    remote_v=$(fetch_remote) || return 2
    [ -z "$remote_v" ] && return 2
    [ "$remote_v" = "$local_v" ] && return 1
    version_gt "$remote_v" "$local_v" && return 0
    return 1
}

# ---------------------------------------------------------------------------
# update
# ---------------------------------------------------------------------------
do_update() {
    local remote_v
    remote_v=$(fetch_remote) || {
        warn "cannot reach GitHub to read $REPO_SLUG"
        return 1
    }

    if [ -d "$USER_CHECKOUT/.git" ] && have git; then
        say "updating existing checkout $USER_CHECKOUT"
        git -C "$USER_CHECKOUT" pull --ff-only --quiet || {
            warn "git pull failed in $USER_CHECKOUT"
            return 1
        }
    elif have git; then
        mkdir -p "$AGENT_DIR"
        [ -d "$USER_CHECKOUT" ] && mv "$USER_CHECKOUT" "$USER_CHECKOUT.old.$$"
        say "cloning $REPO_URL"
        if ! git clone --quiet --depth 1 "$REPO_URL" "$USER_CHECKOUT"; then
            [ -d "$USER_CHECKOUT.old.$$" ] && mv "$USER_CHECKOUT.old.$$" "$USER_CHECKOUT"
            warn "clone failed (no network, or the repo needs credentials)"
            return 1
        fi
        rm -rf "$USER_CHECKOUT.old.$$"
    else
        warn "git is not installed on this image; cannot update in place"
        warn "the firmware snapshot in $SYSTEM_SNAPSHOT stays as it is"
        return 1
    fi

    do_sync
    state_put updated_at "\"$(date +%s)\"" installed "\"$(local_version)\"" \
              last_result '"updated"' 2>/dev/null || true
    say "updated to $(local_version)"
    say "reopen pi (or /reload) to pick up the new skills"
}

# ---------------------------------------------------------------------------
# prompt
# ---------------------------------------------------------------------------
do_prompt() {
    local local_v remote_v
    local_v=$(local_version)
    remote_v=$(fetch_remote) || exit 0          # offline: silent

    if [ "$(state_get dismissed || true)" = "$remote_v" ]; then
        exit 0
    fi

    # A GUI dialog when there is a desktop session, a terminal question when
    # there is a tty, silence otherwise (cron, systemd, no session yet).
    if have python3 && [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
        if python3 "$(dirname "$0")/board-skills-prompt.py" "$local_v" "$remote_v" 2>/dev/null; then
            do_update
            exit $?
        fi
        exit 0
    fi

    if [ -t 0 ] && [ -t 1 ]; then
        say ""
        say "板端技能包有更新：已安装 ${local_v}，远端 ${remote_v}"
        printf '现在更新吗？[y/N] '
        local answer="n"
        read -r answer 2>/dev/null </dev/tty || true
        case "$answer" in
            y|Y|yes|YES) do_update; exit $? ;;
            *) state_put dismissed "\"$remote_v\"" 2>/dev/null || true
               say "已跳过，下次有新提交再提醒"; exit 0 ;;
        esac
    fi
    exit 0
}

# ---------------------------------------------------------------------------
case "${1:-status}" in
    status)
        root=$(active_root)
        say "system snapshot: $SYSTEM_SNAPSHOT $( [ -d "$SYSTEM_SNAPSHOT" ] && echo "(present, $(tr -d ' \n' < "$SYSTEM_SNAPSHOT/VERSION" 2>/dev/null || echo '?') )" || echo "(absent)")"
        say "user checkout:   $USER_CHECKOUT $( [ -d "$USER_CHECKOUT" ] && echo "(present)" || echo "(absent)")"
        say "active layer:    ${root:-none}"
        say "installed:       $(local_version)"
        if r=$(fetch_remote); then say "remote:          $r"
        else say "remote:          unreachable"; fi
        n=$(ls -1 "$SKILLS_DIR" 2>/dev/null | wc -l | tr -d ' ')
        say "linked skills:   $n in $SKILLS_DIR"
        [ -r "$STATE_FILE" ] && { say "state file:      $STATE_FILE"; sed 's/^/                 /' "$STATE_FILE"; }
        ;;
    sync)
        do_sync
        ;;
    check)
        needs_update
        rc=$?
        case $rc in
            0) say "update available: $(local_version) -> $(fetch_remote)"; exit 0 ;;
            1) say "up to date: $(local_version)"; exit 1 ;;
            *) say "cannot check (offline)"; exit 1 ;;
        esac
        ;;
    update)
        do_update
        ;;
    dismiss)
        v=$(fetch_remote) || v=$(local_version)
        state_put dismissed "\"$v\"" 2>/dev/null || true
        say "dismissed $v"
        ;;
    autostart)
        do_sync >/dev/null 2>&1 || exit 0
        needs_update
        case $? in
            0) do_prompt ;;
            *) exit 0 ;;
        esac
        ;;
    -h|--help|help)
        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        warn "unknown command $1 (try: status sync check update autostart dismiss)"
        exit 2
        ;;
esac
