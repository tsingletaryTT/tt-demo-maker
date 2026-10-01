#!/usr/bin/env bash
# Tests for lib/qemu_capture.sh against a STUB virsh -- no libvirt, no VM, no chip.
#
# What this does and does not prove: it proves the WIRING (grabber waits for the
# guest, starts at the first frame, dedupes, ends when the guest powers off,
# timing survives into the video, and -- the part that matters -- that a blank or
# frozen guest display is REFUSED rather than encoded). It does not prove
# `virsh screenshot` on the real QB2 domain returns a good frame; that is checked
# by the real run's own verify step.
#
# The stub's behaviour is chosen per case via $STUB_MODE:
#   boot  frames change every ~0.4s and alternate 720x400 / 1024x768 (like SeaBIOS -> GDM)
#   black every screenshot is pure black
#   still every screenshot is the same non-blank image
#   flicker every screenshot is a DIFFERENT solid colour -- distinct frames, none with content.
#           (Needed so the blank-colour check is tested on its own: an all-black capture
#           is also caught by the one-distinct-frame check, which would mask a dead
#           blank check. Found by mutation-testing this suite.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CAP="$HERE/../qemu_capture.sh"
TMP="$(mktemp -d)"; trap 'kill $(cat "$TMP"/*/grabber.pid 2>/dev/null) 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/virsh" <<'STUB'
#!/usr/bin/env bash
# stub virsh: only what qemu_capture.sh calls.
while [ $# -gt 0 ]; do
  case "$1" in -c|--connect) shift 2 ;; *) break ;; esac
done
sub="${1:-}"; shift || true
case "$sub" in
  list|dominfo) exit 0 ;;
  domstate)
    cat "$STUB_STATE_FILE"
    # NOISY: keep writing AFTER the first line, like real virsh's trailing blank line.
    # `virsh domstate | head -1` then SIGPIPEs virsh -> pipefail -> a bogus "gone".
    if [ -e "${STUB_NOISY_FILE:-/nonexistent}" ]; then sleep 0.15; echo; echo "(trailing output)"; fi ;;
  screenshot)
    file="$2"
    python3 - "$file" "${STUB_MODE:-boot}" <<'PY'
import sys, time
from PIL import Image, ImageDraw
path, mode = sys.argv[1], sys.argv[2]
if mode == "black":
    im = Image.new("RGB", (720, 400), (0, 0, 0))
elif mode == "flicker":
    k = int(time.time() / 0.3) % 200
    im = Image.new("RGB", (720, 400), (k, k // 2, 255 - k))
else:
    step = 0 if mode == "still" else int(time.time() / 0.4)
    w, h = ((720, 400) if step % 2 == 0 else (1024, 768))
    im = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rectangle([10, 10, 10 + 30 + (step % 40) * 5, 60], fill=(200, 200, 200))
    d.text((20, 80), f"boot step {step}", fill=(255, 255, 255))
im.save(path, "PPM")
PY
    ;;
  *) echo "stub virsh: unhandled '$sub'" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/virsh"
export PATH="$TMP/bin:$PATH"
export STUB_STATE_FILE="$TMP/state"

wait_for() {  # wait_for <seconds> <cmd...>
  local n=$(( $1 * 10 )); shift
  while ! "$@" 2>/dev/null; do n=$(( n - 1 )); [ "$n" -gt 0 ] || return 1; sleep 0.1; done
}

# --- case 1: a real-looking boot, started BEFORE the guest exists -------------
echo "shut off" > "$STUB_STATE_FILE"; export STUB_MODE=boot
bash "$CAP" start "$TMP/boot" fakedom >/dev/null
sleep 1.2
[ "$(ls "$TMP/boot/frames" | wc -l)" -eq 0 ] || fail "grabber captured frames while the guest was shut off"
echo running > "$STUB_STATE_FILE"
wait_for 10 bash -c "[ \$(ls '$TMP/boot/frames' | wc -l) -ge 6 ]" || fail "grabber never captured 6 frames once the guest was running"
sleep 1
echo "shut off" > "$STUB_STATE_FILE"                      # guest powers off by itself
wait_for 10 bash -c "! kill -0 $(cat "$TMP/boot/grabber.pid")" || fail "grabber did not end when the guest powered off"
bash "$CAP" stop "$TMP/boot" >/dev/null                    # stop after self-exit must not error

bash "$CAP" build "$TMP/boot" "$TMP/boot.mp4" --fps 10 >"$TMP/build.out" 2>&1 || { cat "$TMP/build.out"; fail "build failed on a good capture"; }
[ -s "$TMP/boot.mp4" ] || fail "no mp4 from a good capture"
grep -q "domain state when capture began: shut off" "$TMP/boot/summary.txt" || fail "summary lost the initial domain state"
grep -q "NOT an end-to-end boot" "$TMP/boot/summary.txt" && fail "a from-shut-off capture was flagged as not end-to-end"

# Timing: the video must last about as long as the wall-clock capture, not N frames / fps.
span="$(python3 - "$TMP/boot/ticks.log" <<'PY'
import sys
t=[float(l.split()[0]) for l in open(sys.argv[1]) if l.split()[1]=="ok"]
print(f"{t[-1]-t[0]:.2f}")
PY
)"
dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/boot.mp4")"
python3 -c "import sys; s,d=$span,$dur; sys.exit(0 if abs(d-(s+1.0))<0.8 else 1)" \
  || fail "video duration ${dur}s does not match the ${span}s wall-clock capture (+1s hold): timing was lost"
# Mixed frame sizes must have been fitted onto one canvas.
canvas="$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=s=x:p=0 "$TMP/boot.mp4")"
[ "$canvas" = 1024x768 ] || fail "canvas $canvas, expected the largest frame 1024x768"

# --- case 2: capture that began on an ALREADY-RUNNING guest must say so ------
echo running > "$STUB_STATE_FILE"
bash "$CAP" start "$TMP/late" fakedom >/dev/null
sleep 1.5; bash "$CAP" stop "$TMP/late" >/dev/null
bash "$CAP" build "$TMP/late" "$TMP/late.mp4" >/dev/null 2>&1 || fail "build failed on the late capture"
grep -q "NOT an end-to-end boot" "$TMP/late/summary.txt" || fail "a capture begun on a running guest was not flagged"

# --- case 3: the instrument must FAIL on a broken subject ---------------------
echo running > "$STUB_STATE_FILE"; export STUB_MODE=black
bash "$CAP" start "$TMP/black" fakedom >/dev/null
sleep 1.5; bash "$CAP" stop "$TMP/black" >/dev/null
if bash "$CAP" build "$TMP/black" "$TMP/black.mp4" >"$TMP/black.out" 2>&1; then fail "an all-black display was encoded and called good"; fi
[ ! -s "$TMP/black.mp4" ] || fail "a blank capture still produced an mp4"
grep -qiE "single colour|only 1 distinct" "$TMP/black.out" || fail "blank capture failed for the wrong reason: $(cat "$TMP/black.out")"

export STUB_MODE=flicker
bash "$CAP" start "$TMP/flick" fakedom >/dev/null
sleep 2; bash "$CAP" stop "$TMP/flick" >/dev/null
[ "$(ls "$TMP/flick/frames" | wc -l)" -ge 2 ] || fail "flicker stub produced <2 distinct frames; this case would not isolate the blank check"
if bash "$CAP" build "$TMP/flick" "$TMP/flick.mp4" >"$TMP/flick.out" 2>&1; then fail "distinct solid-colour frames (no content) were encoded and called good"; fi
grep -q "single colour" "$TMP/flick.out" || fail "flicker capture failed for the wrong reason: $(cat "$TMP/flick.out")"

export STUB_MODE=still
bash "$CAP" start "$TMP/still" fakedom >/dev/null
sleep 1.5; bash "$CAP" stop "$TMP/still" >/dev/null
if bash "$CAP" build "$TMP/still" "$TMP/still.mp4" >"$TMP/still.out" 2>&1; then fail "a frozen display was accepted as a boot sequence"; fi
grep -q "only 1 distinct" "$TMP/still.out" || fail "frozen capture failed for the wrong reason: $(cat "$TMP/still.out")"

# --- case 3b: a live guest must NOT be read as "powered off" by a pipe race ----
# Regression: a real capture ended itself mid-demo because `domstate | head -1 || echo gone`
# yielded "running\ngone". The race only ends a capture that has ALREADY started (before
# that, an odd state just means "keep waiting"), so: get the grabber running on clean
# output first, THEN make virsh keep writing after line 1. (A first version of this test
# turned noise on from the start and passed against the buggy code -- mutation-testing
# caught it.)
echo running > "$STUB_STATE_FILE"; export STUB_MODE=boot STUB_NOISY_FILE="$TMP/noisy.flag"
bash "$CAP" start "$TMP/noisy" fakedom >/dev/null
wait_for 10 bash -c "[ \$(ls '$TMP/noisy/frames' | wc -l) -ge 2 ]" || fail "noisy case: grabber never started capturing"
touch "$STUB_NOISY_FILE"
before="$(ls "$TMP/noisy/frames" | wc -l)"
sleep 3
kill -0 "$(cat "$TMP/noisy/grabber.pid")" 2>/dev/null || fail "grabber ended itself on a RUNNING guest (domstate pipe race): $(tail -2 "$TMP/noisy/grabber.log")"
grep -q "ending capture" "$TMP/noisy/grabber.log" && fail "grabber logged a bogus end-of-guest: $(tail -2 "$TMP/noisy/grabber.log")"
[ "$(ls "$TMP/noisy/frames" | wc -l)" -gt "$before" ] || fail "grabber stopped capturing once virsh got noisy"
bash "$CAP" stop "$TMP/noisy" >/dev/null
rm -f "$STUB_NOISY_FILE"

# --- case 3c: resume after a dead grabber records the gap and the video CUTS ---
echo running > "$STUB_STATE_FILE"
bash "$CAP" start "$TMP/res" fakedom >/dev/null
sleep 2; bash "$CAP" stop "$TMP/res" >/dev/null
sleep 3                                                    # ~3s of footage nobody recorded
bash "$CAP" start "$TMP/res" fakedom --resume >/dev/null
sleep 2; bash "$CAP" stop "$TMP/res" >/dev/null
bash "$CAP" build "$TMP/res" "$TMP/res.mp4" --fps 10 >"$TMP/res.out" 2>&1 || { cat "$TMP/res.out"; fail "build failed on a resumed take"; }
grep -q "GAP(S)" "$TMP/res/summary.txt" || fail "summary does not mention the gap"
[ -z "$(ls "$TMP/res/frames" | sort | uniq -d)" ] || fail "resume reused a frame number"
wall="$(python3 -c "
import sys
t=[float(l.split()[0]) for l in open('$TMP/res/ticks.log') if l.split()[1]=='ok']
print(f'{t[-1]-t[0]:.2f}')")"
rdur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/res.mp4")"
# wall includes the ~3s hole; the video drops it but adds ~1.5s of end-holds, so it must be
# >1s shorter than wall (a frozen gap lands ABOVE wall: 9.3s vs 8.0s when mutated).
python3 -c "import sys; sys.exit(0 if $rdur < $wall - 1.0 else 1)" || fail "video ${rdur}s vs wall ${wall}s: the gap was frozen into the video instead of cut"

# --- case 3d: LONG still holds must keep their real duration in the video -----
# Found on the first real QB2 boot: frames held 27-32s (GRUB, login screen) came out of
# ffmpeg's concat demuxer as 117s / 71s / 73s / 98s depending on encode flags, for a true
# 97.6s capture. The earlier cases only held frames for fractions of a second, so they could
# not see it. This builds a take directly (no waiting) with long holds + mixed frame sizes.
mkdir -p "$TMP/long/frames"
python3 - "$TMP/long" <<'PY'
import sys
from PIL import Image, ImageDraw
d = sys.argv[1]
for i, (w, h) in enumerate([(720, 400), (1024, 768), (640, 480)], 1):
    im = Image.new("RGB", (w, h), (0, 0, 0)); dr = ImageDraw.Draw(im)
    dr.rectangle([10, 10, 10 + 40 * i, 60], fill=(200, 200, 200)); dr.text((20, 80), f"screen {i}", fill=(255, 255, 255))
    im.save(f"{d}/frames/f_{i:06d}.img", "PPM")
open(f"{d}/ticks.log", "w").write("""1000.0 ok h1 1
1000.5 ok h1 0
1020.0 ok h2 1
1045.0 ok h3 1
1060.0 ok h3 0
""")
open(f"{d}/meta.env", "w").write("DOMAIN=x\nINITIAL_STATE=shut off\nGRAB_STARTED_AT=1000.0\n")
PY
bash "$CAP" build "$TMP/long" "$TMP/long.mp4" --fps 30 >"$TMP/long.out" 2>&1 || { cat "$TMP/long.out"; fail "build failed on the long-hold take"; }
ldur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/long.mp4")"
python3 -c "import sys; sys.exit(0 if abs($ldur - 61.0) < 1.0 else 1)" \
  || fail "long-hold video is ${ldur}s, capture was 60s (+1s end hold): ffmpeg mangled the still-frame durations"

# --- case 4: never mix two takes / never start on a nonexistent domain --------
if bash "$CAP" start "$TMP/boot" fakedom >/dev/null 2>&1; then fail "start overwrote a directory that already holds frames"; fi

echo "qemu_capture tests passed"
