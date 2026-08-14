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

## A worked example

`tt-bio-demo` records its protein-folding booth this way. Its
`scripts/record-demo-video.sh` keeps the order of operations this file's `record` uses — OBS
started *first* (so its startup dialog lands on an empty desktop rather than stealing focus
from the demo), under `systemd-inhibit`, never `setsid` — then brings the app up fullscreen
over the top and trims the dirty head by offset afterwards. It adds one app-specific check
this generic backend can't: a screenshot precheck that refuses to continue if desktop chrome
is still visible. Its `recordings/README.md` then runs `screen_capture.sh verify` on every
recut before it ships.
