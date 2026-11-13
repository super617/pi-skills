#!/bin/bash
# board-shot.sh -- take a screenshot on a Quectel PI board.
#
# This board has no gnome-screenshot and no grim. Under GNOME the only working
# path is the xdg-desktop-portal Screenshot interface, and it is asynchronous:
# the gdbus call returns a request handle, and the PNG shows up in ~/Pictures a
# moment later. This script hides both details.
#
#   bash board-shot.sh                  # copy newest shot to /tmp/board-shot.png
#   bash board-shot.sh /tmp/a.png       # ... to a given path
#   bash board-shot.sh --list           # only list existing shots
#
# Read-only except for the new PNG the portal writes into ~/Pictures.

set -u

TARGET="/tmp/board-shot.png"
LIST_ONLY=no
for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --list)    LIST_ONLY=yes ;;
        *)         TARGET="$arg" ;;
    esac
done

# Find the logged-in desktop user and its runtime dir.
DUSER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3!="-" && $2>=1000 {print $3; exit}')
[ -z "${DUSER:-}" ] && DUSER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
if [ -z "${DUSER:-}" ]; then
    echo "board-shot: no desktop user found (is anyone logged in on the screen?)" >&2
    exit 1
fi
DUID=$(id -u "$DUSER")
RUNTIME="/run/user/$DUID"
PICS=$(sudo -u "$DUSER" sh -c 'echo $HOME')/Pictures

if [ ! -d "$RUNTIME" ]; then
    echo "board-shot: $RUNTIME missing -- desktop session is not running" >&2
    exit 1
fi

if [ "$LIST_ONLY" = yes ]; then
    ls -t "$PICS"/Screenshot-*.png 2>/dev/null | head -10
    exit 0
fi

# Session pinned by its own dbus address, so this works from a root shell too.
run_as_user() {
    sudo -u "$DUSER" env \
        XDG_RUNTIME_DIR="$RUNTIME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus" \
        "$@"
}

if ! run_as_user gdbus call --session \
        --dest org.freedesktop.portal.Desktop --object-path / \
        --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
    echo "board-shot: xdg-desktop-portal is not answering on the session bus" >&2
    echo "            under Weston, use weston-screenshooter instead" >&2
    exit 1
fi

before=$(ls -t "$PICS"/Screenshot-*.png 2>/dev/null | head -1)

# The interactive flag is what makes the portal grab the screen without asking;
# handle_token only names the request object.
token="piskill$$"
run_as_user gdbus call --session \
    --dest org.freedesktop.portal.Desktop \
    --object-path /org/freedesktop/portal/desktop \
    --method org.freedesktop.portal.Screenshot.Screenshot \
    "" "{\"interactive\": <false>, \"handle_token\": <\"$token\">}" >/dev/null 2>&1

# The portal is asynchronous; poll for the new file instead of guessing a delay.
newest=""
for _ in $(seq 1 40); do
    sleep 0.25
    newest=$(ls -t "$PICS"/Screenshot-*.png 2>/dev/null | head -1)
    if [ -n "$newest" ] && [ "$newest" != "$before" ]; then
        break
    fi
    newest=""
done

if [ -z "$newest" ]; then
    echo "board-shot: no new file appeared in $PICS after 10s" >&2
    echo "            (screen locked? portal refusing? try: $0 --list)" >&2
    exit 1
fi

cp -f "$newest" "$TARGET" || {
    echo "board-shot: could not copy to $TARGET" >&2
    exit 1
}
echo "$TARGET"
echo "source: $newest"
ls -l "$TARGET"
