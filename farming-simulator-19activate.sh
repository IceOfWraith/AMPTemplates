#!/bin/bash
# Activates Farming Simulator 19 by driving the launcher's product key dialog under Proton.
#
# The game offers no command line, config file or offline path for the key, so the dialog is the only route.
# Under Wine the dialog is a real X window, so it is driven with xdotool on a headless X server rather than
# with SendMessage. Activation is a single file, so this exits immediately once that file exists.
set -uo pipefail

KEY=""; GAME_DIR=""; PROTON=""; DIALOG_TIMEOUT=90; ACTIVATION_TIMEOUT=120
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) KEY="$2"; shift 2 ;;
        --gamedir) GAME_DIR="${2%/}"; shift 2 ;;
        --proton) PROTON="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done
[[ -n "$GAME_DIR" ]] || { echo "ERROR: --gamedir is required"; exit 1; }

# Activation is stored in the prefix, so it must be the same prefix the server will run in. $HOME is shared
# by every instance on a host, and inside a container it is discarded when the container is recreated, so
# activating there would either share the activation or silently burn a fresh one on every start. Both are
# worse than failing, because online activations are limited.
if [[ -z "${STEAM_COMPAT_DATA_PATH:-}" ]]; then
    echo "ERROR: STEAM_COMPAT_DATA_PATH is not set, so the Proton prefix cannot be located."
    echo "       Activating without it would not persist and would consume an activation on every start."
    exit 1
fi
PROFILE="$(readlink -f "$STEAM_COMPAT_DATA_PATH/pfx/drive_c/users/steamuser/Documents" 2>/dev/null)"
if [[ -z "$PROFILE" ]]; then
    echo "ERROR: The Proton prefix at $STEAM_COMPAT_DATA_PATH does not exist yet."
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
    echo "ERROR: Farming Simulator 19 is not activated for this instance and no product key is set."
    echo "       Set the Product Key setting on this instance, then start it again."
    exit 1
fi

LAUNCHER="$GAME_DIR/FarmingSimulator2019.exe"
[[ -f "$LAUNCHER" ]] || { echo "ERROR: Could not find $LAUNCHER"; echo "       Update this instance to install the game before starting it."; exit 1; }
[[ -n "$PROTON" && -x "$PROTON" ]] || { echo "ERROR: Proton was not found at '$PROTON'"; exit 1; }

for tool in xdotool Xvfb; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: $tool is not installed, so the product key dialog cannot be driven."
        echo "       Install xvfb and xdotool, or activate once elsewhere and copy the resulting file to:"
        echo "         $ACTIVATION"
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
    WID=$(xdotool search --name 'Product Key' 2>/dev/null | head -1)
    [[ -n "$WID" ]] && break
done

if [[ -z "$WID" ]]; then
    [[ -f "$ACTIVATION" ]] && { echo "Farming Simulator 19 is already activated for this instance"; exit 0; }
    echo "ERROR: The product key dialog did not appear. Activation could not be completed."
    exit 1
fi

# The key field holds focus when the dialog opens, and Enter is the default button ("Activate >").
xdotool windowactivate --sync "$WID" 2>/dev/null
xdotool type --window "$WID" --delay 40 "$KEY"
sleep 1
xdotool key --window "$WID" Return

deadline=$(( SECONDS + ACTIVATION_TIMEOUT ))
while (( SECONDS < deadline )); do
    sleep 3
    [[ -f "$ACTIVATION" ]] && break
done

if [[ -f "$ACTIVATION" ]]; then
    echo "Activation successful"
    exit 0
fi

echo "ERROR: Activation did not complete. The key may be invalid, or the online activation limit reached."
echo "       Check the Product Key setting, or activate once elsewhere and copy the resulting file to:"
echo "         $ACTIVATION"
exit 1
