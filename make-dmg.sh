#!/bin/zsh
# Packs build/PulseMRR.app into build/PulseMRR.dmg with a laid out window: background with an arrow,
# large icons, the app on the left and Applications on the right. Uses Finder through AppleScript, so it
# needs a logged in session (not a headless CI runner). Called by build.sh.
set -e
cd "${0:A:h}"
APP="build/PulseMRR.app"
RW="build/PulseMRR-rw.dmg"
MNT="$PWD/build/dmg-mount"

/bin/rm -rf build/dmg "$RW" build/PulseMRR.dmg
mkdir -p build/dmg/.background
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
tiffutil -cathidpicheck Icons/dmg-background.png Icons/dmg-background@2x.png -out build/dmg/.background/background.tiff >/dev/null

hdiutil create -quiet -volname "PulseMRR" -fs HFS+ -srcfolder build/dmg -format UDRW -ov "$RW"
mkdir -p "$MNT"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$MNT" "$RW"

osascript <<EOF
tell application "Finder"
  set d to item (POSIX file "$MNT" as alias)
  open d
  set w to container window of d
  set current view of w to icon view
  set toolbar visible of w to false
  set statusbar visible of w to false
  set bounds of w to {200, 120, 840, 548}
  set o to icon view options of w
  set arrangement of o to not arranged
  set icon size of o to 128
  set text size of o to 13
  set background picture of o to file ".background:background.tiff" of d
  set position of item "PulseMRR.app" of d to {170, 190}
  set position of item "Applications" of d to {470, 190}
  update d without registering applications
  delay 1
  close w
end tell
EOF

# The volume icon goes in after the Finder pass, which drops it
cp Icons/PulseMRR.icns "$MNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MNT"
chflags hidden "$MNT/.background" "$MNT/.VolumeIcon.icns"
sync
hdiutil detach -quiet "$MNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o build/PulseMRR.dmg
/bin/rm -rf build/dmg "$RW" "$MNT"
