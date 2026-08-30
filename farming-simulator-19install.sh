#!/bin/bash
# Installs Farming Simulator 19 into the instance directory, for running under Proton.
# The product key is posted to the GIANTS download portal to get the download link, then the disc image is
# fetched and its payload unpacked.
#
# The game's Inno Setup installer is never executed. It requires administrator rights and would need a Wine
# prefix to run in; innoextract reads its payload directly instead.
set -uo pipefail

KEY=""
DOWNLOAD_URL=""
GAME_DIR=""
WORK_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) KEY="$2"; shift 2 ;;
        --url) DOWNLOAD_URL="$2"; shift 2 ;;
        --gamedir) GAME_DIR="${2%/}"; shift 2 ;;
        --workdir) WORK_DIR="${2%/}"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done
[[ -n "$GAME_DIR" && -n "$WORK_DIR" ]] || { echo "ERROR: --gamedir and --workdir are required"; exit 1; }

PORTAL="https://eshop.giants-software.com/downloads.php"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
INNOEXTRACT_URL="https://github.com/dscharrer/innoextract/releases/download/1.9/innoextract-1.9-linux.tar.xz"
INNOEXTRACT_SHA256="008efe5011476ccc4aae17c3e22038b5a1bc5c7aad2b9d4d869537bf3874d21f"

if [[ -f "$GAME_DIR/dedicatedServer.exe" ]]; then
    echo "Farming Simulator 19 $(cat "$GAME_DIR/VERSION" 2>/dev/null) already installed. Skipping"
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
    mapfile -t LINKS < <(grep -oE 'https://cdn[0-9]*\.giants-software\.com/eshop/[^"]+' <<<"$PAGE" | sort -u)
    if [[ ${#LINKS[@]} -eq 0 ]]; then
        echo "ERROR: The download portal returned no downloads for that product key."
        echo "       Check the Product Key setting, or confirm the key at the portal in a browser."
        exit 1
    fi
    DOWNLOAD_URL=$(printf '%s\n' "${LINKS[@]}" | grep -E 'FarmingSimulator2019.*\.img$' | head -1)
    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo "ERROR: That product key unlocks downloads, but no Farming Simulator 19 disc image was among them:"
        printf '         %s\n' "${LINKS[@]}"
        exit 1
    fi
    echo "Found ${DOWNLOAD_URL##*/}"
fi

mkdir -p "$GAME_DIR" "$WORK_DIR" || exit 1

# ~5GB download, unpacked to ~5GB more, then ~10GB of game files. Fail now rather than after the download.
FREE_GB=$(( $(df -P -k "$GAME_DIR" | awk 'NR==2{print $4}') / 1024 / 1024 ))
if [[ $FREE_GB -lt 17 ]]; then
    echo "ERROR: Only ${FREE_GB}GB is free on the instance drive, and installing Farming Simulator 19 needs about 17GB."
    exit 1
fi

IMG="$WORK_DIR/fs19_download.img"
UNPACK="$WORK_DIR/fs19_unpack"
STAGING="$WORK_DIR/fs19_staging"
TOOLS="$WORK_DIR/tools"
rm -rf "$UNPACK" "$STAGING"; rm -f "$IMG"

echo "Downloading Farming Simulator 19. This is a multi-gigabyte download and will take a while"
# The CDN 403s any request that does not carry the portal as its referer.
if ! curl -fsS -A "$UA" -e "$PORTAL" -o "$IMG" "$DOWNLOAD_URL"; then
    echo "ERROR: The download failed."
    echo "       If this was a 403, the link was rejected by the CDN. Clear the Download Link setting"
    echo "       so the key is used to look up a fresh link automatically."
    rm -f "$IMG"; exit 1
fi
echo "Downloaded $(awk -v b="$(stat -c%s "$IMG")" 'BEGIN{printf "%.2f", b/1073741824}') GB"

# --- ISO9660 extraction, without mounting ---
# Mounting needs root. Files are stored as contiguous unencoded extents, so extraction is a seek and a copy.
# Only the root directory is read: Inno installers keep Setup.exe and their .bin slices there.
u8()  { echo "${BYTES[$1]}"; }
u32() { echo $(( ${BYTES[$1]} | ${BYTES[$(($1+1))]}<<8 | ${BYTES[$(($1+2))]}<<16 | ${BYTES[$(($1+3))]}<<24 )); }

extract_iso() {
    local img="$1" dest="$2"
    # Primary volume descriptor sits at sector 16 and holds the root directory record at offset 156.
    local magic
    magic=$(dd if="$img" bs=1 skip=32769 count=5 2>/dev/null)
    [[ "$magic" == "CD001" ]] || { echo "ERROR: the download is not an ISO9660 disc image"; return 1; }

    mapfile -t BYTES < <(dd if="$img" bs=2048 skip=16 count=1 2>/dev/null | od -An -tu1 -v | tr -s ' ' '\n' | grep -v '^$')
    local root_lba root_size
    root_lba=$(u32 158); root_size=$(u32 166)

    mapfile -t BYTES < <(dd if="$img" bs=2048 skip="$root_lba" count=$(( (root_size + 2047) / 2048 )) 2>/dev/null | od -An -tu1 -v | tr -s ' ' '\n' | grep -v '^$')

    mkdir -p "$dest"
    local p=0 len lba size flags filen name
    while (( p < root_size )); do
        len=$(u8 $p)
        if (( len == 0 )); then p=$(( (p / 2048 + 1) * 2048 )); continue; fi
        lba=$(u32 $((p+2))); size=$(u32 $((p+10)))
        flags=$(u8 $((p+25))); filen=$(u8 $((p+32)))
        local first=${BYTES[$((p+33))]}

        # The first two records of every directory are "." and "..", a single 0x00/0x01 byte. Detect them by
        # value before building the name, since command substitution cannot carry a NUL through.
        if (( filen == 1 && first <= 1 )); then p=$(( p + len )); continue; fi

        name=""
        local i c
        for (( i=0; i<filen; i++ )); do
            c=${BYTES[$((p+33+i))]}
            name+=$(printf "\\$(printf '%03o' "$c")")
        done
        p=$(( p + len ))

        (( flags & 2 )) && continue
        name="${name%%;*}"; name="${name%.}"
        [[ -n "$name" ]] || continue

        dd if="$img" bs=2048 skip="$lba" count=$(( (size + 2047) / 2048 )) 2>/dev/null | head -c "$size" > "$dest/$name"
    done
}

echo "Reading the disc image"
extract_iso "$IMG" "$UNPACK" || { rm -f "$IMG"; exit 1; }

# ISO9660 cannot store a hyphen, so "Setup-1.bin" slices are written as "SETUP_1.BIN". The unpacker looks
# slices up by the name in the installer header, so every plausible spelling is linked. Links cost no space.
shopt -s nullglob nocaseglob
for f in "$UNPACK"/*_*.bin; do
    base="${f##*/}"
    for alt in "$(sed -E 's/_([0-9]+)\.bin$/-\1.bin/I' <<<"$base")" "${base//_/-}"; do
        [[ "$alt" == "$base" || -e "$UNPACK/$alt" ]] && continue
        ln "$f" "$UNPACK/$alt" 2>/dev/null || cp "$f" "$UNPACK/$alt"
    done
done

# Names come out of ISO9660 uppercased, so this lookup stays case-insensitive.
SETUP=""
for n in Setup.exe FarmingSimulator2019.exe; do
    for cand in "$UNPACK"/$n; do [[ -f "$cand" ]] && SETUP="$cand" && break 2; done
done
if [[ -z "$SETUP" ]]; then
    for cand in "$UNPACK"/*.exe; do [[ -f "$cand" ]] && SETUP="$cand" && break; done
fi
shopt -u nullglob nocaseglob
[[ -n "$SETUP" ]] || { echo "ERROR: the installer was not found in the disc image"; rm -rf "$UNPACK"; rm -f "$IMG"; exit 1; }

# Release the image before unpacking, so it does not sit beside both the payload and the game files.
rm -f "$IMG"

echo "Fetching innoextract"
mkdir -p "$TOOLS"
INNO=$(find "$TOOLS" -type f -name innoextract -perm -u+x 2>/dev/null | head -1)
if [[ -z "$INNO" ]]; then
    if ! curl -fsSL -o "$TOOLS/ie.tar.xz" "$INNOEXTRACT_URL"; then
        echo "ERROR: could not download innoextract"; exit 1
    fi
    GOT=$(sha256sum "$TOOLS/ie.tar.xz" | cut -d' ' -f1)
    if [[ "$GOT" != "$INNOEXTRACT_SHA256" ]]; then
        echo "ERROR: the innoextract download did not match its expected checksum (got $GOT)"
        rm -f "$TOOLS/ie.tar.xz"; exit 1
    fi
    tar -xJf "$TOOLS/ie.tar.xz" -C "$TOOLS" && rm -f "$TOOLS/ie.tar.xz"
    # The archive ships a wrapper plus per-architecture binaries; the wrapper picks the right one.
    INNO=$(find "$TOOLS" -maxdepth 2 -type f -name innoextract -perm -u+x | head -1)
fi
[[ -n "$INNO" ]] || { echo "ERROR: innoextract was not found after downloading it"; exit 1; }

echo "Unpacking the game. This takes several minutes"
if ! "$INNO" --extract --output-dir "$STAGING" --color=off --progress=no "$SETUP"; then
    echo "ERROR: innoextract failed to unpack the installer"
    rm -rf "$UNPACK" "$STAGING"; exit 1
fi

# innoextract lays the payload out under the installer's {app} constant.
if [[ ! -d "$STAGING/app" ]]; then
    echo "ERROR: the unpacked payload has no app directory"
    rm -rf "$UNPACK" "$STAGING"; exit 1
fi
echo "Moving the game into place"
shopt -s dotglob
mv "$STAGING/app"/* "$GAME_DIR"/ || { echo "ERROR: could not move the game into place"; exit 1; }
shopt -u dotglob
rm -rf "$UNPACK" "$STAGING"

if [[ ! -f "$GAME_DIR/dedicatedServer.exe" ]]; then
    echo "ERROR: The game was unpacked but no dedicated server was found in it."
    exit 1
fi
echo "Farming Simulator 19 $(cat "$GAME_DIR/VERSION" 2>/dev/null) installed"
