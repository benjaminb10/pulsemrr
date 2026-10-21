#!/bin/zsh
# Packs build/PulseMRR.app into build/PulseMRR.dmg with a laid out window: background with an arrow,
# large icons, the app on the left and Applications on the right. The layout is written into the image
# by dmgbuild (Icons/dmg-settings.py), so the window opens right from the first frame. Called by build.sh.
set -e
cd "${0:A:h}"
if [[ ! -x build/venv/bin/dmgbuild ]]; then
  python3 -m venv build/venv
  build/venv/bin/pip install -q dmgbuild
fi
/bin/rm -f build/PulseMRR.dmg
build/venv/bin/dmgbuild -s Icons/dmg-settings.py -D app=build/PulseMRR.app "PulseMRR" build/PulseMRR.dmg >/dev/null
