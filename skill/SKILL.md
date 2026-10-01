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

## Recording a QEMU/libvirt guest booting (the QB2 image)
The user may say: *"capture the QB2 fresh image booting on qemu end to end; I'll drive and tell
you when to stop."* That is `lib/qb2_capture.sh`. It polls the guest's own framebuffer
(`virsh screenshot`) from the very first firmware frame and builds an mp4 with real timing — no
OBS, no portal, no dependence on a viewer window or on the host session being unlocked.

1. **Confirm the one destructive choice.** `begin --fresh` overwrites the live disk
   (~163 GB) with the pristine snapshot; `--as-is` boots whatever is there. "Fresh image"
   means `--fresh`. The default pristine is the big one (tt-installer done, Qwen3-32B cache,
   ~130 GB, slow to restore); `--pristine tt-qb2-one-accelerator-pristine-gdm-only.qcow2` is
   the small one. If the user didn't say which, ask — it's minutes vs. seconds.
2. `lib/qb2_capture.sh begin --fresh [--pristine FILE]` — restores the disk, starts the grabber
   (it waits for frame 0), then runs `sudo qb2-vm-up.sh --open-remote`, which takes the **gozer
   lease** (queues if the chips are busy; the grabber just keeps waiting) and opens
   remote-viewer. It returns immediately. Tell the user it's recording and that they drive.
   Needs passwordless `sudo`; if not, have the user run `! sudo -v` first.
3. **The user drives.** Do not touch the guest. `lib/qb2_capture.sh status` shows live frame
   counts if they ask.
4. When they say stop: `lib/qb2_capture.sh end [--down]`. It stops the grabber, verifies the
   frames, builds `boot.mp4`, and verifies the mp4 itself. `--down` powers off and releases the
   lease; without it the guest keeps running and **still holds the chips** — say so, and ask
   before leaving it that way.
5. Read `summary.txt` in the take dir to the user *before* calling it good, and look at the
   result (`tt-demo`-style: extract a few frames with ffmpeg and Read them). Two things must be
   reported honestly: the achieved screenshot rate (a few fps — fine for boot text, choppy for
   animation) and that **the mouse pointer is not in the footage** (SPICE draws it
   client-side). If the demo is pointer-driven, say so and offer `screen_capture.sh` on the
   viewer window instead. `summary.txt` also flags a take that began on an already-running
   guest as *not* end-to-end.

Take dirs land in `demo/assets/qb2-boot-<timestamp>/` (gitignored). Primitive for any libvirt
domain: `lib/qemu_capture.sh {start|stop|status|build|verify}`. Not exercised against the real
QB2 domain by `lib/tests/qemu_capture_test.sh` (stub `virsh`) — the first real run's `verify`
is the check that `virsh screenshot` returns good frames there.

## Notes
- Non-invasive by default: prefer `--backend hybrid`/`--host` in scene commands.
- A local Qwen (`--narrate local`) can write narration when you are not in the loop.
