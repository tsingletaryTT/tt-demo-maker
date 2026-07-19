# tt-demo-maker

A reusable, project-agnostic toolkit for authoring **demo recordings and draft posts** from
inside any project. Point it at a TUI/CLI, describe what you want captured, and it turns
that into recorded footage (asciicast / GIF / MP4) **and** a first-draft Markdown post that
pairs each *directive* with the *reaction* it caused.

It exists so recording machinery (tmux + asciinema/VHS + ffmpeg + agg, idle-trimming, a demo
registry, inference-server-aware readiness gating) isn't reinvented per-project.

## Layers

```
description ──▶ /tt-demo skill (LLM: Claude or local Qwen)
                 │  authors/edits demo/demos.yaml, writes narration
                 ▼
            bin/tt-demo  (Rust orchestrator — the stable interface)
                 │  parse+validate manifest, compile scenes, drive flow
                 ▼
            lib/*.sh     (bash capture primitives — the terminal ballet)
                 │  spawn: tmux · asciinema · vhs · Xvfb · xterm · ffmpeg · agg
                 ▼
            demo/assets/*  +  demo/POST.draft.md
```

Full design: `docs/superpowers/specs/2026-07-18-tt-demo-maker-design.md`.

## Install

```bash
./install.sh
```

This builds the `tt-demo` release binary, symlinks it to `~/.local/bin/tt-demo`, and
symlinks `skill/` to `~/.claude/skills/tt-demo` (so the `/tt-demo` Claude skill is
available in any project). If you invoke `tt-demo` from outside this repo, set
`TT_DEMO_HOME=/path/to/tt-demo-maker` so it can find `lib/`, `templates/`, and `themes/`.

## Quickstart

From the root of any project you want to demo:

```bash
tt-demo doctor                 # check for tmux, asciinema, vhs, agg, ffmpeg, Xvfb, xterm
tt-demo init                   # scaffold demo/demos.yaml, demo/assets/, demo/.gitignore
$EDITOR demo/demos.yaml        # describe your scenes — see skill/manifest-schema.md
tt-demo record --dry-run       # validate + print the capture plan; touches no hardware
tt-demo record all             # capture every scene (single/split/serve-wait as declared)
tt-demo compress demo/assets/<id>.cast   # idle-trim a raw cast
tt-demo render <id> --gif      # (or --mp4) post-process a clean cast into an artifact
tt-demo post --narrate claude  # assemble demo/POST.draft.md (narration written by the skill)
```

`tt-demo list` shows every scene's resolved engine (`vhs`/`asciinema`) and whether it's been
recorded yet.

## Using the `/tt-demo` skill

Once installed, ask your agent (in any project) something like "record a short demo of the
cold-load causing the arcade viz to react" and the `/tt-demo` skill will author/edit
`demo/demos.yaml`, drive the CLI above, and write the narration in `demo/POST.draft.md`.
See `skill/SKILL.md` for the exact steps it follows and `skill/manifest-schema.md` for the
full manifest field reference.

## Reference example

`examples/demos.yaml` is the tt-toplike reference manifest — three scenes (`qa-short`,
`cold-load`, `reset-lightshow`) built entirely from `tt-toplike --host` (no ASIC needed), so
the whole pipeline is runnable and CI-testable without hardware. Copy it into a project as a
starting point:

```bash
mkdir -p demo && cp examples/demos.yaml demo/demos.yaml
```

## Non-invasive by default

Demo scene commands should prefer `--host` or `--backend hybrid` (interpolated via the
`{backend}` token in `defaults.backend`) over touching real hardware directly — this keeps
demos safe to record on shared boxes and runnable in CI via `--dry-run`.

## v1 limitations / v1.1

`tt-demo record` (non-dry-run) drives declarative (`left`/`right`) scenes straight through
the tested `lib/*.sh` capture primitives, using each scene's raw `run:` commands. The
following are deliberately deferred to v1.1:

- **Raw-hatch CLI capture.** `raw_tape`/`raw_script` scenes are recognized and skipped
  cleanly (no error) rather than executed — run VHS/asciinema on them by hand for now.
- **Compiled-tape/driver execution.** `compile_scene`'s rendered VHS tape / asciinema
  driver text (`Compiled.text`) is produced and validated (compile-time only) but never
  executed by `record`; real capture goes through `lib/tmux_capture.sh`/`lib/split.sh`
  directly against the scene's raw commands instead. The compiled-driver's own shell
  quoting (`Debug`-repr, in `compile.rs`) also isn't POSIX-shell-safe yet — fine for the
  unexecuted text today, but must be fixed before that path is wired up.
- **Theme-matched GIF palette.** `tt-demo render --gif` shells out to `agg` with its
  default palette; it doesn't yet apply the manifest's `theme:` (`tt-brand`/`dracula`)
  colors the way the VHS path does.
- **MP4 rendering is unexercised.** `lib/render.sh mp4` (Xvfb + xterm + ffmpeg) exists but
  has no automated coverage here — it needs a display server most CI runners don't have.
- **Server stop / board reset on switch.** `Step::Switch` starts the next scene's server
  and waits for its readiness gate, but never stops whatever was running before it or runs
  a `tt-smi -r` board reset — switching between two exclusive hardware-backed servers back
  to back is not yet safe to automate.
