#!/bin/zsh
# Builds build/PulseMRR.app (universal, macOS 13+) and build/PulseMRR.dmg.
# Signs with the "Developer ID Application" identity in the keychain when there is one, then notarizes
# with the notarytool profile in $NOTARY_PROFILE (default: encorescreen-notary). SKIP_NOTARIZE=1 to skip.
set -e
cd "${0:A:h}"
VERSION=${VERSION:-0.1}
NOTARY_PROFILE=${NOTARY_PROFILE:-encorescreen-notary}
APP="build/PulseMRR.app"

mkdir -p build && /bin/rm -rf "$APP" build/obj && mkdir -p build/obj
# Sparkle (automatic updates): the official release, fetched once into build/vendor
SPARKLE_VERSION=2.10.0
SPARKLE="build/vendor/sparkle-$SPARKLE_VERSION"
if [[ ! -d $SPARKLE/Sparkle.framework ]]; then
  mkdir -p "$SPARKLE"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" | tar -xJ -C "$SPARKLE"
fi
# Public half of the key that signs updates (the private half stays in the maintainer's Keychain)
SU_PUBLIC_KEY=XEgLTXNKAhjALYj1DGsh8i7KjXvNYP1cTv1KkszfEKc=
SU_FEED=https://raw.githubusercontent.com/benjaminb10/pulsemrr/main/appcast.xml

SOURCES=(Sources/*.swift)
LINK=(-F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 $LINK $SOURCES -o build/obj/arm64
xcrun swiftc -O -swift-version 5 -parse-as-library -target x86_64-apple-macos13.0 $LINK $SOURCES -o build/obj/x86_64
lipo -create build/obj/arm64 build/obj/x86_64 -output build/obj/PulseMRR

mkdir -p "$APP"/Contents/MacOS "$APP"/Contents/Resources "$APP"/Contents/Frameworks
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp build/obj/PulseMRR "$APP/Contents/MacOS/PulseMRR"
[[ -f Icons/PulseMRR.icns ]] && cp Icons/PulseMRR.icns "$APP"/Contents/Resources/AppIcon.icns
cp Sounds/cash.caf "$APP"/Contents/Resources/cash.caf
cp -R Resources/*.lproj "$APP"/Contents/Resources/ && mkdir -p "$APP"/Contents/Resources/en.lproj
cat > "$APP"/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
<key>CFBundleExecutable</key><string>PulseMRR</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>app.pulsemrr</string>
<key>CFBundleName</key><string>PulseMRR</string>
<key>CFBundleDisplayName</key><string>PulseMRR</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSUserNotificationAlertStyle</key><string>alert</string>
<key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
<key>SUFeedURL</key><string>$SU_FEED</string>
<key>SUPublicEDKey</key><string>$SU_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>NSHumanReadableCopyright</key><string>A notification for every Stripe sale.</string>
</dict></plist>
PLIST
/bin/rm -rf build/obj

DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
SIGN=(--force --sign "${DEVID:--}")
[[ -n $DEVID ]] && SIGN+=(--options runtime --timestamp) && echo "Signing with $DEVID"
# Sparkle's helpers first, inside out, then the framework, then the app
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign $SIGN "$FW/XPCServices/Installer.xpc"
codesign $SIGN --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
codesign $SIGN "$FW/Autoupdate"
codesign $SIGN "$FW/Updater.app"
codesign $SIGN "$APP/Contents/Frameworks/Sparkle.framework"
codesign $SIGN "$APP"

./make-dmg.sh

if [[ -n $DEVID && -z $SKIP_NOTARIZE ]]; then
  codesign --force --timestamp --sign "$DEVID" build/PulseMRR.dmg
  xcrun notarytool submit build/PulseMRR.dmg --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/PulseMRR.dmg
  xcrun stapler staple "$APP"
fi
echo "OK: $APP and build/PulseMRR.dmg"
