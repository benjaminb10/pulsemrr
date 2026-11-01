#!/bin/sh
# Acceptance run of the dashboard window (every project, every period), to launch after each release. See Tests/recette.py.
set -e
command -v agent-desktop >/dev/null || { echo "agent-desktop missing: npm i -g agent-desktop"; exit 1; }
exec python3 "$(dirname "$0")/recette.py" "$@"
