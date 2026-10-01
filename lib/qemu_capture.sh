#!/usr/bin/env bash
# qemu_capture.sh — record a libvirt/QEMU guest's DISPLAY, from firmware to login.
#
# Not a screen recorder: it polls the guest's own framebuffer (`virsh screenshot`,
# i.e. QMP screendump) and stitches the frames, with their real timestamps, into a
# video. That makes it independent of the host compositor, of any remote-viewer /
# virt-manager window, and of whether the host session is locked.
#
# Usage:
#   qemu_capture.sh start  <out-dir> <domain> [--interval S] [--wait S]
#   qemu_capture.sh stop   <out-dir>
#   qemu_capture.sh build  <out-dir> <out.mp4> [--fps N] [--size WxH]
#   qemu_capture.sh verify <out-dir|file.mp4>
#   qemu_capture.sh status <out-dir>
#
# `start` may be run BEFORE the domain is started. It waits (up to --wait, default
# 900s -- a gozer queue can be long) for the domain to reach `running`, then
# grabs from the first frame the guest produces. That ordering is the whole point:
# attach afterwards and the firmware/bootloader screens are already gone.
#
# WHAT THIS CANNOT SEE (be honest in anything you ship made from it)
# -------------------------------------------------------------------
#   * The MOUSE POINTER. SPICE/VNC draw the cursor client-side, so a screendump of
#     the guest framebuffer never contains it. Keyboard-driven demos are fine; a
#     demo where the pointer's movement matters is not -- use lib/screen_capture.sh
#     on the viewer window for that instead.
#   * Anything faster than the screenshot rate (a few fps; `summary.txt` reports
#     the rate actually achieved). Boot text and splash screens are fine, smooth
#     animation will look choppy.
#
# HOW IT TELLS A REAL CAPTURE FROM A FAKE ONE
# -------------------------------------------
# `virsh screenshot` can succeed and hand back a blank or never-changing frame
# (display not initialised yet, wrong console, device without a framebuffer).
# So `build` always runs `verify`, which fails -- loudly -- if every sampled frame
# is a single colour OR if the whole capture contains fewer than 2 distinct frames
# (a boot is not a still image). Pillow missing is fatal, not a pass: without it
# nothing here can judge the frames. (Same rule as screen_capture.sh.)
#
# Layout of <out-dir>:
#   meta.env        domain, initial state, start time   (read back by summary)
#   frames/f_NNNNNN.img   one file per DISTINCT frame (md5-deduped), PPM or PNG
#   ticks.log       "<epoch> ok <md5> <kept 0|1>" or "<epoch> fail" per attempt
#   grabber.pid / grabber.log
#   frames.ffconcat, summary.txt           written by build
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { echo "qemu_capture: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- virsh access ---------------------------------------------------------
# The QB2 domain lives under the SYSTEM libvirtd. Plain `virsh` defaults to the
# per-user session instance and would report "no such domain". Prefer direct
# access (libvirt group), fall back to non-interactive sudo; never prompt, since
# the grabber runs detached and a password prompt would hang it forever.
CONNECT="${QEMU_CAPTURE_CONNECT:-qemu:///system}"
VIRSH=()
virsh_init() {
  have virsh || die "virsh not found (apt install libvirt-clients)"
  if virsh -c "$CONNECT" list >/dev/null 2>&1; then
    VIRSH=(virsh -c "$CONNECT")
  elif sudo -n virsh -c "$CONNECT" list >/dev/null 2>&1; then
    VIRSH=(sudo -n virsh -c "$CONNECT")
  else
    die "cannot talk to libvirt at $CONNECT as $USER (not in the libvirt group, and 'sudo -n' needs a password).
  Fix: add yourself to the libvirt group, or run 'sudo -v' first in this terminal."
  fi
}

# Temp dirs are removed by one EXIT trap. (A `trap ... RETURN` inside a function
# is NOT scoped to it: it stays armed and fires on the next function's return, where
# the local it references is gone -- an "unbound variable" under `set -u`.)
TMPS=()
mk_tmp() { MK_TMP="$(mktemp -d)"; TMPS+=("$MK_TMP"); }   # sets $MK_TMP; not $(...)-able: a subshell would lose TMPS
trap 'for d in "${TMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done' EXIT

# One-line domain state, or "gone" if virsh failed. NEVER write this as
# `virsh domstate | head -1 || echo gone`: under `set -o pipefail`, head closing the
# pipe early SIGPIPEs virsh, the pipeline "fails", and the fallback APPENDS "gone" to
# a state that was really "running" -- which the grabber read as "guest powered off"
# and ended a live recording mid-demo. Capture first, trim second, no pipe.
domstate_of() {
  local out
  out="$("${VIRSH[@]}" domstate "$1" 2>/dev/null)" || { echo gone; return; }
  out="${out%%$'\n'*}"; echo "${out:-gone}"
}

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# --- start ----------------------------------------------------------------
cmd_start() {  # cmd_start <out-dir> <domain> [--interval S] [--wait S]
  [ $# -ge 2 ] || die "usage: start <out-dir> <domain> [--interval S] [--wait S]"
  local out="$1" dom="$2" interval=0 wait=900 resume=0; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume)   resume=1; shift ;;
      --interval) interval="$2"; shift 2 ;;
      --wait)     wait="$2"; shift 2 ;;
      *) die "start: unknown option $1" ;;
    esac
  done
  virsh_init
  "${VIRSH[@]}" dominfo "$dom" >/dev/null 2>&1 || die "start: no domain named '$dom' on $CONNECT"

  mkdir -p "$out"
  # Never overwrite footage: a second `start` into a used directory would
  # interleave two boots into one timeline.
  if [ -f "$out/grabber.pid" ] && pid_alive "$(cat "$out/grabber.pid")"; then
    die "start: a grabber is already running for $out (pid $(cat "$out/grabber.pid"))"
  fi
  if [ "$resume" = 0 ] && [ -d "$out/frames" ] && [ -n "$(ls -A "$out/frames" 2>/dev/null)" ]; then
    die "start: $out already holds frames; pick a new directory (refusing to mix two takes)
  (--resume continues the SAME take after a grabber died, and records the gap)"
  fi
  mkdir -p "$out/frames"
  if [ "$resume" = 1 ]; then
    [ -s "$out/ticks.log" ] || die "start: --resume needs an existing take (no ticks.log in $out)"
    # Time between the dead grabber's last tick and now is footage we do NOT have.
    # Mark it so build cuts across it instead of freezing the last frame over it.
    echo "$(date +%s.%N) gap" >> "$out/ticks.log"
  else
    : > "$out/ticks.log"
  fi

  # Record what state the guest was in when we began. A capture that began on an
  # already-running guest is NOT an end-to-end boot, and summary.txt must say so.
  local init; init="$(domstate_of "$dom")"
  [ "$resume" = 1 ] || {
    # Plain KEY=value (NOT printf %q: it writes "shut\ off", which then fails to
    # compare equal to "shut off" and falsely flags a good take as not-end-to-end).
    printf 'DOMAIN=%s\n' "$dom"
    printf 'INITIAL_STATE=%s\n' "$init"
    printf 'GRAB_STARTED_AT=%s\n' "$(date +%s.%N)"
  } > "$out/meta.env"

  # Detach. setsid is correct here (unlike OBS in screen_capture.sh): virsh
  # needs no graphical-session/portal association.
  setsid "$HERE/$(basename "${BASH_SOURCE[0]}")" _grab "$out" "$dom" "$interval" "$wait" >>"$out/grabber.log" 2>&1 < /dev/null &
  echo $! > "$out/grabber.pid"
  disown || true
  sleep 0.5
  pid_alive "$(cat "$out/grabber.pid")" || die "start: grabber exited immediately; see $out/grabber.log"
  echo "qemu_capture: grabber pid $(cat "$out/grabber.pid") watching '$dom' (state: $init) -> $out"
}

# --- the grabber loop (internal; runs detached) ---------------------------
cmd__grab() {  # cmd__grab <out> <dom> <interval> <wait>
  local out="$1" dom="$2" interval="$3" wait="$4"
  virsh_init
  trap 'echo "[grab] stopped by signal"; exit 0' TERM INT

  local n; n="$(ls "$out/frames" | wc -l)"
  local last="" started=0 deadline state t h f tmp="$out/.shot.tmp"
  deadline=$(( $(date +%s) + wait ))
  echo "[grab] waiting for '$dom' to be running (up to ${wait}s)"
  while :; do
    state="$(domstate_of "$dom")"
    case "$state" in
      running|paused) started=1 ;;
      *)
        # Left the running state AFTER we started => the guest powered off; the
        # take is over. Before we started => still waiting for it to boot.
        if [ "$started" = 1 ]; then echo "[grab] domain is '$state'; ending capture"; break; fi
        if [ "$(date +%s)" -ge "$deadline" ]; then echo "[grab] gave up waiting (${wait}s); domain stayed '$state'"; exit 3; fi
        sleep 0.2; continue ;;
    esac

    t="$(date +%s.%N)"
    rm -f "$tmp"
    if "${VIRSH[@]}" screenshot "$dom" "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ]; then
      h="$(md5sum < "$tmp" | cut -d' ' -f1)"
      if [ "$h" != "$last" ]; then
        n=$(( n + 1 )); f="$(printf '%s/frames/f_%06d.img' "$out" "$n")"
        mv "$tmp" "$f"; last="$h"
        echo "$t ok $h 1" >> "$out/ticks.log"
      else
        echo "$t ok $h 0" >> "$out/ticks.log"
      fi
    else
      echo "$t fail" >> "$out/ticks.log"
      sleep 0.2          # don't spin on a display that isn't up yet
    fi
    [ "$interval" = 0 ] || sleep "$interval"
  done
}

# --- stop -----------------------------------------------------------------
cmd_stop() {  # cmd_stop <out-dir>
  [ $# -ge 1 ] || die "usage: stop <out-dir>"
  local out="$1" pid i
  [ -f "$out/grabber.pid" ] || die "stop: no grabber.pid in $out"
  pid="$(cat "$out/grabber.pid")"
  if pid_alive "$pid"; then
    # SIGTERM only: the loop traps it and exits between screenshots, so we never
    # leave a half-written frame as the final one.
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 100); do pid_alive "$pid" || break; sleep 0.1; done
    pid_alive "$pid" && { kill -KILL "$pid" 2>/dev/null || true; echo "qemu_capture: grabber needed SIGKILL" >&2; }
  else
    echo "qemu_capture: grabber (pid $pid) had already exited (guest powered off?)"
  fi
  rm -f "$out/.shot.tmp"
  echo "qemu_capture: stopped. $(ls "$out/frames" | wc -l) distinct frames, $(wc -l < "$out/ticks.log") attempts"
}

cmd_status() {  # cmd_status <out-dir>
  local out="$1" pid
  [ -f "$out/grabber.pid" ] || die "status: no grabber in $out"
  pid="$(cat "$out/grabber.pid")"
  if pid_alive "$pid"; then echo "grabber: RUNNING (pid $pid)"; else echo "grabber: not running"; fi
  echo "distinct frames: $(ls "$out/frames" 2>/dev/null | wc -l)   attempts: $(wc -l < "$out/ticks.log")   failed: $(grep -c ' fail$' "$out/ticks.log" || true)"
}

# --- judging frames -------------------------------------------------------
# Reads image paths on argv. Exit: 0 = real content, 1 = BLANK, 2 = cannot judge.
# Three-valued on purpose (see screen_capture.sh): "cannot judge" must never be
# collapsed into "fine", or a box without Pillow waves through an all-black take.
_judge_frames() {
  python3 - "$@" <<'PY'
import sys
try:
    from PIL import Image
except ImportError:
    sys.exit(2)
blank = 0
for p in sys.argv[1:]:
    im = Image.open(p).convert("RGB")
    if len(set(im.getdata())) < 3:     # a text screen is >= 2 colours; <3 is "nothing"
        blank += 1
print(f"{len(sys.argv)-1 - blank}/{len(sys.argv)-1} sampled frames have content")
sys.exit(1 if blank == len(sys.argv) - 1 else 0)
PY
}

_judge_or_die() {  # _judge_or_die <what> <images...>
  local what="$1" rc=0; shift
  [ $# -gt 0 ] || die "verify: no frames to judge in $what"
  _judge_frames "$@" || rc=$?
  case "$rc" in
    0) ;;
    1) die "verify: BLANK CAPTURE -- every sampled frame in $what is a single colour.
  The guest display returned nothing. Check the guest has a video device and that
  the domain's graphics (SPICE/VNC) is up; 'virsh screenshot <dom> x.ppm' by hand." ;;
    *) die "verify: cannot judge the frames -- python3 has no Pillow (python3 -m pip install Pillow).
  Refusing to vouch for footage nothing looked at." ;;
  esac
}

cmd_verify() {  # cmd_verify <out-dir|file.mp4>
  local target="$1" tmp; mk_tmp; tmp="$MK_TMP"
  [ -e "$target" ] || die "verify: no such path: $target"
  if [ -d "$target" ]; then
    local files=() total i
    total="$(ls "$target/frames" 2>/dev/null | wc -l)"
    [ "$total" -ge 1 ] || die "verify: $target/frames is empty -- nothing was captured"
    # A boot passes through firmware, bootloader, kernel, login. If the
    # framebuffer never changed, we captured a still -- whatever it shows.
    [ "$total" -ge 2 ] || die "verify: only 1 distinct frame in the whole capture.
  The display never changed. That is a still image, not a boot sequence."
    # Evenly spaced sample across the take, not the first N (the first frames are
    # routinely the least interesting -- and the last is the one that proves it booted).
    mapfile -t all < <(ls "$target/frames"/f_*.img)
    for i in 0 1 2 3 4 5; do files+=("${all[$(( i * (${#all[@]} - 1) / 5 ))]}"); done
    _judge_or_die "$target" "${files[@]}"
    echo "verify: OK -- $total distinct frames in $target"
  else
    have ffmpeg || die "verify: ffmpeg not installed"
    local dur frac at n=0 imgs=()
    dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$target" 2>/dev/null || true)"
    dur="${dur%%.*}"; [ -n "$dur" ] && [ "$dur" -gt 0 ] 2>/dev/null || dur=10
    for frac in 5 25 50 75 95; do
      at=$(( dur * frac / 100 )); n=$(( n + 1 ))
      ffmpeg -hide_banner -loglevel error -ss "$at" -i "$target" -frames:v 1 -y "$tmp/s$n.png" 2>/dev/null || continue
      [ -s "$tmp/s$n.png" ] && imgs+=("$tmp/s$n.png")
    done
    _judge_or_die "$target" "${imgs[@]}"
    echo "verify: OK -- real content in $target"
  fi
}

# --- build ----------------------------------------------------------------
cmd_build() {  # cmd_build <out-dir> <out.mp4> [--fps N] [--size WxH]
  [ $# -ge 2 ] || die "usage: build <out-dir> <out.mp4> [--fps N] [--size WxH]"
  local out="$1" mp4="$2" fps=30 size=""; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --fps)  fps="$2"; shift 2 ;;
      --size) size="$2"; shift 2 ;;
      *) die "build: unknown option $1" ;;
    esac
  done
  have ffmpeg || die "build: ffmpeg not installed"
  [ -s "$out/ticks.log" ] || die "build: no ticks.log in $out -- was this directory ever captured into?"
  # Refuse BEFORE encoding: a blank or single-frame capture should never reach an mp4.
  cmd_verify "$out"

  # ffconcat with per-frame durations taken from the REAL capture timestamps, so
  # a 3-second GRUB menu lasts 3 seconds in the video. Frames are variable size
  # (SeaBIOS 720x400 text -> GRUB -> plymouth -> GDM), so everything is
  # fitted+letterboxed onto one canvas -- the largest frame seen unless --size.
  python3 - "$out" "$size" <<'PY'
import os, sys, glob
from PIL import Image
out, size = sys.argv[1], sys.argv[2]
frames = sorted(glob.glob(os.path.join(out, "frames", "f_*.img")))
kept, last_t, ok, fail = [], None, 0, 0
cut = {}          # kept-frame index -> time its footage really ends (a gap follows it)
gaps = []         # (gap_start, gap_end): footage we do not have
for line in open(os.path.join(out, "ticks.log")):
    p = line.split()
    if len(p) >= 4 and p[1] == "ok":
        ok += 1; last_t = float(p[0])
        if p[3] == "1": kept.append(float(p[0]))
    elif len(p) >= 2 and p[1] == "fail":
        fail += 1; last_t = float(p[0])
    elif len(p) >= 2 and p[1] == "gap" and last_t is not None:
        # grabber died after last_t and a --resume began at p[0]. Hold the last frame
        # briefly, then CUT -- never freeze it across time we did not record.
        gaps.append((last_t, float(p[0])))
        if kept: cut[len(kept) - 1] = last_t + 0.5
if len(kept) != len(frames):
    sys.exit(f"build: ticks.log says {len(kept)} kept frames but frames/ has {len(frames)} -- refusing to guess the timing")
W = H = 0
for f in frames:
    w, h = Image.open(f).size; W, H = max(W, w), max(H, h)
if size:
    W, H = map(int, size.lower().split("x"))
W, H = W + W % 2, H + H % 2          # yuv420p needs even dimensions
with open(os.path.join(out, "frames.ffconcat"), "w") as fh:
    fh.write("ffconcat version 1.0\n")
    for i, f in enumerate(frames):
        # Each frame is held until the next DISTINCT one appeared; the last is
        # held until the final capture attempt (+1s so the end state is readable).
        end = kept[i + 1] if i + 1 < len(kept) else (last_t + 1.0)
        if i in cut: end = min(end, cut[i])
        fh.write(f"file '{os.path.abspath(f)}'\nduration {max(end - kept[i], 0.04):.3f}\n")
    fh.write(f"file '{os.path.abspath(frames[-1])}'\n")   # concat demuxer drops the last duration without this
span = (last_t - kept[0]) - sum(b - a for a, b in gaps) if kept else 0
meta = dict(l.strip().split("=", 1) for l in open(os.path.join(out, "meta.env")) if "=" in l)
init = meta.get("INITIAL_STATE", "?").strip()
lines = [
    f"canvas          : {W}x{H}",
    f"first->last frame: {span:.1f}s",
    f"capture attempts: {ok + fail}  (ok {ok}, failed {fail})",
    f"distinct frames : {len(frames)}",
    *([f"!! {len(gaps)} GAP(S) in the footage (grabber died and was resumed): "
       + ", ".join(f"{b - a:.0f}s" for a, b in gaps) + " not recorded -- the video cuts across them"]
      if gaps else []),
    f"achieved rate   : {ok / span:.2f} screenshots/s" if span > 0 else "achieved rate   : n/a",
    f"domain state when capture began: {init}",
]
if init != "shut off":
    lines.append("  !! the guest was NOT shut off when capture began -- this is NOT an end-to-end boot")
lines.append("NOTE: the mouse pointer is not in a framebuffer screendump (drawn client-side).")
open(os.path.join(out, "summary.txt"), "w").write("\n".join(lines) + "\n")
open(os.path.join(out, ".canvas"), "w").write(f"{W}x{H}")
PY
  local canvas; canvas="$(cat "$out/.canvas")"
  # Resample with the fps FILTER + -fps_mode cfr, not a bare output `-r`. Measured on a real
  # 97.6s boot capture (frames held 27-32s): `-r 30` gave 117.6s, `fps=30` alone 70.9s,
  # `-fps_mode vfr` 72.8s; only fps filter + cfr gave the true 97.6s. Short holds hide this.
  ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$out/frames.ffconcat" \
    -vf "scale=${canvas%x*}:${canvas#*x}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${canvas%x*}:${canvas#*x}:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p,fps=$fps" \
    -fps_mode cfr -c:v libx264 -crf 18 -movflags +faststart "$mp4"
  [ -s "$mp4" ] || die "build: ffmpeg produced no file"
  cat "$out/summary.txt"
  cmd_verify "$mp4"          # judge the artifact we are about to hand over, not just its inputs
  echo "qemu_capture: wrote $mp4"
}

case "${1:-}" in
  start)  shift; cmd_start "$@" ;;
  _grab)  shift; cmd__grab "$@" ;;
  stop)   shift; cmd_stop "$@" ;;
  status) shift; cmd_status "$@" ;;
  build)  shift; cmd_build "$@" ;;
  verify) shift; [ $# -ge 1 ] || die "usage: verify <out-dir|file.mp4>"; cmd_verify "$@" ;;
  *) die "usage: $(basename "$0") {start|stop|status|build|verify} ..." ;;
esac
