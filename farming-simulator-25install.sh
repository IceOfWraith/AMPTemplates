#!/bin/bash
# Installs Farming Simulator 25 into the instance directory, for running under Proton.
# The product key is posted to the GIANTS download portal to get the download link, then the disc image is
# fetched, its payload read out, and the installer run under Proton.
#
# Unlike Farming Simulator 19, the payload is not unpacked with innoextract: FS25 ships Inno Setup 6.3, and
# no released innoextract understands it (1.9 stops at 6.0.5). The installer is run under Wine instead, where
# it reports "User privileges: Administrative" and so does not hit the admin check that blocks it on Windows.
set -uo pipefail

KEY=""; DOWNLOAD_URL=""; GAME_DIR=""; WORK_DIR=""; PROTON=""; COMPAT_DIR=""; STEAM_DIR=""; HOME_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) KEY="$2"; shift 2 ;;
        --url) DOWNLOAD_URL="$2"; shift 2 ;;
        --gamedir) GAME_DIR="${2%/}"; shift 2 ;;
        --workdir) WORK_DIR="${2%/}"; shift 2 ;;
        --proton) PROTON="$2"; shift 2 ;;
        --compatdata) COMPAT_DIR="${2%/}"; shift 2 ;;
        --steamdir) STEAM_DIR="${2%/}"; shift 2 ;;
        --home) HOME_DIR="${2%/}"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done
[[ -n "$GAME_DIR" && -n "$WORK_DIR" ]] || { echo "ERROR: --gamedir and --workdir are required"; exit 1; }

PORTAL="https://eshop.giants-software.com/downloads.php"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
# Far larger than Farming Simulator 19: a ~21GB image, read out to ~21GB alongside it, installing to ~40GB.
# The image is deleted before the install runs, so the peak is the payload plus the installed game.
REQUIRED_GB=70

if [[ -f "$GAME_DIR/dedicatedServer.exe" ]]; then
    echo "Farming Simulator 25 $(cat "$GAME_DIR/VERSION" 2>/dev/null) already installed. Skipping"
    echo "Delete the game folder inside this instance to force a reinstall"
    exit 0
fi

if [[ -z "$DOWNLOAD_URL" ]]; then
    if [[ -z "$KEY" ]]; then
        echo "ERROR: No product key is set, so the download link cannot be looked up."
        echo "       Set the Product Key setting on this instance, then update it again."
        exit 1
    fi
    echo "Looking up the download link from the GIANTS download portal..."
    PAGE=$(curl -sS -A "$UA" --data-urlencode "activationKey=$KEY" --data-urlencode "foobar=DOWNLOAD" "$PORTAL") || {
        echo "ERROR: Could not reach the GIANTS download portal."; exit 1; }
    # Titles are served from a per-product path, not the /eshop/ prefix Farming Simulator 19 uses.
    mapfile -t LINKS < <(grep -oE 'https://cdn[0-9]*\.giants-software\.com/[^"]+' <<<"$PAGE" | sort -u)
    if [[ ${#LINKS[@]} -eq 0 ]]; then
        echo "ERROR: The download portal returned no downloads for that product key."
        echo "       Check the Product Key setting, or confirm the key at the portal in a browser."
        exit 1
    fi
    DOWNLOAD_URL=$(printf '%s\n' "${LINKS[@]}" | grep -E 'FarmingSimulator25[^/]*\.img$' | head -1)
    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo "ERROR: That product key unlocks downloads, but no Farming Simulator 25 disc image was among them:"
        printf '         %s\n' "${LINKS[@]}"
        exit 1
    fi
    echo "Found ${DOWNLOAD_URL##*/}"
fi

mkdir -p "$GAME_DIR" "$WORK_DIR" || exit 1

FREE_GB=$(( $(df -P -k "$GAME_DIR" | awk 'NR==2{print $4}') / 1024 / 1024 ))
if [[ $FREE_GB -lt $REQUIRED_GB ]]; then
    echo "ERROR: Only ${FREE_GB}GB is free on the instance drive, and installing Farming Simulator 25 needs about ${REQUIRED_GB}GB."
    exit 1
fi

IMG="$WORK_DIR/fs25_download.img"
UNPACK="$WORK_DIR/fs25_unpack"
rm -rf "$UNPACK"; rm -f "$IMG"

echo "Downloading Farming Simulator 25. This is a very large download and will take a while"
if ! curl -fsS -A "$UA" -e "$PORTAL" -o "$IMG" "$DOWNLOAD_URL"; then
    echo "ERROR: The download failed."
    echo "       If this was a 403, the link was rejected by the CDN. Clear the Download Link setting"
    echo "       so the key is used to look up a fresh link automatically."
    rm -f "$IMG"; exit 1
fi
echo "Downloaded $(awk -v b="$(stat -c%s "$IMG")" 'BEGIN{printf "%.2f", b/1073741824}') GB"

# --- ISO9660 extraction, without mounting (mounting needs root) ---
u8()  { echo "${BYTES[$1]}"; }
u32() { echo $(( ${BYTES[$1]} | ${BYTES[$(($1+1))]}<<8 | ${BYTES[$(($1+2))]}<<16 | ${BYTES[$(($1+3))]}<<24 )); }

extract_iso() {
    local img="$1" dest="$2"
    local magic
    magic=$(dd if="$img" bs=1 skip=32769 count=5 2>/dev/null)
    [[ "$magic" == "CD001" ]] || { echo "ERROR: the download is not an ISO9660 disc image"; return 1; }

    mapfile -t BYTES < <(dd if="$img" bs=2048 skip=16 count=1 2>/dev/null | od -An -tu1 -v | tr -s ' ' '\n' | grep -v '^$')
    local root_lba root_size
    root_lba=$(u32 158); root_size=$(u32 166)
    mapfile -t BYTES < <(dd if="$img" bs=2048 skip="$root_lba" count=$(( (root_size + 2047) / 2048 )) 2>/dev/null | od -An -tu1 -v | tr -s ' ' '\n' | grep -v '^$')

    mkdir -p "$dest"
    local p=0 len lba size flags filen name first i c
    while (( p < root_size )); do
        len=$(u8 $p)
        if (( len == 0 )); then p=$(( (p / 2048 + 1) * 2048 )); continue; fi
        lba=$(u32 $((p+2))); size=$(u32 $((p+10)))
        flags=$(u8 $((p+25))); filen=$(u8 $((p+32))); first=${BYTES[$((p+33))]}
        if (( filen == 1 && first <= 1 )); then p=$(( p + len )); continue; fi
        name=""
        for (( i=0; i<filen; i++ )); do
            c=${BYTES[$((p+33+i))]}
            name+=$(printf "\\$(printf '%03o' "$c")")
        done
        p=$(( p + len ))
        (( flags & 2 )) && continue
        name="${name%%;*}"; name="${name%.}"
        [[ -n "$name" ]] || continue
        echo "  reading $name"
        dd if="$img" bs=2048 skip="$lba" count=$(( (size + 2047) / 2048 )) 2>/dev/null | head -c "$size" > "$dest/$name"
    done
}

echo "Reading the disc image"
extract_iso "$IMG" "$UNPACK" || { rm -f "$IMG"; exit 1; }
rm -f "$IMG"

# ISO9660 cannot store a hyphen, so slices named "Setup-1a.bin" are written as "SETUP_1A.BIN". Wine matches
# filenames case-insensitively, so only the separator has to be restored. Hardlinks cost no space.
shopt -s nullglob nocaseglob
for f in "$UNPACK"/*_*.bin; do
    base="${f##*/}"
    alt="${base//_/-}"
    [[ "$alt" == "$base" || -e "$UNPACK/$alt" ]] && continue
    ln "$f" "$UNPACK/$alt" 2>/dev/null || cp "$f" "$UNPACK/$alt"
done
SETUP=""
for cand in "$UNPACK"/Setup.exe "$UNPACK"/*.exe; do [[ -f "$cand" ]] && SETUP="$cand" && break; done
shopt -u nullglob nocaseglob
[[ -n "$SETUP" ]] || { echo "ERROR: the installer was not found in the disc image"; rm -rf "$UNPACK"; exit 1; }

[[ -n "$PROTON" && -x "$PROTON" ]] || { echo "ERROR: Proton was not found at '$PROTON'"; exit 1; }
[[ -n "$COMPAT_DIR" ]] || { echo "ERROR: --compatdata is required to run the installer under Proton"; exit 1; }
# Proton will build the prefix itself, but only if the compatdata directory it is pointed at already exists.
mkdir -p "$COMPAT_DIR" "${STEAM_DIR:-$COMPAT_DIR}" || exit 1
export STEAM_COMPAT_DATA_PATH="$COMPAT_DIR"
[[ -n "$STEAM_DIR" ]] && export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_DIR"
[[ -n "$HOME_DIR" ]] && { mkdir -p "$HOME_DIR"; export HOME="$HOME_DIR"; }
export WINEDEBUG="${WINEDEBUG:--all}"

# Wine maps the Linux root at Z:, so the installer needs its destination in that form.
winpath() { printf 'Z:%s' "$(sed 's|/|\\|g' <<<"$1")"; }
LOG="$WORK_DIR/fs25_install.log"

echo "Installing Farming Simulator 25. This takes a long time"
PROTON_LOG="$WORK_DIR/fs25_proton.log"
"$PROTON" runinprefix "$SETUP" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /SP- \
    "/DIR=$(winpath "$GAME_DIR")" "/LOG=$(winpath "$LOG")" >"$PROTON_LOG" 2>&1
rc=$?

if [[ ! -f "$GAME_DIR/dedicatedServer.exe" ]]; then
    echo "ERROR: The installer finished (exit $rc) but no dedicated server was installed."
    if [[ -f "$LOG" ]]; then
        echo "--- installer log ---"
        tail -20 "$LOG" | sed 's/^/    /'
    else
        echo "--- the installer wrote no log; Proton output follows ---"
        tail -20 "$PROTON_LOG" 2>/dev/null | sed 's/^/    /'
    fi
    echo "---------------------"
    # The unpacked payload is kept so a retry does not need the whole download again.
    echo "The unpacked installer has been left in $UNPACK for a retry."
    exit 1
fi

rm -rf "$UNPACK"
echo "Farming Simulator 25 $(cat "$GAME_DIR/VERSION" 2>/dev/null) installed"
