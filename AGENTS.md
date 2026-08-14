# tt-demo-maker — Development Log

## Project Overview

`tt-demo-maker` is a reusable, project-agnostic toolkit for authoring **demo recordings and
draft posts** from inside any project. It turns a natural-language ask ("record me a
cold-model-load causation clip in arcade mode") into recorded terminal footage
(GIF/MP4/asciicast) **and** a first-draft Markdown post pairing each *directive* with the
*reaction* it caused.

Three layers: `skill/` (the `/tt-demo` Claude skill — the "from any project" front door),
`bin/` (the Rust `tt-demo` orchestrator — manifest parse/validate, scene compilation, capture
plan), `lib/` (bash capture primitives — tmux/asciinema/vhs/ffmpeg/agg, kept in bash because
that's genuinely the better tool for the process ballet).

**Design spec**: `docs/superpowers/specs/2026-07-18-tt-demo-maker-design.md` (v1, approved).
**Plan**: `docs/superpowers/plans/2026-07-18-tt-demo-maker.md`.
**Task ledger**: `.superpowers/sdd/progress.md` + `.superpowers/sdd/task-N-{brief,report}.md`.

It exists because the same recording machinery was reinvented per-project: tt-toplike
(`record-casts.sh`), tt-forge-compiletron (`record_demo.sh`, `render_demo_video.sh`,
`compress_cast.py`), tt-animatediff (`record_demo.sh`, `bringup.tape`), tt-local-generator
(`vhs-defaults.tape`, `demo-quickstart.tape`, `pipeline_engine.py`/`server_manager.py`), and
tt-zork1 (`record-all.sh`). This centralizes that machinery so any project gets it for free.

---

## What Happened?

### Spec-driven development (SDD), July 18 2026

Taylor asked for a reusable demo-recording toolkit generalized from the recording scripts
scattered across TT projects (tt-toplike, tt-forge-compiletron, tt-animatediff,
tt-local-generator, tt-zork1). The design spec (`docs/superpowers/specs/`) was written and
approved first, then broken into an 11-task implementation plan
(`docs/superpowers/plans/`), executed task-by-task on branch `feat/tt-demo-v1` with a
controller/subagent review loop per task (see `.superpowers/sdd/progress.md` for the full
ledger and every reviewer finding).

**Key architectural decisions** (from the spec, §2–§3):
- **Bash for capture, Rust for orchestration.** Escaping tmux/ffmpeg/Xvfb pipelines through
  Rust `Command` is a step backward; bash is genuinely better at that process ballet. Rust
  (`clap` + `serde`/`serde_yml` + `minijinja` + `regex` + `which` + `ureq`) owns manifest
  parsing/validation, scene compilation (scene → VHS tape / asciinema driver via minijinja
  templates), and orchestration (server-switch minimization, dry-run planning).
  `serde_yaml` is archived upstream — the maintained fork `serde_yml` is used instead.
- **YAML manifest, not a DSL.** `demo/demos.yaml` is deliberately small and bounded so a
  local Qwen (not just Claude) can author it reliably from natural language. Two escape
  hatches (`raw_tape`/`raw_script`) cover anything too tricky to describe declaratively (GUI
  capture, pixel-stable hero clips).
- **Two-pane causation capture** (`layout: split`) is the marquee feature: one tmux window,
  directive pane (left) + viz pane (right), recorded as a single asciicast so the *ask* and
  its *reaction* share one timeline with real timing — not two clips stitched together.
  `engine: auto` picks asciinema for anything needing live real timing (split, injected
  `keys`, `raw_script`) and VHS for deterministic single-terminal sequences (repeatable,
  themed, pixel-stable) — see spec §5.
- **Tiered readiness** (`ready:` — `log` → `health_url`/`ready_field` → `runner_key`
  identity check, spec §6.1) follows the tt-toplike house rule: *active ≠ matched; cheap
  signal first, authoritative probe off the hot path.* A scene never records against the
  *wrong* model warm on a shared port.
- **`--dry-run` is the CI backbone.** `tt-demo record [ids] --dry-run` validates + compiles
  every scene and prints the ordered capture/switch plan, touching zero hardware/tmux/docker
  — mirrors `pipeline_engine`'s `dry_run` in tt-local-generator. It's also the fast
  manifest-authoring feedback loop for humans and the local-Qwen skill path alike.

### Task 11: skill, reference example, install, docs (this task)

Added the user-facing layer with no Rust changes:
- `examples/demos.yaml` — the tt-toplike reference manifest (`qa-short`, `cold-load`,
  `reset-lightshow`), built entirely on `tt-toplike --host` / `yes`/`sleep`/`kill` so it's
  hardware-free and CI-runnable. Validated end-to-end via `tt-demo record --dry-run`
  (`TT_DEMO_HOME=<repo> tt-demo record --dry-run` from a scratch `demo/` dir copying the
  example in) — printed the three record steps in manifest order and ended with
  `[dry-run] N step(s); no hardware touched`. No changes to the example were needed; it
  validated as given.
- `skill/SKILL.md` — the `/tt-demo` front door: doctor → init/edit → dry-run → record →
  compress/render → post, with narration written by the invoking agent (Claude) or a local
  model.
- `skill/manifest-schema.md` — full field reference for `demo/demos.yaml` (top-level,
  `defaults.*`, `servers.*`, scene fields, pane fields, the `ready:` tier ladder, the
  `engine: auto` rule, and the `raw_tape`/`raw_script` escape hatches), sourced from spec §4
  cross-checked against `bin/src/manifest.rs` so field names/types match the actual parser
  exactly.
- `install.sh` — builds the release binary, symlinks `tt-demo` into `~/.local/bin` and
  `skill/` into `~/.claude/skills/tt-demo`, `chmod +x`'s `lib/*.sh`. `bash -n` clean.
  (`shellcheck` isn't installed in this environment — per the task's environment note,
  `bash -n` is the syntax gate here; run `shellcheck install.sh` separately wherever it's
  available before a release.)
- `README.md` — quickstart (install → init → edit → dry-run → record → compress/render →
  post) plus a pointer at the skill and the reference example.
- `AGENTS.md` — this file.

**Env note carried forward from the ledger**: `shellcheck` is not installed on this
machine; `bash -n` is the syntax gate for shell scripts here (mirrors the note already
recorded for Task 8).

---

*Task 11 status: complete. See `.superpowers/sdd/task-11-report.md` for the full
step-by-step record (dry-run output, cleanup confirmation, commit SHA).*

---

### Task 13: final-review MUST-FIXES — split.sh pane fix + real CLI capture wiring

A whole-branch review of all 12 tasks (17/17 tests passing at the time) returned MERGE
AFTER MUST-FIXES. This task closes those out in one commit set:

- **`lib/split.sh` panes/ratio were inverted.** tmux 3.4's `split-window -h` always puts
  the *new* pane on the right of the pane it splits from. The old code ran the viz
  (`right_cmd`) in the initial session pane (→ visually left) and split the directive
  (`left_cmd`) in with plain `-h` (→ visually right, at `100-RATIO`% wide) — the inverse of
  the documented contract. Fixed by keeping `right_cmd` as the initial pane and splitting
  `left_cmd` in with `-h -b -l "${RATIO}%"` (`-b` = insert the new pane *before*/left of the
  target). Verified manually with `tmux list-panes`/`capture-pane` mid-recording: the left
  pane (`left=0`, width=RATIO%) now genuinely runs `left_cmd`, the right pane runs
  `right_cmd`.
- **Real capture wired into `bin/src/record.rs`** (the core value of this whole tool — up
  to now `record` only ever wrote a `[dry-run]` placeholder, even without `--dry-run`).
  `Step::Switch` now starts a scene's server via `lib/serve.sh`, capturing its PID and a
  logfile (`demo/assets/.<server>.log`), then gates on readiness: `ready::poll_http` for
  `health_url`, or a new `wait_for_log` (log-file-backed twin of `ready::poll_http`'s loop
  shape) for a bare `ready.log` pattern; `ready.timeout` (e.g. `"360s"`) parses to a
  `Duration`, defaulting to 300s. Stopping the *previous* server and any board reset is
  explicitly left as `// TODO(v1.1)` — switching never runs `tt-smi -r`. `Step::Record` now
  computes `cols`/`rows`/`ratio`/`dur` from the manifest (with the same defaults
  `compile.rs` uses) and shells directly to `lib/split.sh` (two-pane scenes) or
  `lib/tmux_capture.sh` (single-pane, wrapped in a `cmd & sleep DUR; kill; wait` so a
  non-exiting viz still gets stopped cleanly) against the scene's **raw** `left`/`right`
  commands — never the compiled tape/driver text, which stays a v1.1 execution path (see
  `compile.rs`'s new TODO on its shell-quoting closure). `--dry-run` behavior is untouched.
  **Bug found while testing this wiring**: `compile::compile_scene` unconditionally
  requires a `right` pane, but raw-hatch scenes (`raw_tape`/`raw_script`) never have one by
  construction — so raw scenes crashed `tt-demo record` outright, in dry-run included, on
  every branch before this task. Fixed by checking `Scene::is_raw()` *before* ever calling
  `compile_scene`, so raw scenes print `[raw]` + a "not yet CLI-captured (v1.1)" note and
  skip cleanly instead of erroring, matching the manifest's own contract that raw scenes
  are a valid (if less-automated) shape.
- **`tests/e2e_golden.sh`** gained two new hardware-free scenes (`cli-single`, `cli-split`)
  and a section that runs `tt-demo record cli-single` / `tt-demo record cli-split`
  (non-dry-run, through the real CLI, not the lib/ scripts directly like the existing
  marquee check) and asserts the resulting `.cast` files contain their markers
  (`CLI_SINGLE`; `CLI_LEFT` + `CLI_RIGHT`). Ran 3 consecutive times, 3/3 pass, no leftover
  tmux sessions or processes after any run.
- **Hygiene**: `compile.rs`'s dead `width` expression
  (`split_ratio.map(|_| ()).and(None).unwrap_or(...)`, always evaluated to the same value
  as a bare `unwrap_or`) simplified to `m.defaults.cols.unwrap_or(200)`; a TODO added at the
  asciinema-driver's `Debug`-repr shell-quoting closure. `cargo build` warnings driven to
  zero: `Compiled.text`, `Defaults.outputs`/`padding`, and `ServerDef.stop` are each
  `#[allow(dead_code)]` with a one-line reason (all reserved for v1.1 paths this task
  intentionally doesn't wire up yet).
- **Docs**: README gained a "v1 limitations / v1.1" section listing exactly what's
  deferred (raw-hatch CLI capture, compiled-tape/driver execution + its shell-quoting gap,
  theme-matched GIF palette, unexercised MP4 path, server-stop/board-reset on switch).

Full step-by-step record (split.sh before/after verification, record.rs manual smoke
tests including the raw-scene bug, golden 3-run evidence, warning count):
`.superpowers/sdd/task-13-report.md`.

---

*Task 13 status: complete.*

---

### v1.1: rehearse / verify / publish + render tuning, August 5 2026

Taylor asked for real-hardware demo footage embedded in the README. Recording it (three
scenes on the QuietBox's 4× P300C: ttnn matmul bursts on device 0 + tt-toplike hybrid
visualizations) surfaced five capability gaps — every place the paved path had to be left
manually. Taylor then asked to develop all five as v1.1
(plan: `docs/superpowers/plans/2026-08-05-tt-demo-v1.1.md`, branch `feat/tt-demo-v1.1`,
version 0.1.0 → 0.2.0):

- **`tt-demo rehearse <id>`** (the big one): run a scene's directive while sampling
  `tt-smi -s`, report per-device idle→peak power/aiclk deltas, `--require-reaction` to
  hard-fail quiet boards. Born from the trap where the "LLM server" on :8001 turned out to
  be a CPU fallback (`tt-local-generator prompt_server.py`) — inference moved nothing;
  footage would have shown a dead board. Golden-tested with a stub `tt-smi` whose telemetry
  flips when the directive's flag file appears (proves the sample loop overlaps the run).
- **`defaults.render` + theme-matched agg palettes**: `render: { fps_cap, font_size,
  speed }` in the manifest → `AGG_*` env vars → `lib/render.sh`; `themes/<theme>.agg`
  (tt-brand, dracula) supplies `agg --theme`. Stock agg defaults had produced 16–25 MB GIFs;
  the hand-tuned flags (fps_cap 10, font_size 12, speed 1.25) brought scenes under ~6 MB
  and are now dogfooded in this repo's own `demo/demos.yaml`.
- **`tt-demo compress` writes `<id>.min.cast` by default** (what `render_target()` already
  preferred); `--stdout` keeps the old pipe behavior. Previously it dumped a 16 MB cast
  into the terminal when `--out` was forgotten.
- **`tt-demo verify <id>`**: ffprobe frame count → ffmpeg select+tile contact-sheet PNG
  (`<id>.sheet.png`) so an agent can Read the footage instead of playing it.
- **`tt-demo publish [ids] --dir media --readme README.md`**: copy artifacts out of
  gitignored `demo/assets/` into a committed dir + emit/splice a markdown gallery between
  `<!-- tt-demo:gallery:begin/end -->` markers (repeatable — markers survive).

All five follow the house split (Rust resolves/validates/orchestrates, bash talks to
agg/ffmpeg). 32 unit tests + extended `tests/e2e_golden.sh` (compress default, tuned+themed
render, verify PNG magic bytes, publish splice idempotence, rehearse reaction + no-reaction
paths) — all hardware-free. Raw-hatch capture, compiled-driver execution, MP4 coverage, and
server-stop/board-reset remain deferred (see below).

### Screen capture: recording a GUI, August 13–14 2026

Taylor needed demo footage of `tt-bio-demo`'s protein-folding booth — a fullscreen GTK/GL
kiosk. Every backend in this toolkit drives tmux and asciinema, which only ever see a
terminal, so none of them can photograph it at all. `lib/screen_capture.sh` +
`docs/screen-capture.md` are the answer (bash-only; deliberately *not* a `tt-demo`
subcommand yet — see the roadmap below).

**The value here is the measurements, which are not guessable**, and each wrong turn cost an
hour. On this KWin/Wayland box (Ubuntu 24.04): `ffmpeg -f x11grab` records **pure black at
exit 0** — a real `.mp4`, one unique colour per frame; `wf-recorder` and `grim` are
wlroots-only and refuse outright on KWin; `spectacle` works but is **stills-only** at 23.08.5
(video landed in 24.02, which Ubuntu 24.04 does not package) and sustains ~5.9 fps;
**OBS + PipeWire** is the right answer at 1920×1080 @ 60 fps with hardware encode. The caveat
that eats the hour: OBS needs the xdg **ScreenCast portal** to grant a session, and a saved
restore token is *not* sufficient from a detached or non-interactive process — the stream goes
`paused` → `unconnected` and every frame is black. Hence `record` deliberately does not
`setsid`.

Three of those five fail by producing **a plausible file full of black**, the worst failure
available: it looks like a working recording until someone plays it, which is usually after
you shipped it. So every backend verifies itself before reporting success. Two follow-up
fixes, each paid for in lost footage, and both the same lesson one level up — *it is not
enough for a verifier to fail on the failure you imagined*:

- **It sampled one frame at t=1s.** A recorder's first second is routinely black while it
  starts and the compositor hands over the first buffer, so the verifier called a perfectly
  good 136 s 1080p60 capture a BLANK CAPTURE — on the first video it was ever pointed at.
  Now samples five points across the duration (six frames for a stills burst) and fails only
  if *every* sample is blank.
- **A lock screen passed every check we had.** 161 seconds of desktop wallpaper recorded at
  2:23 am and verified as good, because the only question being asked was "is it black?" and
  a mountain range at night emphatically is not. This is a question about the *world*, not
  the pixels, which is why no amount of frame sampling would have caught it: `verify` now
  refuses when `loginctl` reports `LockedHint=yes`, and `record` wraps the recorder in
  `systemd-inhibit --what=idle:sleep` so the lock cannot arrive mid-take.

**Downstream use**: `tt-bio-demo/scripts/record-demo-video.sh` keeps this order of operations
(OBS first under `systemd-inhibit`, app raised fullscreen over its startup dialog, dirty head
trimmed by offset) and adds an app-specific screenshot precheck for leftover desktop chrome;
its `recordings/README.md` runs `screen_capture.sh verify` on every recut before shipping.

**Docs + coverage pass, August 14 2026** (version 0.2.0 → 0.2.1). Taylor asked that the
README and the other instruction surfaces catch up with screen capture, then — reading the
gaps that pass surfaced — that the tests and `doctor` catch up too.

Docs: the GUI section + requirements + layout + roadmap entries in `README.md`, a
screen-capture section in `skill/SKILL.md`, an explicit "neither escape hatch records a GUI
window" note in `skill/manifest-schema.md` (where `raw_tape` had been documented as being
*for* GUI capture — it never could be; VHS records a terminal), and the two verifier fixes
plus the `tt-bio-demo` worked example in `docs/screen-capture.md`.

Writing them turned up that `docs/screen-capture.md`'s claim that the verifier "is tested in
both directions" was not true of the repo — that testing had been done by hand and never
committed. Closing that honestly is what produced the rest:

- **`lib/tests/screen_capture_test.sh`** — the claim, made real. Fixtures are synthesised
  with ffmpeg's lavfi sources so it needs no display: real content passes, synthetic black is
  rejected *as a blank capture* (not merely rejected), a black first second does not condemn
  an otherwise good take (asserted as 4/5 samples, so it stays a test of the tolerance rather
  than quietly becoming a second happy-path check), stills bursts verify both ways, and a box
  that cannot judge the frames refuses. Skips itself when ffmpeg or Pillow is absent, or when
  the session is locked — that last one would otherwise mask every assertion, since `verify`
  correctly refuses before it ever looks at a frame.
- **A real bug, found by writing that last case.** `_frame_is_blank` exited 2 for "no Pillow",
  the caller treated any non-zero as *not blank*, and so a box without Pillow waved every
  capture through — all-black ones included — while still printing its reassuring OK line.
  The verifier had a mode in which it could not fail, which is the exact trap the file's
  header says it exists to prevent. Now three-valued (blank / content / cannot judge), fatal
  on the third. The tally also moved out of a `$(...)` substitution: `die` inside one only
  kills the subshell, so the scary message printed and the footage passed anyway.
- **`tt-demo doctor` checks `obs`/`spectacle`/Pillow** in a separate optional section —
  reported and recommended, never fatal, because most projects demo a terminal and putting
  these in `REQUIRED` would fail `doctor` on every machine that will never record a GUI. A
  unit test guards exactly that regression. `--require-screen` opts *in* to hard failure for
  a scripted preflight that does mean to record one. 34 Rust tests pass (32 + 2 new).

---

## v1 Limitations / v1.1 Roadmap

This section documents known limitations and features still deferred after v1.1,
kept in sync with README.md's "v1 limitations" section. (Delivered in v1.1: compress
`.min.cast` default, `defaults.render` + agg theme palettes, `rehearse`, `verify`,
`publish` — see the v1.1 entry above.)

### Deferred Features

- **Raw-hatch CLI capture**: `raw_tape`/`raw_script` scenes are recognized and skipped
  cleanly (no error) — VHS/asciinema must be run by hand for these escape hatches.
- **Compiled-tape/driver execution**: The VHS tape and asciinema driver text are produced
  and validated at compile time but never executed by `record`; real capture uses raw
  `lib/*.sh` scripts instead. The compiled driver's shell quoting is also not yet
  POSIX-safe (see `compile.rs`).
- **MP4 rendering**: `lib/render.sh mp4` (Xvfb + xterm + ffmpeg) has no automated test
  coverage — most CI runners lack a display server.
- **Server stop / board reset on switch**: `Step::Switch` starts the next server and gates
  on readiness but never stops the prior server or runs a `tt-smi -r` board reset.
- **Screen capture is not in the CLI or the manifest**: `lib/screen_capture.sh` is called
  directly — there is no `tt-demo record` path to it and no scene shape for a GUI window.
  (`doctor` does check `obs`/`spectacle`/Pillow via `doctor::SCREEN_CAPTURE`, advisory
  unless `--require-screen`; the verifier is covered by
  `lib/tests/screen_capture_test.sh`.) The capture backends themselves remain untestable
  here: OBS needs a real graphical session and an interactively granted portal.

### v1 Known Behavior (Documented for v1.1 Clarity)

- **Single-pane scenes with multi-statement commands**: If a scene's `right.run` is a
  multi-statement sequence (e.g. `"setup; long-viz"`), the entire command is backgrounded
  as a subshell in the kill/wait safety net (lines 170–172 in `bin/src/record.rs`).
  Individual non-terminating sub-steps are not separately managed — only the whole sequence
  gets the `kill` timeout.
- **Automated server start/readiness testing**: The `Step::Switch` readiness gating path
  (`serve.sh` + `poll_http`/log-wait in `ready::` and `wait_for_log()`) is verified
  manually on real hardware but lacks automated test coverage. This is planned for v1.1.
