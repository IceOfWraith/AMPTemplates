#!/bin/bash

SCRIPT_NAME=$(echo \"$0\" | xargs readlink -f)
SCRIPTDIR=$(dirname "$SCRIPT_NAME")

echo "Starting Xvfb"
exec 6>display.log
/usr/bin/Xvfb -displayfd 6 -nolisten tcp -nolisten unix &
XVFB_PID=$!
for i in $(seq 1 30); do
  [[ -s display.log ]] && break
  sleep 1
done
if [[ ! -s display.log ]]; then
  echo "Xvfb did not start a display within 30 seconds"
  exec 6>&-
  kill $XVFB_PID 2>/dev/null
  rm -f display.log
  exit 1
fi
read -r DPY_NUM < display.log
rm display.log

export WINEPREFIX="$SCRIPTDIR/aloft/.wine"
export WINEDLLOVERRIDES="mscoree,mshtml="
export WINEARCH=win64
export WINEDEBUG=fixme-all
export DISPLAY=:$DPY_NUM

# Get Wine major version
WINE_VERSION=$(/usr/bin/wine --version | grep -oP '\d+' | head -1)

# Determine correct Wine Mono version
case "$WINE_VERSION" in
  8) MONO_VERSION="8.1.0" ;;
  9) MONO_VERSION="9.4.0" ;;
  10|11) MONO_VERSION="10.4.1" ;;
  *)
    echo "Unsupported Wine version: $WINE_VERSION"
    exec 6>&-
    kill $XVFB_PID
    exit 1
    ;;
esac

# Setup winetricks and install Mono
[[ -f winetricks ]] && rm -f winetricks
echo "Downloading winetricks"
wget -q --timeout=60 --tries=3 https://raw.githubusercontent.com/Winetricks/winetricks/refs/tags/20260125/src/winetricks
chmod +x winetricks

MONO_URL="https://dl.winehq.org/wine/wine-mono/${MONO_VERSION}/wine-mono-${MONO_VERSION}-x86.msi"
echo "Installing Wine Mono $MONO_VERSION"
wget -q --timeout=60 --tries=3 -O "$WINEPREFIX/mono.msi" "$MONO_URL"
/usr/bin/wine msiexec /i "$WINEPREFIX/mono.msi" /qn /quiet /norestart /log "$WINEPREFIX/mono_install.log"

PACKAGES="vcrun2022 wmp11 sound=disabled"
echo "" > winescript_log.txt 2>&1
for PACKAGE in $PACKAGES; do
  #if [[ "$PACKAGE" == "vcrun2022" && "$WINE_VERSION" =~ ^(10|11)$ ]]; then continue; fi
  echo "Installing $PACKAGE"
  ./winetricks -q $PACKAGE >> winescript_log.txt 2>&1
done
rm -rf ~/.cache/winetricks

exec 6>&-
kill $XVFB_PID

exit 0
