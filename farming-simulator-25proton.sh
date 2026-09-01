#!/bin/bash
# Installs Proton GE, which runs the Windows dedicated server on Linux.
set -uo pipefail

ROOT=""; BASE=""; VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root) ROOT="${2%/}"; shift 2 ;;
        --base) BASE="${2%/}"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done
[[ -n "$ROOT" && -n "$BASE" ]] || { echo "ERROR: --root and --base are required"; exit 1; }

PROTON_DIR="$ROOT/.proton"
# Proton needs these to exist even with no Steam app involved.
mkdir -p "$PROTON_DIR/compatdata" "$BASE/.steam/steam" "$BASE/.config/protonfixes" || exit 1

VERSION="${VERSION//[[:space:]]/}"
if [[ -z "$VERSION" ]]; then
    echo "Resolving the latest Proton GE release..."
    # jq is not in every base image.
    VERSION=$(curl -fsSL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
              | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
    [[ -n "$VERSION" ]] || { echo "ERROR: could not resolve the latest Proton GE release from GitHub."; exit 1; }
fi
if [[ ! "$VERSION" =~ ^GE-Proton[0-9]+-[0-9]+$ ]]; then
    echo "ERROR: '$VERSION' is not a Proton GE release version. Expected a tag such as GE-Proton9-1."
    exit 1
fi

# The version file reads "<build stamp> GE-ProtonN-N".
INSTALLED=""
[[ -x "$PROTON_DIR/proton" && -f "$PROTON_DIR/version" ]] && read -r _ INSTALLED < "$PROTON_DIR/version"
if [[ -n "$INSTALLED" && "$INSTALLED" == "$VERSION"* ]]; then
    echo "Proton GE $VERSION already installed. Skipping"
    exit 0
fi

# GE-Proton11-4 and later name the x86_64 build explicitly.
ver="${VERSION#GE-Proton}"; major="${ver%%-*}"; minor="${ver#*-}"
SUFFIX=""
(( major > 11 || (major == 11 && minor >= 4) )) && SUFFIX="-x86_64"
URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${VERSION}/${VERSION}${SUFFIX}.tar.gz"

echo "Downloading ${URL##*/}"
if ! curl -fsSL -o "$PROTON_DIR/proton.tar.gz" "$URL"; then
    echo "ERROR: the Proton GE download failed."
    rm -f "$PROTON_DIR/proton.tar.gz"
    exit 1
fi

# A prefix is not reusable across Proton versions. Savegames sit outside it, but the key is re-entered.
rm -rf "${PROTON_DIR:?}/compatdata/"* >/dev/null 2>&1

tar -xzf "$PROTON_DIR/proton.tar.gz" --strip-components=1 -C "$PROTON_DIR" || {
    echo "ERROR: could not unpack Proton."; rm -f "$PROTON_DIR/proton.tar.gz"; exit 1; }
rm -f "$PROTON_DIR/proton.tar.gz"
[[ -x "$PROTON_DIR/proton" ]] || { echo "ERROR: Proton was unpacked but no proton binary was found."; exit 1; }

# Build the prefix now so a failure shows during the update, not on first start.
STEAM_COMPAT_DATA_PATH="$PROTON_DIR/compatdata" \
STEAM_COMPAT_CLIENT_INSTALL_PATH="$BASE/.steam/steam" \
HOME="$BASE" WINEDEBUG=-all \
    "$PROTON_DIR/proton" runinprefix cmd /c exit >/dev/null 2>&1

echo "Proton GE $VERSION installed"
