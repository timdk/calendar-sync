#!/bin/bash
# Builds CalSync.app into ./build.   ./build.sh install  also copies it to
# ~/Applications and (re)launches it.   ./build.sh screenshots  renders the
# README screenshots (fake calendars) into docs/.
#
# Signing: ad-hoc by default, which means macOS may ask for calendar access
# again after every rebuild. Set CALSYNC_SIGN_IDENTITY to a code-signing
# certificate name to keep the approval across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/CalSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CalSync "$APP/Contents/MacOS/CalSync"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${CALSYNC_SIGN_IDENTITY:--}" --identifier local.calsync "$APP"
echo "Built $APP"

if [[ "${1:-}" == "screenshots" ]]; then
    # Launched via LaunchServices (-n: alongside a running copy) so its windows
    # can become key and render with the accent colour.
    open -n -W "$APP" --args --demo-screenshots "$PWD/docs"
    echo "Wrote docs/settings.png and docs/menu.png"
fi

if [[ "${1:-}" == "install" ]]; then
    pkill -x CalSync 2>/dev/null && sleep 1 || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/CalSync.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/CalSync.app
    echo "Installed and launched ~/Applications/CalSync.app"
fi
