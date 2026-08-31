#!/bin/bash
# Activates Farming Simulator 19 by driving the launcher's product key dialog under Proton.
#
# The game offers no command line, config file or offline path for the key, so the dialog is the only route.
# Under Wine the dialog is a real X window, so it is driven with xdotool on a headless X server rather than
# with SendMessage. Activation is a single file, so this exits immediately once that file exists.
set -uo pipefail

KEY=""; GAME_DIR=""; PROTON=""; COMPAT_DIR=""; STEAM_DIR=""; HOME_DIR=""; DIALOG_TIMEOUT=90; ACTIVATION_TIMEOUT=120
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) KEY="$2"; shift 2 ;;
        --gamedir) GAME_DIR="${2%/}"; shift 2 ;;
        --compatdata) COMPAT_DIR="${2%/}"; shift 2 ;;
        --steamdir) STEAM_DIR="${2%/}"; shift 2 ;;
        --home) HOME_DIR="${2%/}"; shift 2 ;;
        --proton) PROTON="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done
[[ -n "$GAME_DIR" ]] || { echo "ERROR: --gamedir is required"; exit 1; }

# Activation lives in the prefix, so it must be the prefix the server runs in; $HOME is shared between
# instances. App.EnvironmentVariables skips pre-start stages, so the path arrives as an argument.
[[ -n "$COMPAT_DIR" ]] || COMPAT_DIR="${STEAM_COMPAT_DATA_PATH:-}"
if [[ -z "$COMPAT_DIR" ]]; then
    echo "ERROR: No Proton prefix path was given (--compatdata)."
    exit 1
fi
# Proton reads these from the environment when the launcher is run below, and needs a writable HOME.
export STEAM_COMPAT_DATA_PATH="$COMPAT_DIR"
[[ -n "$STEAM_DIR" ]] && export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_DIR"
[[ -n "$HOME_DIR" ]] && { mkdir -p "$HOME_DIR" 2>/dev/null; export HOME="$HOME_DIR"; }

PROFILE="$(readlink -f "$COMPAT_DIR/pfx/drive_c/users/steamuser/Documents" 2>/dev/null)"
if [[ -z "$PROFILE" ]]; then
    echo "ERROR: The Proton prefix at $COMPAT_DIR does not exist yet."
    exit 1
fi
PROFILE="$PROFILE/My Games/FarmingSimulator2019"
ACTIVATION="$PROFILE/AHC_63805.dat"

if [[ -f "$ACTIVATION" ]]; then
    echo "Farming Simulator 19 is already activated for this instance"
    exit 0
fi

KEY="${KEY// /}"
if [[ -z "$KEY" ]]; then
    echo "ERROR: No product key is set."
    echo "       Set the Product Key setting on this instance, then start it again."
    exit 1
fi

LAUNCHER="$GAME_DIR/FarmingSimulator2019.exe"
[[ -f "$LAUNCHER" ]] || { echo "ERROR: Could not find $LAUNCHER"; echo "       Update this instance to install the game before starting it."; exit 1; }
[[ -n "$PROTON" && -x "$PROTON" ]] || { echo "ERROR: Proton was not found at '$PROTON'"; exit 1; }

for tool in xdotool Xvfb; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: $tool is not installed, so the product key cannot be entered."
        exit 1
    }
done

mkdir -p "$PROFILE"

# A private X server: the dialog needs somewhere to draw, but nothing needs to see it.
# Containers get their own /tmp, but instances running directly on a host share it, so claim a free
# display number rather than picking one at random and colliding with another instance.
DISPLAY_NUM=""
for n in $(seq 90 120); do
    [[ -e "/tmp/.X${n}-lock" || -e "/tmp/.X11-unix/X${n}" ]] && continue
    DISPLAY_NUM="$n"; break
done
[[ -n "$DISPLAY_NUM" ]] || { echo "ERROR: no free X display number could be found."; exit 1; }
Xvfb ":$DISPLAY_NUM" -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY=":$DISPLAY_NUM"
sleep 2

cleanup() {
    pkill -f 'FarmingSimulator2019Game.exe' >/dev/null 2>&1
    pkill -f 'FarmingSimulator2019.exe' >/dev/null 2>&1
    [[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

echo "Activating Farming Simulator 19..."
"$PROTON" runinprefix "$LAUNCHER" >/dev/null 2>&1 &

# The dialog is titled "Product Key for Farming Simulator 19"; match loosely in case it is localised.
WID=""
deadline=$(( SECONDS + DIALOG_TIMEOUT ))
while (( SECONDS < deadline )); do
    sleep 2
    # Without --onlyvisible this also matches unmapped Wine windows, which cannot be typed into.
    WID=$(xdotool search --onlyvisible --name 'Product Key|FarmingSimulator2019' 2>/dev/null | head -1)
    [[ -n "$WID" ]] && break
done

if [[ -z "$WID" ]]; then
    [[ -f "$ACTIVATION" ]] && { echo "Farming Simulator 19 is already activated for this instance"; exit 0; }
    echo "ERROR: The product key dialog did not appear."
    exit 1
fi

# Snapshot the current windows: "any window that is not the dialog" also matches the launcher's own.
WINDOWS_BEFORE=" $(xdotool search --onlyvisible --name '.*' 2>/dev/null | tr '\n' ' ') "

# The key field holds focus and Enter is the default button. windowactivate needs a window manager and
# a bare Xvfb has none, so focus is set directly; keystrokes go via XTEST because Wine ignores XSendEvent.
xdotool windowraise "$WID" 2>/dev/null
xdotool windowfocus "$WID" 2>/dev/null
sleep 1
xdotool type --clearmodifiers --delay 40 "$KEY"
sleep 1
xdotool key --clearmodifiers Return

# A window the launcher did not already have open is its reply, and proof the key reached the field.
RESULT_WID=""
deadline=$(( SECONDS + ACTIVATION_TIMEOUT ))
while (( SECONDS < deadline )); do
    sleep 3
    [[ -f "$ACTIVATION" ]] && break
    if [[ -z "$RESULT_WID" ]]; then
        for w in $(xdotool search --onlyvisible --name '.*' 2>/dev/null); do
            [[ "$WINDOWS_BEFORE" == *" $w "* ]] && continue
            name=$(xdotool getwindowname "$w" 2>/dev/null)
            [[ -n "$name" ]] || continue
            RESULT_WID="$w"
            break
        done
    fi
done

if [[ -f "$ACTIVATION" ]]; then
    echo "Activation successful"
    exit 0
fi

if [[ -n "$RESULT_WID" ]]; then
    # A reply window means the server answered, so this is a licensing refusal, not a UI failure.
    echo "ERROR: Activation failed. The key is invalid, or its activation limit has been reached."
    echo "       Every instance activates separately. Contact GIANTS support about the key."
else
    echo "ERROR: The product key could not be entered, so activation was not attempted."
fi
exit 1
