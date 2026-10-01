# Recording a GUI app (not a terminal)

`lib/screen_capture.sh` records graphical demos — a GTK/Qt/GL kiosk whose whole point is
what it draws. The rest of tt-demo-maker drives tmux and asciinema, which only ever see a
terminal.

```bash
lib/screen_capture.sh detect                 # what works on this machine, and why
lib/screen_capture.sh record 120 out.mp4     # OBS/PipeWire, 60fps
lib/screen_capture.sh burst  120 frames/     # Spectacle stills, any compositor
lib/screen_capture.sh verify out.mp4         # fails loudly on a black capture
```

## What actually works, measured

Findings from a KWin/Wayland box (Ubuntu 24.04). None of this is guessable, and each wrong
turn costs an hour:

| tool | result |
|---|---|
| `ffmpeg -f x11grab` | **records pure black.** Exit 0, real `.mp4`, one unique colour per frame |
| `wf-recorder` | refuses: *"compositor doesn't support wlr-screencopy-unstable-v1"* — wlroots only |
| `grim` | same wlroots assumption; unusable on KWin |
| `spectacle` | works, **stills only** at 23.08.5. Video landed in 24.02, which Ubuntu 24.04 does not package — `apt` offers 23.08.5 and nothing newer. Sustains **~5.9 fps** |
| **OBS + PipeWire** | **the right answer**: 1920×1080 @ 60 fps, hardware encode |

## The OBS caveat that will cost you an hour

OBS needs the xdg **ScreenCast portal** to grant a session. A saved restore token is *not*
sufficient from a detached or non-interactive process: the PipeWire stream goes
`paused` → `unconnected`, OBS writes a perfectly valid file, and every frame is black.

So the first run in a new login session must have the screen-share dialog approved **once,
interactively**. After that it is automatic within that session. `record` deliberately does
**not** use `setsid`, because detaching loses the session association the portal keys on.

## Why every backend verifies itself

Three of the five options above fail by producing a *plausible file full of black*. That is
the worst failure mode available: it looks like a working recording until someone plays it,
which is usually after you have shipped it.

So `verify` runs after every capture and refuses to report success on a blank capture, and
it is tested in *both* directions — real content passes, synthetic black is rejected —
because a verifier that cannot fail is exactly the trap it exists to prevent:

```bash
bash lib/tests/screen_capture_test.sh
```

That test synthesises its fixtures with ffmpeg's lavfi sources, so it needs no display.

Three corrections, all paid for in lost footage or lost trust:

**Sample the whole file, not one frame.** A recorder's first second is routinely black while
it starts and the compositor hands over the first buffer. Judging the file at t=1s reported a
perfectly good 136 s 1080p60 capture as a BLANK CAPTURE — on the first video this verifier was
ever pointed at. It now samples five points across the duration (six frames for a stills
burst) and fails only if *every* sample is a single colour.

**Ask about the world, not only the pixels.** A locked session records happily, and a
wallpaper has thousands of colours, so it sails through any is-it-black test. That cost a
161-second take of a mountain range at 2:23 am with the application running the whole time
underneath. `verify` now refuses outright when `loginctl` reports `LockedHint=yes`, and
`record` wraps the recorder in `systemd-inhibit --what=idle:sleep` so the lock cannot arrive
part-way through a long unattended take. No amount of frame sampling would have caught this
one — it is not a question about the frames.

**"Cannot judge" is not "fine."** The frame check needs Pillow, and when the import failed it
returned non-zero — which the caller read as *not blank*. On a box without Pillow the
verifier therefore waved every capture through, all-black ones included, while still printing
its reassuring OK line. It now distinguishes three outcomes (blank / has content / cannot
judge) and dies on the third rather than vouching for footage it never looked at.

## Requirements

`obs` (video) or `spectacle` (stills), `ffmpeg`/`ffprobe`, and `python3` with Pillow for the
blank-frame check. `systemd-inhibit` and `loginctl` are used when present.

`tt-demo doctor` reports all of these in a separate optional section and does **not** fail on
them — most projects demo a terminal and will never record a GUI window. Use
`tt-demo doctor --require-screen` when you do mean to, and `screen_capture.sh detect` for
which backend actually works on this box.

## Headless verification, no live session at all

Everything above is for recording (or photographing) the **real, live desktop session** for
a demo. A different need comes up just as often: checking that a GTK/Qt/GL app's *layout*
looks right — at a specific window size, or across several — without a human's actual
desktop involved at all. That matters for two reasons the live-session tools above don't
solve: an agent driving a real desktop risks capturing whatever else is open on it (a
`spectacle -f` full-screen grab came back with the person's own browser tabs, not the app
under test), and testing "does this look right at 1024×768 vs 1920×1080" needs a screen you
can actually set to those sizes on demand, which a real monitor isn't.

**`weston --backend=headless`** solves both: a real Wayland compositor with no display
attached, so a Wayland-native app (a plain X11 `DISPLAY` doesn't reach it, and vice versa)
renders into an in-memory surface you can screenshot on request, at whatever resolution you
ask for, with zero risk of ever showing you someone's browser tabs.

```bash
sudo apt-get install -y weston      # pulls in libweston + (unused here) RDP/VNC backend deps

# One compositor, sized however you want to test:
weston --debug --backend=headless --renderer=pixman \
  --width=1024 --height=768 --socket=verify-1024 --idle-time=0 &

# Point the app being tested at it instead of a real display:
WAYLAND_DISPLAY=verify-1024 unset DISPLAY  # or just don't export DISPLAY at all
my-gtk-app &

# Screenshot on demand:
WAYLAND_DISPLAY=verify-1024 weston-screenshooter   # writes ./wayland-screenshot-<timestamp>.png
```

Two flags are load-bearing and neither is optional, measured the hard way:

- **`--renderer=pixman`.** Without it weston auto-selects and silently falls back to a
  **no-op** renderer under `--backend=headless` with no GPU attached (visible only as
  `Compositor capabilities: ...` differing in the log, nothing louder) — `weston-screenshooter`
  then dies with `Assertion 'width > 0' failed`, because the no-op renderer keeps no real
  framebuffer to read from. Pixman is the CPU software renderer; it always works headless.
- **`--debug`.** Without it, `weston-screenshooter` connects fine but every capture attempt
  answers `Output capture error: unauthorized` — the screenshooter protocol is gated behind
  weston's debug extension. (A detour through `weston.ini`'s `[autolaunch]` section, on the
  theory that only compositor-spawned clients are "trusted," was unnecessary once this was
  found — `--debug` alone is sufficient, no config file needed.)

Multiple compositor instances (different `--socket`/`--width`/`--height`) can run side by
side, which is the whole point for a responsive-layout check: launch the same app against
`verify-1024`, `verify-1366`, `verify-1920`, screenshot each, compare.

This is a genuinely different tool from the OBS/Spectacle path above, not a replacement for
it — it never touches a real login session or its screen, so it cannot record what a person
is actually looking at, and it does not attempt GPU-accelerated rendering (software Pixman
only) so it is not the tool for a smooth 60fps capture of the real thing. Use it for "does
this layout hold up at this size," and OBS+PipeWire for "here is a video of the real booth."

## A worked example

`tt-bio-demo` records its protein-folding booth this way. Its
`scripts/record-demo-video.sh` keeps the order of operations this file's `record` uses — OBS
started *first* (so its startup dialog lands on an empty desktop rather than stealing focus
from the demo), under `systemd-inhibit`, never `setsid` — then brings the app up fullscreen
over the top and trims the dirty head by offset afterwards. It adds one app-specific check
this generic backend can't: a screenshot precheck that refuses to continue if desktop chrome
is still visible. Its `recordings/README.md` then runs `screen_capture.sh verify` on every
recut before it ships.
