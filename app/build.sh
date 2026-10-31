#!/bin/bash
# Builds build/Jinn.app (ad-hoc signed). Ad-hoc signing changes the code hash each build,
# so a plain ad-hoc signature makes macOS re-ask for permissions after every rebuild. The designated requirement below is pinned to the bundle id instead, so grants should survive.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Jinn.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/Jinn "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"; cp -R Resources/lamp "$APP/Contents/Resources/"
codesign --force --sign - --identifier com.dhivio.jinn -r="designated => identifier \"com.dhivio.jinn\"" "$APP"
echo "Built $APP  (open it, or: $APP/Contents/MacOS/Jinn --ask 'tidy my downloads')"
