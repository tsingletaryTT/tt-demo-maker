#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# single-pane capture of an echo
bash "$LIB/tmux_capture.sh" "$TMP/one.cast" 100 30 bash -c 'echo TTDEMO_MARKER; sleep 1'
[[ -s "$TMP/one.cast" ]] || { echo "FAIL: no cast written"; exit 1; }
grep -q "TTDEMO_MARKER" "$TMP/one.cast" || { echo "FAIL: marker not captured"; exit 1; }

# render that cast to a gif
bash "$LIB/render.sh" gif "$TMP/one.cast" "$TMP/one.gif"
[[ -s "$TMP/one.gif" ]] || { echo "FAIL: no gif produced"; exit 1; }

echo "capture tests passed"
