#!/usr/bin/env bash
# render.sh gif|mp4 <in.cast> <out> — render an asciicast to GIF (agg) or MP4 (Xvfb+xterm+ffmpeg).
set -euo pipefail
MODE="$1"; IN="$2"; OUT="$3"
case "$MODE" in
  gif)
    # Optional theme + encoding knobs arrive as env vars from bin/src/render.rs
    # (AGG_THEME from themes/<theme>.agg; the rest from the manifest's
    # defaults.render). Unset vars mean "use agg's own default".
    ARGS=()
    [[ -n "${AGG_THEME:-}" ]]     && ARGS+=(--theme "$AGG_THEME")
    [[ -n "${AGG_FPS_CAP:-}" ]]   && ARGS+=(--fps-cap "$AGG_FPS_CAP")
    [[ -n "${AGG_FONT_SIZE:-}" ]] && ARGS+=(--font-size "$AGG_FONT_SIZE")
    [[ -n "${AGG_SPEED:-}" ]]     && ARGS+=(--speed "$AGG_SPEED")
    agg "${ARGS[@]}" "$IN" "$OUT"
    ;;
  mp4)
    FONT="Ubuntu Mono"; FONT_SIZE=13; SPEED="${SPEED:-1}"
    XVFB=""; XT=""; FF=""
    # Always tear down what we started. Without this, any failure below (set -e)
    # left Xvfb + xterm + `asciinema play` running, and nothing
    # cleaned them up.
    cleanup() {
      for p in "$FF" "$XT" "$XVFB"; do
        [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
      done
    }
    trap cleanup EXIT
    # Size the terminal to the recording, not a fixed 200x50: the cast header
    # carries the grid (v2: width/height, v3: term.cols/rows).
    COLS=200; ROWS=50
    if read -r c r < <(python3 - "$IN" <<'PY'
import json, sys
h = json.loads(open(sys.argv[1]).readline())
t = h.get("term", {})
print(h.get("width") or t.get("cols") or "", h.get("height") or t.get("rows") or "")
PY
    ) && [[ -n "${c:-}" && -n "${r:-}" ]]; then COLS=$c; ROWS=$r; fi
    # Take the first unused X display instead of hardcoding :99 and `pkill -f`-ing
    # whatever held it. `pkill -f` matches any command line containing the
    # pattern, including the caller's own shell, and it killed other people's
    # Xvfb too.
    DISPLAY_NUM=""
    for n in $(seq 99 140); do
      if [[ ! -e "/tmp/.X11-unix/X$n" && ! -e "/tmp/.X$n-lock" ]]; then DISPLAY_NUM=":$n"; break; fi
    done
    [[ -n "$DISPLAY_NUM" ]] || { echo "render.sh: no free X display in :99-:140" >&2; exit 1; }
    Xvfb "$DISPLAY_NUM" -screen 0 4096x2160x24 & XVFB=$!; sleep 0.8
    IN_Q=$(printf '%q' "$IN")
    # Ignore title/window ops from the recording. A TUI (or tmux) that sets the
    # terminal title renamed the window, so `xwininfo -name ttcap` below found
    # nothing and the render died.
    DISPLAY="$DISPLAY_NUM" xterm -geometry "${COLS}x${ROWS}+0+0" -fa "$FONT" -fs "$FONT_SIZE" \
      -bg "#0F2A35" -fg "#E8F0F2" -title ttcap \
      -xrm 'XTerm*allowTitleOps: false' -xrm 'XTerm*allowWindowOps: false' \
      -e bash -c "asciinema play --speed $SPEED $IN_Q; sleep 2" & XT=$!; sleep 1.5
    G=$(DISPLAY="$DISPLAY_NUM" xwininfo -name ttcap | awk '/Width:/{w=$2}/Height:/{h=$2}/Absolute upper-left X:/{x=$NF}/Absolute upper-left Y:/{y=$NF}END{print w"x"h"+"x"+"y}') \
      || { echo "render.sh: no xterm window named ttcap (did xterm start?)" >&2; exit 1; }
    W=$(echo "$G" | cut -dx -f1); W=$(((W/2)*2))
    H=$(echo "$G" | cut -dx -f2 | cut -d+ -f1); H=$(((H/2)*2))
    XOFF=$(echo "$G" | cut -d+ -f2); YOFF=$(echo "$G" | cut -d+ -f3)
    ffmpeg -y -f x11grab -video_size "${W}x${H}" -i "$DISPLAY_NUM+$XOFF,$YOFF" -codec:v libx264 -pix_fmt yuv420p "$OUT" &
    FF=$!
    wait "$XT" 2>/dev/null || true
    XT=""
    # SIGINT lets ffmpeg write the mp4 trailer; SIGTERM can leave it unplayable.
    kill -INT "$FF" 2>/dev/null || true; wait "$FF" 2>/dev/null || true
    FF=""
    ;;
  *) echo "usage: render.sh gif|mp4 <in.cast> <out>" >&2; exit 2 ;;
esac
