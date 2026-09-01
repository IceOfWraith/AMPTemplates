#!/bin/bash
# Prepares the dedicated server before AMP starts it: writes dedicatedServer.xml from AMP settings and
# keeps the game's profile directory inside the instance.
#
# The game hardcodes its profile to "Documents/My Games/FarmingSimulator2022" under the user profile. Running
# under Proton with HOME pointed at the instance is what makes that per-instance instead of machine-wide.
set -uo pipefail

GAME_DIR=""; LOG_DIR=""; PROFILE_DIR=""; PROTON=""; COMPAT_DIR=""; STEAM_DIR=""; HOME_DIR=""
WEB_PORT="8080"; TLS_PORT="8443"; TLS_ON="false"; ADMIN_USER="admin"; ADMIN_PASS=""; GAME_PORT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gamedir) GAME_DIR="${2%/}"; shift 2 ;;
        --logdir) LOG_DIR="${2%/}"; shift 2 ;;
        --profiledir) PROFILE_DIR="${2%/}"; shift 2 ;;
        --compatdata) COMPAT_DIR="${2%/}"; shift 2 ;;
        --steamdir) STEAM_DIR="${2%/}"; shift 2 ;;
        --home) HOME_DIR="${2%/}"; shift 2 ;;
        --proton) PROTON="$2"; shift 2 ;;
        --gameport) GAME_PORT="$2"; shift 2 ;;
        --webport) WEB_PORT="$2"; shift 2 ;;
        --tlsport) TLS_PORT="$2"; shift 2 ;;
        --tls) TLS_ON="$2"; shift 2 ;;
        --user) ADMIN_USER="$2"; shift 2 ;;
        --pass) ADMIN_PASS="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done
[[ -n "$GAME_DIR" && -n "$LOG_DIR" ]] || { echo "ERROR: --gamedir and --logdir are required"; exit 1; }

# Wine keeps Documents as a real directory inside the prefix rather than linking it to $HOME, so the prefix
# is where the game actually writes. It lives under the instance, which is what keeps savegames per-instance;
# falling back to $HOME would put every instance on the host into one shared profile.
#
# App.EnvironmentVariables applies to the game process, not to pre-start stages, so the path is passed in
# as an argument and only falls back to the environment when the script is run by hand.
[[ -n "$COMPAT_DIR" ]] || COMPAT_DIR="${STEAM_COMPAT_DATA_PATH:-}"
if [[ -z "$COMPAT_DIR" ]]; then
    echo "ERROR: No Proton prefix path was given (--compatdata)."
    exit 1
fi
# Proton reads these from the environment, so export them for the prefix creation below. HOME is set to the
# same instance path the game runs with: Proton writes protonfixes state into it, and the container's own
# /home/amp is discarded when the container is recreated.
export STEAM_COMPAT_DATA_PATH="$COMPAT_DIR"
[[ -n "$STEAM_DIR" ]] && export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_DIR"
[[ -n "$HOME_DIR" ]] && { mkdir -p "$HOME_DIR" 2>/dev/null; export HOME="$HOME_DIR"; }
mkdir -p "$COMPAT_DIR" "${STEAM_DIR:-$COMPAT_DIR}" 2>/dev/null

PFX_USER="$COMPAT_DIR/pfx/drive_c/users/steamuser"
if [[ ! -d "$PFX_USER" && -n "$PROTON" && -x "$PROTON" ]]; then
    echo "Creating the Proton prefix..."
    "$PROTON" runinprefix cmd /c exit >/dev/null 2>&1
fi
DOCUMENTS="$(readlink -f "$PFX_USER/Documents" 2>/dev/null)"
if [[ -z "$DOCUMENTS" ]]; then
    echo "ERROR: The Proton prefix at $COMPAT_DIR could not be created or read."
    exit 1
fi

# The game's profile path inside the prefix is nine directories below the instance, which is deeper than
# AMP's backup traversal reaches. Keep the real directory shallow and point the prefix at it, so savegames,
# mods and the server database sit two or three levels down and get backed up.
PROFILE="$DOCUMENTS/My Games/FarmingSimulator2022"
if [[ -n "$PROFILE_DIR" ]]; then
    mkdir -p "$PROFILE_DIR" || { echo "ERROR: could not create $PROFILE_DIR"; exit 1; }
    if [[ -L "$PROFILE" ]]; then
        if [[ "$(readlink -f "$PROFILE")" != "$(readlink -f "$PROFILE_DIR")" ]]; then rm -f "$PROFILE"; fi
    elif [[ -d "$PROFILE" ]]; then
        # An earlier start may have written savegames here before the link existed; keep them.
        cp -a "$PROFILE/." "$PROFILE_DIR/" 2>/dev/null
        rm -rf "$PROFILE"
    fi
    if [[ ! -e "$PROFILE" ]]; then
        mkdir -p "$(dirname "$PROFILE")"
        ln -s "$PROFILE_DIR" "$PROFILE" && echo "Linked the game profile to $PROFILE_DIR"
    fi
    PROFILE="$PROFILE_DIR"
fi

GAME_LOGS="$PROFILE/dedicated_server/logs"
mkdir -p "$GAME_LOGS" || { echo "ERROR: could not create $GAME_LOGS"; exit 1; }
[[ -f "$GAME_LOGS/server.log" ]] || : > "$GAME_LOGS/server.log"

# AMP tails a path inside the instance, so point that at the profile's log directory.
if [[ -L "$LOG_DIR" ]]; then
    [[ "$(readlink -f "$LOG_DIR")" == "$(readlink -f "$GAME_LOGS")" ]] || { rm -f "$LOG_DIR"; }
elif [[ -d "$LOG_DIR" ]]; then
    rmdir "$LOG_DIR" 2>/dev/null || rm -rf "$LOG_DIR"
fi
if [[ ! -e "$LOG_DIR" ]]; then
    ln -s "$GAME_LOGS" "$LOG_DIR" && echo "Linked instance log directory to $GAME_LOGS"
fi

XML="$GAME_DIR/dedicatedServer.xml"
if [[ ! -f "$XML" ]]; then
    echo "ERROR: Could not find $XML"
    echo "       Update this instance to install the game before starting it."
    exit 1
fi

[[ "$TLS_ON" == "true" ]] || TLS_ON="false"
# Anything heading into a sed replacement has to have the delimiter and backreference characters escaped.
esc() { printf '%s' "$1" | sed -e 's/[|&\\]/\\&/g'; }
U=$(esc "$ADMIN_USER"); P=$(esc "$ADMIN_PASS")

sed -E -i \
    -e "s|(<webserver[^>]*port=\")[^\"]*\"|\1${WEB_PORT}\"|" \
    -e "s|(<tls[^>]*port=\")[^\"]*\"|\1${TLS_PORT}\"|" \
    -e "s|(<tls[^>]*active=\")[^\"]*\"|\1${TLS_ON}\"|" \
    -e "s|<username>[^<]*</username>|<username>${U}</username>|" \
    "$XML" || { echo "ERROR: could not rewrite $XML"; exit 1; }

if [[ -n "$ADMIN_PASS" ]]; then
    # The server rewrites <password> as <passphrase> on first run, so write the tag it settles on.
    sed -E -i \
        -e "s|<password>[^<]*</password>|<passphrase>${P}</passphrase>|" \
        -e "s|<passphrase>[^<]*</passphrase>|<passphrase>${P}</passphrase>|" \
        "$XML"
fi

# The game port lives in the web interface's saved settings, not dedicatedServer.xml.
# Absent until the web interface saves once; the start form carries the port until then.
SERVER_CONFIG="$PROFILE/dedicated_server/dedicatedServerConfig.xml"
if [[ -n "$GAME_PORT" && -f "$SERVER_CONFIG" ]]; then
    if sed -E -i "s|<port>[^<]*</port>|<port>${GAME_PORT}</port>|" "$SERVER_CONFIG"; then
        echo "Set the game server port to ${GAME_PORT}"
    else
        echo "WARNING: could not set the game server port in $SERVER_CONFIG"
    fi
fi

echo "Configured dedicated server on port ${WEB_PORT}"
