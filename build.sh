#!/bin/zsh
# Builds build/Kaching.app (universal, macOS 13+) and build/Kaching.dmg.
# Signs with the "Developer ID Application" identity in the keychain when there is one, then notarizes
# with the notarytool profile in $NOTARY_PROFILE (default: encorescreen-notary). SKIP_NOTARIZE=1 to skip.
set -e
cd "${0:A:h}"
VERSION=${VERSION:-0.1}
NOTARY_PROFILE=${NOTARY_PROFILE:-encorescreen-notary}
APP="build/Kaching.app"

mkdir -p build && /bin/rm -rf "$APP" build/obj && mkdir -p build/obj
SOURCES=(Sources/*.swift)
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 $SOURCES -o build/obj/arm64
xcrun swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macos13.0 $SOURCES -o build/obj/x86_64
lipo -create build/obj/arm64 build/obj/x86_64 -output build/obj/Kaching

mkdir -p "$APP"/Contents/MacOS "$APP"/Contents/Resources
cp build/obj/Kaching "$APP/Contents/MacOS/Kaching"
[[ -f Icons/Kaching.icns ]] && cp Icons/Kaching.icns "$APP"/Contents/Resources/AppIcon.icns
cp Sounds/kaching.caf "$APP"/Contents/Resources/kaching.caf
cp -R Resources/*.lproj "$APP"/Contents/Resources/ && mkdir -p "$APP"/Contents/Resources/en.lproj
cat > "$APP"/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
<key>CFBundleExecutable</key><string>Kaching</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>app.kaching</string>
<key>CFBundleName</key><string>Kaching</string>
<key>CFBundleDisplayName</key><string>Kaching</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSUserNotificationAlertStyle</key><string>alert</string>
<key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
<key>NSHumanReadableCopyright</key><string>A notification for every Stripe sale.</string>
</dict></plist>
PLIST
/bin/rm -rf build/obj

DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
if [[ -n $DEVID ]]; then
  echo "Signing with $DEVID"
  codesign --force --options runtime --timestamp --sign "$DEVID" "$APP"
else
  codesign --force --sign - "$APP"
fi

mkdir -p build/dmg && cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "Kaching" -srcfolder build/dmg -ov -format UDZO build/Kaching.dmg
/bin/rm -rf build/dmg

if [[ -n $DEVID && -z $SKIP_NOTARIZE ]]; then
  codesign --force --timestamp --sign "$DEVID" build/Kaching.dmg
  xcrun notarytool submit build/Kaching.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/Kaching.dmg
  xcrun stapler staple "$APP"
fi
echo "OK: $APP and build/Kaching.dmg"
