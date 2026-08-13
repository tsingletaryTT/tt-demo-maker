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

So `verify` runs after every capture and refuses to report success on a blank frame. It is
tested in both directions — real content passes, synthetic black is rejected — because a
verifier that cannot fail is exactly the trap it exists to prevent.
