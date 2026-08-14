---
name: tt-demo
description: Author demo recordings + a draft post from any project. Use when the user wants to record a terminal/TUI demo, capture "directive → reaction" footage, or assemble a demo post. Drives the `tt-demo` CLI.
---

# /tt-demo — record demos + assemble a draft post

You turn a natural-language demo request into `demo/demos.yaml`, then drive `tt-demo`.

## Steps
1. `tt-demo doctor` — confirm tools; report anything missing.
2. If `demo/demos.yaml` is absent, `tt-demo init`, then edit it to match the request.
   Author scenes per `manifest-schema.md`. Prefer declarative scenes; use `raw_tape`/`raw_script`
   only for tricky pixel-stable shots. For an actual GUI window, see the screen-capture
   section below — the manifest has no scene shape for one.
3. `tt-demo record --dry-run` — show the plan; fix validation errors.
4. `tt-demo rehearse <id>` — for hardware-reactive scenes, prove the directive moves
   telemetry BEFORE recording (`--require-reaction` to hard-fail). Skip for host-only scenes.
5. `tt-demo record <ids|all>` — capture. `tt-demo compress demo/assets/<id>.cast` (writes
   `<id>.min.cast`, which render prefers) + `tt-demo render <id> --gif|--mp4` as needed.
6. `tt-demo verify <id>` — contact-sheet PNG; Read it to confirm the footage shows what
   the caption claims before shipping it.
7. `tt-demo publish <ids> --readme README.md` — copy artifacts to a committed dir and
   splice the gallery between `<!-- tt-demo:gallery:begin/end -->` markers.
8. `tt-demo post --narrate claude` — assemble `demo/POST.draft.md`; you write the narration paragraphs where marked.

## Recording a GUI app instead of a terminal
The steps above capture terminals (tmux + asciinema/VHS). If the thing to demo is a
graphical app — a GTK/Qt/GL window whose whole point is what it draws — none of that sees it.
Use `lib/screen_capture.sh` directly (it is not a `tt-demo` subcommand, and has no scene shape
in the manifest):

1. `tt-demo doctor --require-screen` then `lib/screen_capture.sh detect` — the first fails
   if there is no usable backend (plain `doctor` only reports them, since most projects
   demo a terminal); the second says which backend works on this box and why.
2. `lib/screen_capture.sh record <seconds> out.mp4` (OBS/PipeWire, 1080p60) or
   `burst <seconds> frames/` (Spectacle stills, any compositor).
3. `lib/screen_capture.sh verify out.mp4` — always, before showing or shipping it.

Three things that will otherwise waste an hour or a whole take:
- **Never `ffmpeg -f x11grab` on Wayland.** It exits 0 and records pure black.
- **OBS needs the xdg ScreenCast portal granted interactively once per login session.** A
  saved restore token does not survive a detached/non-interactive launch — the stream goes
  paused → unconnected and the file is black. Never `setsid` the recorder.
- **Unlock the session first.** A lock screen records fine and passes every not-black check;
  `verify` refuses when `loginctl` reports it, and `record` holds it off with
  `systemd-inhibit --what=idle:sleep`.

Background and the measured backend comparison: `docs/screen-capture.md`.

## Notes
- Non-invasive by default: prefer `--backend hybrid`/`--host` in scene commands.
- A local Qwen (`--narrate local`) can write narration when you are not in the loop.
