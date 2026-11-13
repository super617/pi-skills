#!/bin/bash
# board-check.sh -- one-shot self check for a Quectel PI (QCS6490) board.
#
# Prints a snapshot an agent (or a person) can read to know what this machine
# actually is: OS, kernel, user, and which subsystems answer. It is read-only:
# nothing here writes a sysfs node, changes a service, opens a device for
# streaming, or needs the network.
#
#   bash board-check.sh            # everything
#   bash board-check.sh --short    # only the parts that change diagnosis
#
# Exit code is always 0: this is a report, not a test.

set -u

SHORT=no
for arg in "$@"; do
    case "$arg" in
        --short|-s) SHORT=yes ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf '%s\n' "$*"; }
sect() { printf '\n== %s ==\n' "$*"; }
kv()   { printf '%-26s %s\n' "$1" "$2"; }

# The desktop session of the user who is logged in on the screen. Everything
# that talks to PipeWire, the portal or a Wayland compositor needs these two
# variables, and a root shell (adb, serial) does not inherit them.
DUSER=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$3!="-" && $2>=1000 {print $3; exit}')
[ -z "${DUSER:-}" ] && DUSER=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)
DUID=$(id -u "$DUSER" 2>/dev/null || echo 1000)
DRUNTIME="/run/user/$DUID"

sect "board"
kv model "$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
kv os "$(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
kv codename "$(grep -m1 VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2)"
kv kernel "$(uname -r)"
kv arch "$(uname -m)"
kv desktop_user "$DUSER (uid $DUID)"

if [ "$(id -u)" = 0 ]; then kv "this shell" "root (dmesg ok, GUI needs session vars)"
else kv "this shell" "uid $(id -u) $(id -gn)"; fi

# ---------------------------------------------------------------------------
# display
# ---------------------------------------------------------------------------
sect "display"
if [ -d /sys/class/drm ]; then
    for c in /sys/class/drm/card*-*/status; do
        [ -r "$c" ] || continue
        n=$(basename "$(dirname "$c")")
        # Only connectors: cardN-XXX-N
        case "$n" in card[0-9]*-*) printf '%-26s %s\n' "$n" "$(cat "$c")" ;; esac
    done
    # fb size is what the compositor actually drives
    [ -r /sys/class/graphics/fb0/virtual_size ] && \
        kv "framebuffer" "$(cat /sys/class/graphics/fb0/virtual_size)"
    # Which bridge is live (HDMI here goes through LT9611, not native HDMI).
    if [ -r /sys/kernel/debug/dri/0/bridge_chains ]; then
        r=$(head -20 /sys/kernel/debug/dri/0/bridge_chains 2>/dev/null | grep -o 'lontium,lt9611[a-z]*' | head -1)
        kv "hdmi bridge" "${r:-not on any encoder chain}"
    elif [ "$(id -u)" = 0 ]; then
        kv "hdmi bridge" "not in debugfs (no DRM debugfs?)"
    else
        kv "hdmi bridge" "need root: sudo cat /sys/kernel/debug/dri/0/bridge_chains"
    fi
    kv backlight "$(ls /sys/class/backlight 2>/dev/null | tr '\n' ' ' | sed 's/ $//;s/^$/(none)/')"
else
    kv drm "no /sys/class/drm"
fi

# ---------------------------------------------------------------------------
# audio
# ---------------------------------------------------------------------------
sect "audio"
if [ -r /proc/asound/cards ]; then
    awk 'NF && $1 ~ /^[0-9]+$/ {print "card " $1 ": " $NF}' /proc/asound/cards | head -4
else
    kv sound "no /proc/asound/cards"
fi
for t in wpctl pw-play pw-record pactl paplay tinyplay tinymix aplay; do
    have "$t" && printf '  %-12s ok\n' "$t"
done
if have wpctl; then
    sink=$(sudo -u "$DUSER" env XDG_RUNTIME_DIR="$DRUNTIME" \
               DBUS_SESSION_BUS_ADDRESS="unix:path=$DRUNTIME/bus" \
               wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' | grep -v '^ *$' | head -4)
    if [ -n "$(printf '%s' "$sink" | tr -d ' \n')" ]; then
        printf '%s\n' "$sink"
    else
        kv "pipewire" "no sinks (not running, or no session)"
    fi
fi

# ---------------------------------------------------------------------------
# video / accel
# ---------------------------------------------------------------------------
if [ "$SHORT" = no ]; then
    sect "accel"
    for n in 3d00000.gpu; do
        d="/sys/class/devfreq/$n"
        [ -d "$d" ] || continue
        kv "gpu freq" "$(( $(cat "$d/cur_freq") / 1000000 ))MHz / max $(( $(cat "$d/max_freq") / 1000000 ))MHz"
    done
    kv "fastrpc cdsp" "$([ -e /dev/fastrpc-cdsp ] && echo present || echo MISSING)"
    for u in cdsprpcd adsprpcd; do
        printf '  %-12s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)"
    done
    procs=""
    for n in /dev/video*; do
        [ -e "$n" ] || continue
        nm=$(cat "/sys/class/video4linux/$(basename "$n")/name" 2>/dev/null)
        procs="$procs $(basename "$n"):${nm:-?}"
    done
    kv "video nodes" "${procs:-none}"
    have vainfo && kv "vaapi" "$(vainfo 2>/dev/null | grep -m1 'Driver version' | cut -c1-60 || echo 'needs display env')"
fi

# ---------------------------------------------------------------------------
# network
# ---------------------------------------------------------------------------
sect "network"
if [ -d /sys/class/net ]; then
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        printf '  %-12s %-10s %s\n' "$n" \
            "$(cat "$i/operstate" 2>/dev/null)" \
            "$(cat "$i/address" 2>/dev/null)"
    done
fi
if have ethtool; then
    eth=$(ls /sys/class/net | grep -m1 '^eth')
    [ -n "$eth" ] && kv "ethtool $eth" "$(ethtool "$eth" 2>/dev/null | grep -Eo 'Speed: [0-9]+Mb/s|Link detected: [a-z]+' | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# radio
# ---------------------------------------------------------------------------
sect "wireless"
for r in /sys/class/rfkill/*; do
    [ -r "$r/name" ] || continue
    printf '  %-12s type=%-10s soft=%s hard=%s\n' \
        "$(cat "$r/name")" "$(cat "$r/type")" "$(cat "$r/soft")" "$(cat "$r/hard")"
done
[ -e /sys/devices/platform/rfkill/bt_en ] && \
    kv bt_en "$(cat /sys/devices/platform/rfkill/bt_en 2>/dev/null || echo 'need root')"
have hciconfig && kv bluetooth "$(hciconfig 2>/dev/null | grep -m1 -E 'UP RUNNING|DOWN' | tr -s ' ')"
kv bluetoothd "$(systemctl is-active bluetooth 2>/dev/null)"

# ---------------------------------------------------------------------------
# storage
# ---------------------------------------------------------------------------
if [ "$SHORT" = no ]; then
    sect "storage"
    if have lsblk; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | grep -vE '^loop|^zram' | head -12
    fi
    kv root "$(findmnt -no SOURCE,FSTYPE / 2>/dev/null)"
    if have df; then
        printf '  %-12s %s\n' "free /" "$(df -h / 2>/dev/null | awk 'NR==2{print $4" avail of "$2}')"
    fi
fi

# ---------------------------------------------------------------------------
# thermal / fan / power
# ---------------------------------------------------------------------------
sect "thermal"
if [ -d /sys/class/thermal ]; then
    for z in /sys/class/thermal/thermal_zone*/; do
        t=$(cat "$z/type" 2>/dev/null); v=$(cat "$z/temp" 2>/dev/null)
        [ -n "$t" ] || continue
        case "$t" in
            cpu0*|gpuss0*|nspss0*|video*|ddr*) printf '  %-16s %s C\n' "$t" "$((v/1000))" ;;
        esac
    done
fi
FAN=""
for d in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$d/name" 2>/dev/null)" = pwmfan ] && FAN="$d"
done
if [ -n "$FAN" ]; then
    kv "fan ($FAN)" "pwm1=$(cat "$FAN/pwm1" 2>/dev/null) enable=$(cat "$FAN/pwm1_enable" 2>/dev/null) rpm=$(cat "$FAN/fan1_input" 2>/dev/null)"
else
    kv fan "no hwmon named pwmfan"
fi
kv fan_ctrl "$(systemctl is-active fan_ctrl 2>/dev/null)"
if [ -e /var/persist/fct_done_flag ]; then
    kv "factory flag" "present -> NORMAL mode"
else
    kv "factory flag" "ABSENT -> FACTORY mode"
fi
[ -r /sys/module/typec_ucsi/parameters/fct_client ] && \
    kv fct_client "$(cat /sys/module/typec_ucsi/parameters/fct_client)"

# ---------------------------------------------------------------------------
# usb
# ---------------------------------------------------------------------------
sect "usb"
kv udc "$(ls /sys/class/udc 2>/dev/null | tr '\n' ' ')"
[ -e /sys/class/udc ] && for u in /sys/class/udc/*; do
    kv "udc state" "$(cat "$u/state" 2>/dev/null)"
done
pid=$(cat /sys/kernel/config/usb_gadget/adb/idProduct 2>/dev/null)
[ -n "$pid" ] && kv "gadget idProduct" "$pid $(have qusb && echo '(qusb showpid 查含义)')"

# ---------------------------------------------------------------------------
# tools that are NOT here (the frequent cause of "command not found")
# ---------------------------------------------------------------------------
sect "missing tools"
missing=""
for t in i2cdetect i2cget gpioset gpioget gpiodetect pactl paplay gnome-screenshot \
         grim modetest fio hdparm smartctl nvme mmcli bpftrace speaker-test; do
    have "$t" || missing="$missing $t"
done
if [ -n "$missing" ]; then
    printf '  not installed:%s\n' "$missing"
    printf '  (each skill gives a replacement that needs no install)\n'
else
    say "  all present"
fi

sect "dmesg"
if dmesg >/dev/null 2>&1; then
    kv readable yes
else
    kv readable "no -- need sudo (dmesg_restrict=1)"
fi

printf '\n== end ==\n'
exit 0
