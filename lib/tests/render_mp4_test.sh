#!/usr/bin/env bash
# Tests for the mp4 path of lib/render.sh (Xvfb + xterm + ffmpeg).
#
# Two regressions this guards, both found rendering a real TUI recording:
#  1. A recording that sets the terminal title renamed the xterm window, so the
#     `xwininfo -name ttcap` lookup found nothing and the render died, leaving
#     Xvfb/xterm/asciinema running. The fixture sets the title on purpose; a
#     fixture that never touches the title cannot catch this.
#  2. render.sh used `pkill -f "Xvfb :99"`, which also kills the CALLER's shell
#     whenever its command line mentions that string. The marker below makes
#     the calling shell's command line contain it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RENDER="$HERE/../render.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

for t in Xvfb xterm asciinema ffmpeg ffprobe python3; do
  command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }
done

# 80x24 recording of ~3 s that sets the window title via OSC 0 and OSC 2, and
# pushes the title with CSI 22 t like tmux does.
printf '%s\n' \
  '{"version":2,"width":80,"height":24}' \
  '[0.2,"o","\u001b[22;0;0t\u001b]0;not-ttcap\u0007\u001b]2;also-not-ttcap\u0007hello\r\n"]' \
  '[1.5,"o","still here\r\n"]' \
  '[3.0,"o","done\r\n"]' > "$TMP/title.cast"

count() { pgrep -c -x "$1" || true; }
xvfb_before=$(count Xvfb); xterm_before=$(count xterm)

# The comment is the marker for regression 2; if render.sh pkill -f's it, this
# shell dies and the `echo` below never runs.
bash -c "bash '$RENDER' mp4 '$TMP/title.cast' '$TMP/out.mp4' >'$TMP/log' 2>&1 # Xvfb :99" \
  || { grep -v 'keysym\|^>' "$TMP/log" | tail -3; fail "render.sh exited nonzero"; }
echo "caller survived"

[[ -s "$TMP/out.mp4" ]] || { tail -5 "$TMP/log"; fail "no mp4 produced"; }
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/out.mp4")
awk -v d="$dur" 'BEGIN{exit !(d > 2)}' || fail "mp4 too short: ${dur}s"

[[ "$(count Xvfb)" == "$xvfb_before" ]]   || fail "render left an Xvfb running"
[[ "$(count xterm)" == "$xterm_before" ]] || fail "render left an xterm running"

echo "render mp4 tests passed"
