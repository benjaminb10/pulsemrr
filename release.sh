#!/bin/zsh
# Publishes a version: notarized build, GitHub release with the DMG, the Sparkle appcast (so installed copies
# update themselves) and the Homebrew cask. Usage: ./release.sh 0.9 "What changed, in Markdown"
# Needs: the Developer ID and notarytool profile (build.sh), the Sparkle key in the Keychain (account app.pulsemrr),
# gh logged in, and the tap cloned at ../homebrew-tap.
set -e
cd "${0:A:h}"
VERSION=$1
NOTES=${2:-"PulseMRR $VERSION"}
[[ -z $VERSION ]] && { echo "usage: ./release.sh VERSION \"notes\""; exit 1; }
REPO=benjaminb10/pulsemrr
TAP=../homebrew-tap

VERSION=$VERSION ./build.sh
DMG=build/PulseMRR.dmg

gh release create "v$VERSION" "$DMG" --title "PulseMRR $VERSION" --notes "$NOTES"

# Sparkle reads the newest version from appcast.xml
./appcast.sh "$VERSION"
git add appcast.xml && git commit -q -m "Appcast: PulseMRR $VERSION" && git push -q

# Homebrew: brew install --cask benjaminb10/tap/pulsemrr
if [[ -d $TAP ]]; then
  SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
  sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/pulsemrr.rb"
  git -C "$TAP" commit -q -am "PulseMRR $VERSION" && git -C "$TAP" push -q
fi
echo "Released $VERSION"
