# tt-demo-maker — Design Spec (v1)

*Date: 2026-07-18 · Status: approved · Owner: Taylor Singletary*

## 1. Purpose

`tt-demo-maker` is a reusable, project-agnostic toolkit for authoring **demo recordings and
draft posts** from inside any project. It turns a natural-language ask ("record me a
cold-model-load causation clip in arcade mode") into: recorded terminal footage (GIF / MP4 /
asciicast) **and** a first-draft Markdown post that pairs each *directive* with the *reaction*
it caused, with LLM-written narration explaining the causation.

It exists because the same recording machinery is currently reinvented in every project —
tt-toplike (`record-casts.sh`), tt-forge-compiletron (`record_demo.sh`,
`render_demo_video.sh`, `compress_cast.py`), tt-animatediff (`record_demo.sh`, `bringup.tape`),
tt-local-generator (`vhs-defaults.tape`, `demo-quickstart.tape`), and tt-zork1
(`record-all.sh`). tt-demo-maker centralizes that machinery so any project gets it for free.

### Motivating prior-art patterns (generalized here)

- **Two engines:** VHS `.tape` files and asciinema `.cast` (via tmux `send-keys` injection for
  TUIs, or a driver script with `type()/run()/comment()/section()` helpers).
- **A shared VHS defaults / theme file** (`vhs-defaults.tape`).
- **Post-processing:** `compress_cast.py` idle-trim; `render_demo_video.sh` Xvfb→xterm→ffmpeg
  true-color MP4; agg for GIF.
- **A demo registry** (tt-zork1's `name|script|cols|rows|needs_llm`).
- **Inference-server orchestration:** start a server, poll its log for a ready-marker, record.
- **Env-noise suppression** (`TF_CPP_MIN_LOG_LEVEL`, `PAGER=cat`, `PYTHONWARNINGS`, …).
- **Pipeline engine + server registry** (tt-local-generator `pipeline_engine.py` /
  `server_manager.py`): stage graph with per-stage backend selection; port-8000 servers are
  mutually exclusive, so it stops/resets/starts when a stage needs a different backend; a
  `--dry-run` mode runs the whole graph with placeholder outputs and touches no hardware (CI);
  a `ServerDef` registry with an HTTP health check that confirms the *right* model is loaded
  (`/tt-liveness` `runner_in_use` / `model_ready`), not just that *a* server answers; graceful
  three-tier prompt generation that never fails the run when the LLM is down.

## 2. Goals / Non-goals

**Goals (v1):**
- One command surface (`tt-demo`) usable from any repo, plus a `/tt-demo` Claude skill front door.
- Declarative, LLM-authorable manifest (`demo/demos.yaml`) with a raw `.tape`/`.sh` escape hatch.
- **Two-pane causation capture** (directive pane → viz pane, one recording, real timing).
- **Inference-server orchestration** (start → wait-for-marker → record).
- **MP4 + GIF + compress** post-processing pipeline.
- **Assembled draft post** (`demo/POST.draft.md`) with LLM narration (Claude *or* local Qwen).
- Per-scene engine flexibility (asciinema vs VHS) with an `auto` selection rule.
- Consistent look via shared themes rendered as matched VHS + agg/xterm variants.
- **Tiered readiness** (cheap log/stdout marker → authoritative HTTP health probe with an
  optional model-identity check) so a scene records against the *right* loaded model.
- **Multi-scene server orchestration**: `record all` orders scenes to minimize backend thrash,
  switching (stop → reset → start) only when the next scene needs a different exclusive server.
- **`--dry-run`**: validate + compile + emit the capture plan and placeholder assets, touching
  no hardware / tmux / docker (CI-safe).

**Non-goals (deferred to v2):**
- GUI / browser capture (wf-recorder / OBS picture-in-picture).
- `--serve` / `--remote` relay capture (clean viz recording while load runs elsewhere).
- tt-home auto-sync / cross-machine propagation.
- A prebuilt library of canned TT scenarios.

## 3. Architecture — three layers

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

### Layer 1 · `lib/` — capture primitives (bash)

Kept in bash because escaping tmux / ffmpeg / Xvfb pipelines through Rust `Command` is a step
backward; bash is genuinely better at the process ballet.

- `driver.sh` — sourced helpers `type() / run() / comment() / section() / pause()` + pacing
  constants (`DELAY_CHAR`, `DELAY_ENTER`, `DELAY_THINK`, `DELAY_SECTION`) + env-noise
  suppression. Generalized from tt-animatediff `record_demo.sh`.
- `tmux_capture.sh` — spin a fixed-size tmux session, launch a command, optionally inject
  keys, wrap the pane in asciinema. Single-pane. From tt-toplike `record-casts.sh`.
- `split.sh` — **the marquee**: two-pane tmux (left = directive, right = viz), record the whole
  window as one asciicast with real causation/timing. See §6.
- `serve.sh` — start a server command, tail its log, block until a ready-marker regex appears
  (with timeout), then signal readiness. From tt-zork1 `start_inference_server` + tt-toplike
  media readiness.
- `render.sh` — `cast → MP4` (Xvfb → xterm → ffmpeg x11grab true-color) and `cast → GIF` (agg).
  From tt-forge-compiletron `render_demo_video.sh`.

Every primitive is idempotent: it kills leftover tmux/asciinema/Xvfb from prior runs before
starting, and cleans up on exit.

### Layer 2 · `bin/tt-demo` — orchestrator (Rust)

Owns what Rust is good at. Crates: `clap` (CLI/subcommands), `serde` + `serde_yml`
(manifest — `serde_yaml` is archived; use the maintained fork), `minijinja` (scene → tape /
driver templating), `regex` (`wait_for` markers), `serde_json` (native cast compression),
`which` (`doctor` preflight), `anyhow` + `thiserror` (errors). YAML stays (friendliest for LLM
authoring + nested scenes).

Subcommands:
- `tt-demo init` — scaffold `demo/` in the current project: starter `demos.yaml`, `.gitignore`
  for raw casts, `assets/` dir.
- `tt-demo list` — list scenes and their status (recorded? rendered?).
- `tt-demo doctor` — preflight every dependency (vhs, asciinema, agg, ffmpeg, Xvfb, xterm,
  tmux) and report what is missing.
- `tt-demo record <id|all>` — read + validate `demos.yaml`, compile the scene (→ tape or
  asciinema driver via minijinja), invoke the correct capture primitive (single / split /
  serve-wait), write the raw asset.
- `tt-demo compress <cast>` — idle-trim a raw cast (`--max-idle`, `--min-gap`). Native Rust
  (serde_json), replacing `compress_cast.py`.
- `tt-demo render <id> [--mp4|--gif]` — post-process a clean cast → MP4/GIF via `render.sh`;
  VHS scenes render directly through VHS.
- `tt-demo post` — assemble `demo/POST.draft.md` from the manifest + assets + narration.

**Iteration cost note:** per-demo tuning lives in *data* (`demos.yaml`, `.tape`, driver `.sh`),
never in the binary — so tweaking pacing/captions never recompiles `tt-demo`.

### Layer 3 · `skill/` — `/tt-demo` Claude skill

The "from any project, make it happen" front door. `SKILL.md` instructs the agent to:
1. read/author `demo/demos.yaml` from the user's natural-language description (schema doc in
   `skill/manifest-schema.md` so **any** LLM — Claude or a local Qwen CPU model — can emit
   valid YAML);
2. call `tt-demo` subcommands;
3. write narration into `POST.draft.md`.

Installed to `~/.claude/skills/tt-demo/` by `install.sh`.

## 4. The manifest (`demo/demos.yaml`)

The LLM-facing surface. Deliberately small and bounded so a local Qwen can fill it reliably.

```yaml
project: tt-toplike
theme: tt-brand                 # from themes/  (tt-brand | dracula)
defaults:
  cols: 200
  rows: 50
  backend: "--backend hybrid"   # convenience token interpolable into scene commands
  outputs: [cast, gif]
  padding: 20
  typing_speed: 60ms
  playback_speed: 1.0

# Optional named-server registry (exclusive backends, mostly port-8000). A scene's
# `server:` names an entry here; `record all` groups/orders scenes by server and only
# stops→resets→starts when the required server changes (see §6.1). Omit entirely for
# self-contained scenes whose `left.run` starts whatever they need.
servers:
  qwen3:
    start: "tt-serve qwen3-8b"
    stop:  "tt-serve --stop qwen3-8b"
    ready:
      health_url: "http://localhost:8000/tt-liveness"
      ready_field: "model_ready"      # JSON field must be truthy
      runner_key:  "qwen3-8b"         # confirm the RIGHT model (runner_in_use), not just 2xx
      timeout: 360s
  skyreels:
    start: "bin/start_skyreels.sh"
    ready: { health_url: "http://localhost:8000/tt-liveness", ready_field: "model_ready", runner_key: "skyreels", timeout: 900s }

scenes:
  - id: cold-load
    title: "Cold model load"
    engine: auto                 # auto | vhs | asciinema   (see §5)
    layout: split                # single | split
    server: qwen3                # this scene needs the qwen3 server ready first
    left:                        # directive pane
      run: "tt-serve qwen3-8b"
      ready:                     # tiered readiness gate (see §6) — or `wait_for: "regex"` sugar
        log: "warmed up and ready"                       # tier 1: cheap stdout/log marker
        health_url: "http://localhost:8000/tt-liveness"  # tier 2: authoritative probe
        ready_field: "model_ready"
        runner_key: "qwen3-8b"
        timeout: 360s
    right:                       # viz pane
      run: "tt-toplike --mode arcade {backend}"
      keys: []                   # optional tmux keypresses after first paint
    split_ratio: 40              # left pane % (default 40)
    duration: 90s                # linger; or driven by ready + trailing pad
    caption: "Power steps up in plateaus as weights load; the hero climbs."
    outputs: [cast, gif, mp4]

  - id: qa-short
    title: "One short question"
    layout: single
    server: qwen3                # reuses the already-warm qwen3 server (no restart)
    right: { run: "tt-toplike --mode starfield {backend}" }
    # a separate driver types the prompt into a serving endpoint

  - id: video-gen
    title: "Video generation — the long pull"
    layout: split
    server: skyreels             # exclusive: forces stop→reset→start away from qwen3
    left:  { run: "tt-generate 'a fox in snow' --video", wait_for: "in flight" }
    right: { run: "tt-toplike --mode arcade {backend}" }
    duration: 240s

  - id: gui-dashboard            # escape hatch — full control
    raw_tape: demo/raw/gui.tape

  - id: kernel-run               # escape hatch — asciinema driver
    raw_script: demo/raw/kernel.sh
```

**Per-scene fields:** `id`, `title`, `engine`, `layout`, `left`, `right`, `split_ratio`,
`duration`, `caption`, `outputs`, `server` (name into the top-level `servers:` map), plus
per-scene overrides of any `defaults.*`.
**Readiness (`ready:`):** `log` (stdout/log regex, tier 1), `health_url` + `ready_field`
(HTTP probe, tier 2), `runner_key` (confirm the right model via `runner_in_use`), `timeout`.
`wait_for: "regex"` is sugar for `ready: { log: "regex" }`.
**Escape hatches:** `raw_tape:` (a hand-written VHS tape) or `raw_script:` (a hand-written
asciinema driver). A scene has *either* declarative fields *or* one raw hatch.

Fields promoted to first-class (routinely tuned, per user): `padding`, `typing_speed`,
`playback_speed`, `split_ratio`, `cols/rows`, `outputs`, `backend`.

## 5. Engine selection (`engine:`) — asciinema vs VHS

Per-scene, orthogonal to orchestrator language. `auto` resolves by this rule:

- **asciinema** when the scene needs *live real timing* — `layout: split`, a TUI driven by
  injected `keys`, or anything watching real hardware react. The "authentic reaction" engine.
- **VHS** when the scene is a *deterministic scripted single-terminal* sequence — a clean hero
  clip, a quickstart, a title card. Repeatable, themed, pixel-stable.
- `raw_tape:` ⇒ VHS; `raw_script:` ⇒ asciinema.
- An explicit `engine:` always overrides `auto`.

Both engines read the **same `theme:`**, rendered as matched VHS-partial *and* agg/xterm
variants, so a scene looks identical regardless of engine.

## 6. Two-pane causation capture (the heart)

`split.sh` sizes a tmux window `cols×rows`, splits horizontally at `split_ratio` (default 40/60,
left=directive / right=viz).

1. Right pane launches the viz command; wait for first paint.
2. If `left.ready` is set, the server is pre-started and we **block on readiness (with timeout)
   before the recorded window begins** — so the clip shows the *ask and its reaction*, not a
   90-minute compile. (Omit `ready` when the compile/load itself is the show.)
3. asciinema wraps `tmux attach` on the window → one file, real timing, real causation.
4. On completion: quit the viz (`q`), tear down the session, kill the server if we started it.

### 6.1 Tiered readiness

Readiness follows the tt-toplike house rule (*active ≠ matched; cheap signal first, authoritative
probe off the hot path*):
1. **Tier 1 — `log`:** grep the server's stdout/log for a cheap marker (fast, no request). If it
   is the only field, that alone gates readiness (the classic tt-zork1 pattern).
2. **Tier 2 — `health_url` + `ready_field`:** once tier 1 (or immediately, if no `log`) passes,
   poll the HTTP endpoint until `ready_field` (e.g. `model_ready`) is truthy.
3. **Identity — `runner_key`:** if set, also confirm `runner_in_use == runner_key` so a scene
   never records against the *wrong* model on a shared port (mirrors `server_manager.ServerDef`).

`timeout` on any tier is a hard, clearly-reported failure — never an indefinite hang.

### 6.2 Multi-scene server orchestration (`record all`)

Exclusive backends (port-8000 model servers) can't co-run, so `tt-demo record all`:
1. Resolves each scene's `server:` (if any) against the top-level `servers:` map.
2. **Orders scenes to group identical servers**, minimizing stop/reset/start thrash (a warm
   `qwen3` server is reused across cold-load → qa-short before switching to `skyreels`).
3. On a switch: run the current server's `stop`, `tt-smi -r` reset (only when switching *from*
   a prior backend), then the next server's `start` and its `ready` gate — the
   `pipeline_engine._backend_for` pattern, generalized.
4. Scenes with no `server:` are self-contained (their `left.run` starts whatever they need).

### 6.3 `--dry-run`

`tt-demo record --dry-run` (and `record all --dry-run`) validates + compiles every scene, prints
the ordered capture/switch plan, and writes tiny placeholder assets — touching **no** tmux,
hardware, docker, or `tt-smi`. This is the CI path and the fast manifest-authoring feedback loop,
mirroring `pipeline_engine`'s `dry_run`.

## 7. Data flow

```
your description
  → (skill/LLM) demo/demos.yaml
    → tt-demo record         compile scene → capture (single | split | serve-wait) → raw .cast
      → tt-demo compress     idle-trim → clean .cast
        → tt-demo render     → gif / mp4
          → tt-demo post     POST.draft.md  (assets + LLM narration)
```

## 8. Narration & local-model fallback

`tt-demo post` assembles `POST.draft.md`: an intro, then one section per scene pairing the
directive clip with the viz clip and a narration paragraph explaining the causation, seeded from
each scene's `caption`.

`--narrate-with local|claude|none` degrades gracefully (narration availability never fails a
run — the classic `prompt_client` three-tier posture):
- `claude` — the skill (this agent) writes the prose.
- `local` — POST to the tt-local-generator prompt-server (`http://127.0.0.1:8001/v1/chat/completions`),
  gated by `GET /health` → `model_ready`, with a small schema-bounded prompt (works with no
  Claude in the loop). If the endpoint is down, fall back to `none`.
- `none` — emit each scene's `caption` verbatim, no generated prose.

## 9. Repo layout

```
~/code/tt-demo-maker/
  bin/            (Rust crate — the tt-demo CLI)
    Cargo.toml
    src/{main.rs, manifest.rs, compile.rs, record.rs, orchestrate.rs, ready.rs, compress.rs, render.rs, post.rs, doctor.rs}
  lib/{driver.sh, tmux_capture.sh, split.sh, serve.sh, render.sh}
  themes/{tt-brand.tape, tt-brand.agg.json, tt-brand.xterm, dracula.tape, dracula.agg.json, …}
  skill/{SKILL.md, manifest-schema.md}
  examples/                       (tt-toplike reference manifest — the original ask, worked)
    demos.yaml
  templates/{tape.j2, asciinema-driver.sh.j2, post.md.j2}   (minijinja templates)
  install.sh                      (symlink bin → ~/.local/bin, skill → ~/.claude/skills)
  README.md
  AGENTS.md
  docs/superpowers/specs/2026-07-18-tt-demo-maker-design.md
```

## 10. Distribution / install

`install.sh` (run by hand, per machine):
1. `cargo build --release` the `bin/` crate.
2. Symlink `target/release/tt-demo → ~/.local/bin/tt-demo`.
3. Symlink `skill/ → ~/.claude/skills/tt-demo`.
4. `chmod +x lib/*.sh`; point `tt-demo` at `lib/`/`themes/` via a resolved install prefix
   (env `TT_DEMO_HOME` or a default of the repo path).

No tt-home coupling in v1 (deferred).

## 11. Testing

- **`--dry-run` as the CI backbone:** `tt-demo record all --dry-run` validates + compiles every
  scene and prints the ordered capture/switch plan with zero hardware/tmux/docker — the primary
  CI gate, mirroring `pipeline_engine`'s `dry_run`.
- **Hardware-optional golden test:** `tt-demo init` in a temp dir + a trivial `--host` /
  `echo`-based scene recorded end-to-end to a tiny GIF — exercises the whole *real* pipeline with
  no accelerator.
- **Manifest validation:** unit tests over valid + invalid manifests (missing id, both
  declarative-and-raw, bad `wait_for` type, unknown engine, …) asserting precise errors.
- **Compile tests:** a scene struct → expected tape / driver text (minijinja golden output).
- **`tt-demo doctor`** doubles as a dependency smoke test.
- Reference `examples/demos.yaml` uses `--host` so the full pipeline is runnable without TT
  hardware.

## 12. Error handling

- `doctor`-gated preflight; every subcommand checks its deps and fails with a clear message
  (mirroring compiletron's `for dep in …`).
- Idempotent cleanup of leftover tmux/asciinema/Xvfb before each run.
- Readiness (`ready`/`wait_for`) timeout on any tier → clear failure, not a hang.
- Server orchestration failure (a `start`/`stop`/reset that errors) aborts before recording,
  with the offending server named.
- Unknown scene id → print the valid ids.
- A scene with both declarative fields and a raw hatch → validation error.

## 13. v1 scope boundary (explicit)

**In:** `init/list/doctor/record(single+split+serve-wait)/compress/render(mp4+gif)/post`;
tiered readiness; multi-scene server orchestration + `--dry-run`; tt-brand + dracula themes;
manifest + escape hatch; narration (claude/local/none); self-contained `install.sh`.

**Out (v2):** GUI/browser capture; `--serve`/`--remote` relay capture; tt-home auto-sync;
prebuilt TT-scenario library.

## 14. First worked example

The tt-toplike causation post (the original ask) ships as `examples/demos.yaml` + its generated
`POST.draft.md` — the reference demo *and* the first real deliverable. Scenes: cold-load,
warm-load, qa-short, deep-think, batch-infer, image-gen, video-gen, kernel-run, tt-bio,
reset-lightshow (subset selectable).
