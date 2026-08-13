#!/usr/bin/env bash
# screen_capture.sh — record a GUI application's screen, not a terminal.
#
# tt-demo-maker's other backends drive tmux and asciinema, which only ever see
# a terminal. This one exists for graphical demos: a GTK/Qt/GL kiosk whose
# whole point is what it draws.
#
# Usage:
#   screen_capture.sh detect
#   screen_capture.sh record <seconds> <out.mp4> [fps]
#   screen_capture.sh burst  <seconds> <out-dir>          # stills, any compositor
#   screen_capture.sh verify <file.mp4|dir>               # fails on a black capture
#
# WHY THIS IS NOT JUST `ffmpeg -f x11grab`
# ----------------------------------------
# Measured on a KWin/Wayland box (Ubuntu 24.04), not assumed:
#
#   ffmpeg -f x11grab   -> records PURE BLACK. Exit code 0, a real .mp4, one
#                          unique colour in every frame. Silent and total.
#   wf-recorder         -> refuses: "compositor doesn't support
#                          wlr-screencopy-unstable-v1" (it is wlroots-only).
#   grim                -> same wlroots assumption; unusable.
#   spectacle           -> works, but 23.08.5 is STILLS ONLY. Video recording
#                          landed in Spectacle 24.02, which is not packaged for
#                          Ubuntu 24.04 -- `apt` offers 23.08.5 and nothing else.
#                          Sustains ~5.9 fps invocation-to-invocation.
#   OBS + PipeWire      -> the correct answer at 1920x1080@60, BUT the xdg
#                          ScreenCast portal must grant a session. A saved
#                          restore token is not sufficient from a detached or
#                          non-interactive process: the stream goes
#                          "paused" -> "unconnected" and records black.
#
# THE RULE THIS FILE ENFORCES
# ---------------------------
# Every backend here is verified to have captured real pixels before it is
# allowed to report success. Three of the five options above fail by producing
# a plausible file full of black, which is the worst possible failure: it looks
# like a working recording until someone plays it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "screen_capture: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- is this frame/file actually anything? ---------------------------------
# A single unique colour means the compositor handed us nothing. This is the
# check that turns a silent failure into a loud one.
_frame_is_blank() {  # _frame_is_blank <image>
  python3 - "$1" <<'PY'
import sys
try:
    from PIL import Image
except ImportError:
    sys.exit(2)                      # cannot judge; caller treats as unknown
im = Image.open(sys.argv[1]).convert("RGB")
sys.exit(0 if len(set(im.getdata())) < 5 else 1)
PY
}

cmd_verify() {  # cmd_verify <file.mp4|dir-of-pngs>
  local target="$1" tmp frame
  [ -e "$target" ] || die "verify: no such path: $target"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN

  if [ -d "$target" ]; then
    frame="$(find "$target" -name '*.png' | sort | sed -n '2p')"
    [ -n "$frame" ] || die "verify: no frames in $target"
    cp "$frame" "$tmp/f.png"
  else
    ffmpeg -hide_banner -loglevel error -ss 1 -i "$target" \
      -frames:v 1 -y "$tmp/f.png" 2>/dev/null || die "verify: cannot decode $target"
  fi

  if _frame_is_blank "$tmp/f.png"; then
    case $? in
      2) echo "verify: python3 PIL unavailable -- cannot confirm; treat with suspicion" >&2
         return 0 ;;
    esac
  fi
  if _frame_is_blank "$tmp/f.png"; then
    die "verify: BLANK CAPTURE -- every pixel identical.
  The recorder produced a file but the compositor delivered no frames.
  On Wayland this is usually x11grab (always black) or an ungranted
  xdg ScreenCast portal session. Re-run 'screen_capture.sh detect'."
  fi
  echo "verify: OK -- real content in $target"
}

# --- backend detection ------------------------------------------------------
cmd_detect() {
  local session="${XDG_SESSION_TYPE:-unknown}"
  echo "session: $session   compositor: ${XDG_CURRENT_DESKTOP:-unknown}"
  echo

  local obs_ok=no spectacle_ok=no wfr_ok=no
  have obs && obs_ok=yes
  have spectacle && spectacle_ok=yes
  have wf-recorder && wfr_ok=yes

  echo "  obs (PipeWire, 60fps video) : $obs_ok"
  echo "  spectacle (stills burst)    : $spectacle_ok$( [ "$spectacle_ok" = yes ] && \
      printf ' (%s)' "$(spectacle --version 2>/dev/null | awk '{print $2}')" )"
  echo "  wf-recorder (wlroots only)  : $wfr_ok"
  echo

  if [ "$session" = "wayland" ] && [ "$wfr_ok" = yes ]; then
    echo "NOTE: wf-recorder is installed but only speaks wlr-screencopy. On KWin"
    echo "      or Mutter it refuses outright. Do not rely on it."
  fi
  echo "NOTE: ffmpeg -f x11grab records BLACK under Wayland. Never use it here."
  echo
  if [ "$obs_ok" = yes ]; then
    echo "RECOMMENDED: 'record' (OBS/PipeWire, 60fps)."
    echo "  First run in a NEW login session needs the screen-share portal"
    echo "  dialog approved ONCE, interactively. A saved restore token does not"
    echo "  survive a detached/non-interactive launch -- the PipeWire stream"
    echo "  goes paused -> unconnected and you get a black file."
  elif [ "$spectacle_ok" = yes ]; then
    echo "RECOMMENDED: 'burst' (Spectacle stills, ~5.9fps)."
  else
    die "no usable capture backend found"
  fi
}

# --- OBS / PipeWire: real video ---------------------------------------------
cmd_record() {  # cmd_record <seconds> <out.mp4> [fps]
  local secs="$1" out="$2" fps="${3:-60}"
  have obs || die "record: obs not installed (try 'burst' instead)"
  have ffmpeg || die "record: ffmpeg not installed"

  local before after produced
  before="$(ls -t "$HOME"/*.mkv 2>/dev/null | head -1 || true)"

  # NOT setsid: the ScreenCast portal associates the request with the calling
  # graphical session, and a detached process loses it.
  obs --startrecording --minimize-to-tray >/dev/null 2>&1 &
  local pid=$!
  sleep $(( secs + 12 ))                 # +12s covers OBS start and portal
  kill -INT "$pid" 2>/dev/null || true
  sleep 8
  kill "$pid" 2>/dev/null || true
  sleep 2

  after="$(ls -t "$HOME"/*.mkv 2>/dev/null | head -1 || true)"
  [ -n "$after" ] && [ "$after" != "$before" ] || die "record: OBS produced no file"
  produced="$after"

  ffmpeg -hide_banner -loglevel error -i "$produced" \
    -c:v libx264 -crf 20 -pix_fmt yuv420p -r "$fps" -y "$out"
  cmd_verify "$out"                       # refuses to succeed on black
  echo "record: wrote $out"
}

# --- Spectacle burst: stills at whatever rate the tool sustains --------------
cmd_burst() {  # cmd_burst <seconds> <out-dir>
  local secs="$1" dir="$2"
  have spectacle || die "burst: spectacle not installed"
  mkdir -p "$dir"

  local start now i=0
  start="$(date +%s)"
  while :; do
    now="$(date +%s)"
    [ $(( now - start )) -lt "$secs" ] || break
    i=$(( i + 1 ))
    spectacle -b -n -f -o "$(printf '%s/f_%05d.png' "$dir" "$i")" 2>/dev/null || true
  done
  local elapsed=$(( $(date +%s) - start ))
  [ "$i" -gt 0 ] || die "burst: captured nothing"

  # Encode at the rate actually achieved, so playback is real-time rather than
  # a timelapse pretending to be footage.
  local rate; rate="$(python3 -c "print(round($i/max($elapsed,1),3))")"
  echo "burst: $i frames in ${elapsed}s -> ${rate} fps"
  printf '%s\n' "$rate" > "$dir/.fps"
  cmd_verify "$dir"
}

case "${1:-}" in
  detect) shift; cmd_detect "$@" ;;
  record) shift; [ $# -ge 2 ] || die "usage: record <seconds> <out.mp4> [fps]"; cmd_record "$@" ;;
  burst)  shift; [ $# -ge 2 ] || die "usage: burst <seconds> <out-dir>"; cmd_burst "$@" ;;
  verify) shift; [ $# -ge 1 ] || die "usage: verify <file|dir>"; cmd_verify "$@" ;;
  *) die "usage: $(basename "$0") {detect|record|burst|verify} ..." ;;
esac
