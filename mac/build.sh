#!/bin/zsh
# Sestavi Mac aplikaci Older Sidecar (Intel i Apple Silicon, macOS 12.3+)
# do dist/Older Sidecar.app a dist/OlderSidecar-mac.zip.
set -e
cd "$(dirname "$0")/.."
# Sestavuje se v docasne slozce: iCloud a spol. pridavaji k souborum atributy, se kterymi codesign nepodepise
T=$(mktemp -d)
A="$T/Older Sidecar.app"

mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
clang -fobjc-arc -O2 -Wall -arch arm64 -arch x86_64 -mmacosx-version-min=12.3 mac/main.m -o "$A/Contents/MacOS/OlderSidecar" \
    -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
    -framework VideoToolbox -framework ImageIO -framework IOKit
cp mac/Info.plist "$A/Contents/"
cp mac/AppIcon.icns mac/Kov.png mac/Kov@2x.png "$A/Contents/Resources/"
cp -R mac/*.lproj "$A/Contents/Resources/"
xattr -cr "$A"
# Stalym certifikatem (je-li v Klicence), aby si macOS pamatoval povoleni i po aktualizaci;
# jinak ad hoc podpis (povoleni se pak po kazdem sestaveni musi dat znovu)
PODPIS=$(security find-identity -p codesigning 2>/dev/null | awk '/"Older Sidecar Signing"/ {print $2; exit}')
codesign -s "${PODPIS:--}" --force --timestamp=none "$A"

mkdir -p dist
rm -rf "dist/Older Sidecar.app" dist/OlderSidecar-mac.zip
ditto -c -k --norsrc --noextattr --keepParent "$A" dist/OlderSidecar-mac.zip
cp -R "$A" dist/
# DMG: appka a odkaz na Aplikace, staci pretahnout
VERZE=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" mac/Info.plist)
D=$(mktemp -d)
cp -R "$A" "$D/"
ln -s /Applications "$D/Applications"
rm -f dist/OlderSidecar-*.dmg(N)
hdiutil create -quiet -volname "Older Sidecar $VERZE" -srcfolder "$D" -ov -format UDZO "dist/OlderSidecar-$VERZE.dmg"
rm -rf "$D"
rm -rf "$T"
echo "Hotovo: dist/OlderSidecar-$VERZE.dmg"
