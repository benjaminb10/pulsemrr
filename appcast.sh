#!/bin/zsh
# Writes appcast.xml for a published version: what installed copies read once a day to offer the update.
# The release notes are the GitHub release's, rendered to HTML by GitHub and shown in Sparkle's window.
# Usage: ./appcast.sh 0.9.1 (after the release exists, with build/PulseMRR.dmg the file attached to it)
set -e
cd "${0:A:h}"
VERSION=$1
REPO=benjaminb10/pulsemrr
DMG=build/PulseMRR.dmg
BUILD=$(defaults read "$PWD/build/PulseMRR.app/Contents/Info" CFBundleVersion)
SIG=$(build/vendor/sparkle-*/bin/sign_update --account app.pulsemrr "$DMG")   # sparkle:edSignature="…" length="…"
BODY=$(gh release view "v$VERSION" -R $REPO --json body -q .body)
HTML=$(gh api markdown -f text="$BODY" -f mode=gfm -f context=$REPO)

cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>PulseMRR</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>PulseMRR $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
<style>
  :root { color-scheme: light dark; }
  body { font: 13px -apple-system, sans-serif; line-height: 1.45; margin: 14px 16px; }
  h1, h2, h3 { font-size: 14px; margin: 0 0 8px; }
  ul { padding-left: 18px; margin: 6px 0; } li { margin: 4px 0; }
  code { font: 12px ui-monospace, monospace; background: rgba(127,127,127,.15); padding: 1px 4px; border-radius: 4px; }
  a { color: #594FE0; }
</style>
$HTML
      ]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/PulseMRR.dmg" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "appcast.xml: $VERSION (build $BUILD)"
