#!/usr/bin/env bash
# Tests for the mp4 path of lib/render.sh (Xvfb + alacritty/xterm + ffmpeg).
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

for t in Xvfb asciinema ffmpeg ffprobe python3; do
  command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }
done

# 80x24 recording of ~3 s that sets the window title via OSC 0 and OSC 2, and
# pushes the title with CSI 22 t like tmux does.
printf '%s\n' \
  '{"version":2,"width":80,"height":24}' \
  '[0.2,"o","\u001b[22;0;0t\u001b]0;not-ttcap\u0007\u001b]2;also-not-ttcap\u0007hello\r\n"]' \
  '[1.5,"o","still here\r\n"]' \
  '[3.0,"o","done\r\n"]' > "$TMP/title.cast"

# PID sets, not counts: the box is shared, and another session starting or
# stopping its own Xvfb must not fail this test. Only processes that appear
# during the render and are still alive afterwards count as leaks.
pids() { pgrep -x "$1" | sort || true; }
leaked() { comm -13 <(printf '%s\n' "$1") <(pids "$2"); }

# Run the whole render once per terminal emulator that is installed. The
# default (alacritty, else xterm) is what users get; forcing each one keeps the
# fallback from rotting on boxes that have both.
ran=0
for term in alacritty xterm; do
  command -v "$term" >/dev/null || { echo "skip: $term not installed"; continue; }
  ran=$((ran+1))
  xvfb_before=$(pids Xvfb); term_before=$(pids "$term")
  out="$TMP/$term.mp4"

  # The comment is the marker for regression 2; if render.sh pkill -f's it, this
  # shell dies and the `echo` below never runs. AGG_THEME carries a background
  # no default uses (#123456) so the pixel check below proves the theme reaches
  # the terminal rather than a hardcoded color.
  TT_DEMO_TERMINAL="$term" AGG_THEME="123456,E8F0F2,123456,FA512E,4FD1C5,F6BC42,1B8EB1,FF9E8A,74C5DF,E8F0F2" \
    bash -c "bash '$RENDER' mp4 '$TMP/title.cast' '$out' >'$TMP/log' 2>&1 # Xvfb :99" \
    || { grep -v 'keysym\|^>' "$TMP/log" | tail -3; fail "$term: render.sh exited nonzero"; }
  echo "$term: caller survived"

  [[ -s "$out" ]] || { tail -5 "$TMP/log"; fail "$term: no mp4 produced"; }
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")
  awk -v d="$dur" 'BEGIN{exit !(d > 2)}' || fail "$term: mp4 too short: ${dur}s"

  [[ -z "$(leaked "$xvfb_before" Xvfb)" ]]   || fail "$term: render left an Xvfb running"
  [[ -z "$(leaked "$term_before" "$term")" ]] || fail "$term: render left a $term running"

  # Bottom-right pixel is far from any text, so it is the terminal background.
  if python3 -c 'import PIL' 2>/dev/null; then
    ffmpeg -v error -y -ss 1 -i "$out" -frames:v 1 "$TMP/$term.png"
    python3 -I - "$TMP/$term.png" <<'PY' || fail "$term: background is not the theme's #123456"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
r, g, b = im.getpixel((im.width - 3, im.height - 3))
# yuv420p round-trips colors with a few units of error.
ok = abs(r - 0x12) < 8 and abs(g - 0x34) < 8 and abs(b - 0x56) < 8
sys.exit(0 if ok else 1)
PY
    echo "$term: theme background applied"
  fi
done
[[ $ran -gt 0 ]] || { echo "SKIP: no terminal emulator installed"; exit 0; }

echo "render mp4 tests passed"
