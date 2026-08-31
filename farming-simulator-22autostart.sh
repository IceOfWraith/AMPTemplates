#!/bin/bash
# Presses Start on the dedicated server's web interface once it is up, so the game server comes up with the
# instance rather than needing someone to visit the web interface and press the button by hand.
#
# dedicatedServer.exe is only a manager: it serves the web interface and spawns FarmingSimulator20XXGame.exe
# as a child when the start form is submitted. There is no autostart field in dedicatedServer.xml and no
# command line for it, so submitting that form is the only route.
#
# AMP has no post-start stage, so this is launched from PreStartStages with RunInBackground and outlives it:
# it waits for the web interface to answer, logs in, and submits the form.
#
# The form is sent back exactly as the web interface serves it, with only the fields AMP owns replaced.
# Whatever was last saved in the web interface is what starts. The field set differs between titles -
# Farming Simulator 22 has "difficulty" where 25 has "economicDifficulty", "initialMoney" and "initialLoan" -
# so the fields are read out of the form rather than hardcoded.
set -uo pipefail

HOST=""; PORT=""; USERNAME="admin"; PASSWORD=""; GAME_PORT=""; SAVEGAME=""; TIMEOUT=300
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --user) USERNAME="$2"; shift 2 ;;
        --pass) PASSWORD="$2"; shift 2 ;;
        --gameport) GAME_PORT="$2"; shift 2 ;;
        --savegame) SAVEGAME="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done
[[ -n "$PORT" ]] || { echo "ERROR: --port is required"; exit 1; }

JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

# One field per line, as "name<TAB>value". Attribute order varies and the equals sign is padded in places
# ('<select name = "initialMoney">'), so this matches attributes rather than a fixed layout.
parse_form() {
    sed -e 's/></>\n</g' \
    | awk '
        function attr(s, a,   r) {
            if (match(s, a "[[:space:]]*=[[:space:]]*\"")) {
                r = substr(s, RSTART + RLENGTH)
                return substr(r, 1, index(r, "\"") - 1)
            }
            return "\001"
        }
        /^<input/ {
            t = attr($0, "type"); n = attr($0, "name")
            if (n == "\001" || t == "submit" || t == "button" || t == "reset") next
            v = attr($0, "value"); if (v == "\001") v = ""
            # An unchecked box submits nothing at all, so only a checked one is carried over.
            if (t == "checkbox") { if ($0 ~ /checked/) print n "\t" (v == "" ? "on" : v); next }
            print n "\t" v
            next
        }
        /^<select/ { sel = attr($0, "name"); chosen = "\001"; first = "\001"; next }
        /^<option/ && sel != "" {
            v = attr($0, "value")
            if (v == "\001") { v = $0; sub(/^<option[^>]*>/, "", v) }
            if (first == "\001") first = v
            if ($0 ~ /selected/ && chosen == "\001") chosen = v
            next
        }
        /^<\/select>/ && sel != "" {
            print sel "\t" (chosen != "\001" ? chosen : (first != "\001" ? first : ""))
            sel = ""; next
        }
    '
}

# The dedicated server binds the interface address rather than the wildcard, so the loopback does not answer
# even with AMP set to bind 0.0.0.0 - the server picks the primary address itself and reports it in its log
# as "URL(s): http://<address>:<port>". Which address that is depends on how the container is networked, so
# every local address is tried and whichever answers is the one used.
candidate_hosts() {
    if [[ -n "$HOST" ]]; then printf '%s\n' "$HOST"; return; fi
    printf '127.0.0.1\n'
    hostname -I 2>/dev/null | tr ' \t' '\n\n'
    ip -4 -o addr show scope global 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1
}
mapfile -t CANDIDATES < <(candidate_hosts | grep -E '^[0-9]+(\.[0-9]+){3}$' | awk '!seen[$0]++')
[[ ${#CANDIDATES[@]} -gt 0 ]] || { echo "ERROR: no local address could be found to reach the web interface on."; exit 1; }

echo "Waiting for the dedicated server web interface on port ${PORT}..."
FOUND=""
deadline=$(( SECONDS + TIMEOUT ))
while (( SECONDS < deadline )); do
    for h in "${CANDIDATES[@]}"; do
        if curl -fsS -m 5 -o /dev/null "http://${h}:${PORT}/index.html?lang=en" 2>/dev/null; then FOUND="$h"; break 2; fi
    done
    sleep 3
done
if [[ -z "$FOUND" ]]; then
    echo "ERROR: the web interface did not come up within ${TIMEOUT}s, so the game server was not started."
    echo "       Tried: ${CANDIDATES[*]}"
    exit 1
fi
BASE="http://${FOUND}:${PORT}/index.html?lang=en"
echo "Web interface answered on ${FOUND}:${PORT}"

if ! curl -fsS -m 15 -c "$JAR" -o /dev/null -X POST "$BASE" \
        --data-urlencode "username=$USERNAME" \
        --data-urlencode "password=$PASSWORD" \
        --data-urlencode "login=Login"; then
    echo "ERROR: could not reach the web interface to log in."
    exit 1
fi

PAGE="$(curl -fsS -m 15 -b "$JAR" "$BASE" 2>/dev/null)"
if [[ -z "$PAGE" ]]; then
    echo "ERROR: the web interface returned nothing after logging in."
    exit 1
fi
# The start form only renders for a logged-in session, so its absence is a rejected login.
if ! grep -q 'name="start_server"\|name="stop_server"' <<<"$PAGE"; then
    echo "ERROR: the web interface rejected the admin username and password, so the game server was not started."
    echo "       These come from the Admin Username and Admin Password settings on this instance."
    exit 1
fi
if grep -q 'name="stop_server"' <<<"$PAGE"; then
    echo "The game server is already running"
    exit 0
fi

# Rebuild the form, overriding only what AMP owns. curl encodes each field, so values with spaces and
# punctuation survive intact.
ARGS=()
while IFS=$'\t' read -r name value; do
    [[ -n "$name" ]] || continue
    case "$name" in
        server_port) [[ -n "$GAME_PORT" ]] && value="$GAME_PORT" ;;
        savegame)    [[ -n "$SAVEGAME" ]] && value="$SAVEGAME" ;;
    esac
    ARGS+=(--data-urlencode "$name=$value")
done < <(parse_form <<<"$PAGE")

if [[ ${#ARGS[@]} -eq 0 ]]; then
    echo "ERROR: no settings could be read from the start form, so the game server was not started."
    exit 1
fi
ARGS+=(--data-urlencode "start_server=Start")

echo "Starting the game server"
if ! curl -fsS -m 60 -b "$JAR" -c "$JAR" -o /dev/null -X POST "$BASE" "${ARGS[@]}"; then
    echo "ERROR: the start request failed."
    exit 1
fi

# The button flipping to Stop is the web interface confirming it spawned the game server.
deadline=$(( SECONDS + 120 ))
while (( SECONDS < deadline )); do
    sleep 3
    if curl -fsS -m 15 -b "$JAR" "$BASE" 2>/dev/null | grep -q 'name="stop_server"'; then
        echo "Game server started"
        exit 0
    fi
done
echo "ERROR: the game server did not report as started. Check the web interface on port ${PORT}."
exit 1
