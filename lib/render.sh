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
    DISPLAY_NUM=":99"; FONT="Ubuntu Mono"; FONT_SIZE=13; SPEED="${SPEED:-1}"
    pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true; sleep 0.3
    Xvfb "$DISPLAY_NUM" -screen 0 4096x2160x24 & XVFB=$!; sleep 0.8
    IN_Q=$(printf '%q' "$IN")
    DISPLAY="$DISPLAY_NUM" xterm -geometry 200x50+0+0 -fa "$FONT" -fs "$FONT_SIZE" \
      -bg "#0F2A35" -fg "#E8F0F2" -title ttcap \
      -e bash -c "asciinema play --speed $SPEED $IN_Q; sleep 2" & XT=$!; sleep 1.5
    G=$(DISPLAY="$DISPLAY_NUM" xwininfo -name ttcap | awk '/Width:/{w=$2}/Height:/{h=$2}/Absolute upper-left X:/{x=$NF}/Absolute upper-left Y:/{y=$NF}END{print w"x"h"+"x"+"y}')
    W=$(echo "$G" | cut -dx -f1); W=$(((W/2)*2))
    H=$(echo "$G" | cut -dx -f2 | cut -d+ -f1); H=$(((H/2)*2))
    XOFF=$(echo "$G" | cut -d+ -f2); YOFF=$(echo "$G" | cut -d+ -f3)
    ffmpeg -y -f x11grab -video_size "${W}x${H}" -i "$DISPLAY_NUM+$XOFF,$YOFF" -codec:v libx264 -pix_fmt yuv420p "$OUT" &
    FF=$!
    wait "$XT" 2>/dev/null || true
    kill "$FF" 2>/dev/null || true; wait "$FF" 2>/dev/null || true
    kill "$XVFB" 2>/dev/null || true
    ;;
  *) echo "usage: render.sh gif|mp4 <in.cast> <out>" >&2; exit 2 ;;
esac
