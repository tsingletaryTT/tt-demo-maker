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
