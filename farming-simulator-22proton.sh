#!/bin/bash
# Installs Proton GE into the instance, which is what runs the Windows dedicated server on Linux.
set -uo pipefail

ROOT=""; BASE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root) ROOT="${2%/}"; shift 2 ;;
        --base) BASE="${2%/}"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done
[[ -n "$ROOT" && -n "$BASE" ]] || { echo "ERROR: --root and --base are required"; exit 1; }

PROTON_DIR="$ROOT/.proton"
# Proton expects a compat data directory and a Steam client path to exist even when no Steam app is involved.
mkdir -p "$PROTON_DIR/compatdata" "$BASE/.steam/steam" "$BASE/.config" || exit 1

if [[ -x "$PROTON_DIR/proton" ]]; then
    echo "Proton $(cat "$PROTON_DIR/version" 2>/dev/null | awk '{print $NF}') already installed. Skipping"
    exit 0
fi

echo "Resolving the latest Proton GE release..."
ASSETS=$(curl -fsSL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
         | grep -oE 'https://[^"]+/GE-Proton[^"]+\.tar\.gz')
# Releases list an aarch64 build alongside the x86_64 one, and it is listed first. Pick by architecture
# rather than by position, or the wrong binary unpacks cleanly and only fails when it is run.
case "$(uname -m)" in
    aarch64|arm64) URL=$(grep -iE 'aarch64|arm64' <<<"$ASSETS" | head -1) ;;
    *)             URL=$(grep -ivE 'aarch64|arm64' <<<"$ASSETS" | head -1) ;;
esac
if [[ -z "$URL" ]]; then
    echo "ERROR: could not resolve a Proton GE release for $(uname -m) from GitHub."
    exit 1
fi

echo "Downloading ${URL##*/}"
if ! curl -fsSL -o "$PROTON_DIR/proton.tar.gz" "$URL"; then
    echo "ERROR: the Proton download failed."
    rm -f "$PROTON_DIR/proton.tar.gz"
    exit 1
fi

tar -xzf "$PROTON_DIR/proton.tar.gz" --strip-components=1 -C "$PROTON_DIR" || {
    echo "ERROR: could not unpack Proton."; rm -f "$PROTON_DIR/proton.tar.gz"; exit 1; }
rm -f "$PROTON_DIR/proton.tar.gz"

[[ -x "$PROTON_DIR/proton" ]] || { echo "ERROR: Proton was unpacked but no proton binary was found."; exit 1; }
echo "Proton $(cat "$PROTON_DIR/version" 2>/dev/null | awk '{print $NF}') installed"
