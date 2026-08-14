#!/usr/bin/env bash
# screen_capture_test.sh — exercise the blank-capture verifier in BOTH directions.
#
# A verifier that cannot fail is exactly the trap it exists to prevent, so it is
# not enough to check that real footage passes: synthetic black must be rejected,
# and "I couldn't look at the frames" must not be mistaken for "the frames are
# fine". Each case below has burned a real take at some point:
#
#   * an all-black file from an ungranted ScreenCast portal (looks valid, plays black)
#   * a good recording condemned because its FIRST second was black while the
#     compositor handed over the first buffer
#   * a box with no Pillow, where the frame check silently vouched for everything
#
# Hardware-free: every fixture is synthesised with ffmpeg's lavfi sources.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SC="$HERE/../screen_capture.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

have ffmpeg || { echo "SKIP: ffmpeg not installed"; exit 0; }
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: python3 has no Pillow"; exit 0; }

# The verifier refuses outright on a locked session (correctly — a lock screen
# passes every not-black check there is), which would mask every assertion here.
if bash -c "source '$SC' 2>/dev/null; cmd_session_locked" 2>/dev/null; then
  echo "SKIP: session is locked; verify would refuse before reaching these checks"
  exit 0
fi

# --- fixtures ---------------------------------------------------------------
# Real content: a moving test pattern, thousands of colours per frame.
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=320x240:rate=10 \
  -t 6 -c:v libx264 -crf 30 -pix_fmt yuv420p -y "$TMP/content.mp4" \
  || fail "could not synthesise content.mp4"
# The failure this file exists to catch: a plausible file, black all the way down.
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:size=320x240:rate=10 \
  -t 6 -c:v libx264 -crf 30 -pix_fmt yuv420p -y "$TMP/black.mp4" \
  || fail "could not synthesise black.mp4"
# A good take whose first second is black — the shape that got a real 136s
# 1080p60 capture condemned when the verifier judged the whole file at t=1s.
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i color=c=black:size=320x240:rate=10 -t 1.5 \
  -c:v libx264 -crf 30 -pix_fmt yuv420p -y "$TMP/head.mp4" || fail "head fixture"
printf "file '%s'\nfile '%s'\n" "$TMP/head.mp4" "$TMP/content.mp4" > "$TMP/cat.txt"
ffmpeg -hide_banner -loglevel error -f concat -safe 0 -i "$TMP/cat.txt" \
  -c copy -y "$TMP/black-head.mp4" || fail "could not synthesise black-head.mp4"

# Stills bursts, the Spectacle path: same two verdicts, a directory of PNGs.
mkdir -p "$TMP/frames-ok" "$TMP/frames-black"
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=320x240:rate=10 \
  -t 4 "$TMP/frames-ok/f_%05d.png" || fail "could not synthesise ok frames"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:size=320x240:rate=10 \
  -t 4 "$TMP/frames-black/f_%05d.png" || fail "could not synthesise black frames"

# --- the two directions -----------------------------------------------------
out="$(bash "$SC" verify "$TMP/content.mp4" 2>&1)" \
  || fail "real content was rejected: $out"
grep -q "OK" <<<"$out" || fail "content.mp4: expected an OK line, got: $out"
echo "ok: real content passes"

out="$(bash "$SC" verify "$TMP/black.mp4" 2>&1)" \
  && fail "an all-black capture was ACCEPTED — the verifier cannot fail: $out"
grep -q "BLANK CAPTURE" <<<"$out" \
  || fail "black.mp4: rejected, but not as a blank capture: $out"
echo "ok: synthetic black is rejected"

# --- it must not cry wolf on the normal startup frame -----------------------
out="$(bash "$SC" verify "$TMP/black-head.mp4" 2>&1)" \
  || fail "a good take with a black first second was condemned: $out"
# Assert the head really was sampled AND really did read as blank (4 of 5), so
# this stays a test of the tolerance rather than quietly becoming a second
# happy-path check if the sampling points ever move off the head.
grep -q "(4/5 samples)" <<<"$out" \
  || fail "black-head: expected 4/5 non-blank samples (a sampled blank head), got: $out"
echo "ok: a black head does not condemn the whole take"

# --- the stills path --------------------------------------------------------
out="$(bash "$SC" verify "$TMP/frames-ok" 2>&1)" \
  || fail "a real stills burst was rejected: $out"
out="$(bash "$SC" verify "$TMP/frames-black" 2>&1)" \
  && fail "an all-black stills burst was ACCEPTED: $out"
grep -q "BLANK CAPTURE" <<<"$out" || fail "frames-black: wrong rejection: $out"
echo "ok: stills bursts verify in both directions"

# --- cannot judge is not the same as fine -----------------------------------
# Without Pillow the frame check can't tell black from a mountain range. It must
# refuse rather than wave the footage through. Simulated with a python3 shim on
# PATH that exits 2 (the code the real check uses for "no Pillow").
mkdir -p "$TMP/shim"
printf '#!/bin/sh\nexit 2\n' > "$TMP/shim/python3"
chmod +x "$TMP/shim/python3"
out="$(PATH="$TMP/shim:$PATH" bash "$SC" verify "$TMP/content.mp4" 2>&1)" \
  && fail "with no Pillow the verifier vouched for footage it never looked at: $out"
grep -q "Pillow" <<<"$out" || fail "no-Pillow: expected a Pillow diagnostic, got: $out"
echo "ok: refuses when it cannot judge the frames"

# --- argument handling ------------------------------------------------------
out="$(bash "$SC" verify "$TMP/does-not-exist.mp4" 2>&1)" \
  && fail "verify accepted a nonexistent path: $out"
echo "ok: missing path is refused"

echo "screen capture tests passed"
