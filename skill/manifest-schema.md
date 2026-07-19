# `demo/demos.yaml` — manifest schema

The LLM-facing surface for `tt-demo`. Deliberately small and bounded so a local Qwen can
fill it reliably. This doc lists every field the parser understands
(`bin/src/manifest.rs`); anything not listed here is not read.

## Top level

| Field | Type | Required | Meaning |
|---|---|---|---|
| `project` | string | yes | Free-text project name, used in the assembled post. |
| `theme` | string | yes | A name from `themes/` (e.g. `tt-brand`, `dracula`) — rendered as matched VHS + agg/xterm variants so both engines look the same. |
| `defaults` | map | no | Scene-wide defaults, see below. |
| `servers` | map | no | Named exclusive-backend registry, see below. |
| `scenes` | list | no | The scene list, see below. |

### `defaults.*`

All optional; a scene can override the ones that matter to it via its own top-level fields
(`split_ratio`, `duration`, `outputs`) or by using the `{backend}` token.

| Field | Type | Meaning |
|---|---|---|
| `cols` | int | Terminal width in columns (default 200). |
| `rows` | int | Terminal height in rows (default 50). |
| `backend` | string | Interpolated wherever a pane's `run:` contains the literal token `{backend}` (e.g. `"--host"`, `"--backend hybrid"`). Keep demos non-invasive: prefer `--host`/`--backend hybrid` over touching real ASICs. |
| `outputs` | list | Which artifacts to produce: any of `cast`, `gif`, `mp4`. |
| `padding` | int | VHS theme padding (pixels). |
| `typing_speed` | string | VHS `Set TypingSpeed` (e.g. `60ms`). |
| `playback_speed` | float | VHS `Set PlaybackSpeed`. |

### `servers.<name>`

An optional named-server registry for **exclusive** backends (mostly port-8000 model
servers that can't co-run). A scene points at one via its own `server:` field; `tt-demo
record all` groups and orders scenes by server, only stopping → resetting → starting when
the next scene needs a different one. Omit entirely for self-contained scenes whose
`left.run` starts whatever they need.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `start` | string | yes | Shell command that brings the server up. |
| `stop` | string | no | Shell command that tears it down before switching away. |
| `ready` | map | no | Tiered readiness gate — see **`ready:`** below. |

## Scenes (`scenes[]`)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | yes | Unique scene id (used for asset filenames, CLI selection). |
| `title` | string | no | Human-readable title for the post. |
| `engine` | `auto` \| `vhs` \| `asciinema` | no | Capture engine; default `auto` — see **Engine selection** below. |
| `layout` | `single` \| `split` | no | `single` = one viz pane; `split` = directive pane (`left`) + viz pane (`right`). Default `single`. |
| `left` | pane | no | Directive pane (only meaningful for `layout: split`). |
| `right` | pane | required unless raw | Viz pane — what the camera is pointed at. |
| `split_ratio` | int (0-100) | no | Left pane width %, default 40. |
| `duration` | string | no | How long to linger, e.g. `8s`, `90s`. Default `8s`. |
| `caption` | string | no | One-sentence causation summary; seeds the post narration. |
| `outputs` | list | no | Per-scene override of `defaults.outputs`. |
| `server` | string | no | Name into the top-level `servers:` map — this scene needs that server ready first. |
| `raw_tape` | string | escape hatch | Path to a hand-written VHS `.tape` file. Forces engine `vhs`. |
| `raw_script` | string | escape hatch | Path to a hand-written asciinema driver `.sh`. Forces engine `asciinema`. |

A scene has **either** declarative fields (`left`/`right`/…) **or** exactly one raw hatch
(`raw_tape` or `raw_script`) — never both; the validator rejects a scene that sets both, and
rejects a non-raw scene missing `right`.

### Pane fields (`left:` / `right:`)

| Field | Type | Meaning |
|---|---|---|
| `run` | string | Shell command for this pane. May contain the `{backend}` token (interpolated from `defaults.backend`). |
| `ready` | map | Tiered readiness gate for this pane — see `ready:` below. |
| `wait_for` | string | Sugar: `wait_for: "regex"` is shorthand for `ready: { log: "regex" }`. |
| `keys` | list of strings | Optional tmux keypresses injected into this pane after first paint (split/asciinema scenes only). |

### `ready:` (tiered readiness — same shape on `servers.<name>.ready` and a pane's `ready`)

Readiness follows the house rule: *active ≠ matched; cheap signal first, authoritative probe
off the hot path.*

| Field | Tier | Meaning |
|---|---|---|
| `log` | 1 | Regex against the server's stdout/log — a cheap marker. If it's the only field set, it alone gates readiness. |
| `health_url` | 2 | HTTP endpoint polled once tier 1 passes (or immediately, if no `log`). |
| `ready_field` | 2 | JSON field on the `health_url` response that must be truthy. |
| `runner_key` | identity | If set, also confirms `runner_in_use == runner_key` — so a scene never records against the *wrong* model on a shared port. |
| `timeout` | all | Hard timeout (e.g. `360s`); a miss is a clear, reported failure — never an indefinite hang. |

`wait_for: "regex"` on a pane is exactly `ready: { log: "regex" }`.

## Engine selection (`engine:`)

`auto` (the default) resolves to:
- **`asciinema`** when the scene needs live real timing — `layout: split`, a pane with
  non-empty `keys`, or `raw_script:`.
- **`vhs`** otherwise — a deterministic scripted single-terminal sequence, or `raw_tape:`.
- An explicit `engine: vhs`/`engine: asciinema` always overrides the `auto` rule.

## Escape hatches

- `raw_tape: demo/raw/name.tape` — hand-written VHS tape, full control (GUI capture, tricky
  pixel-stable shots). Engine forced to `vhs`.
- `raw_script: demo/raw/name.sh` — hand-written asciinema driver (sourcing `lib/driver.sh`
  helpers `type()/run()/comment()/section()/pause()`). Engine forced to `asciinema`.

A scene may use *one* of these instead of `left`/`right`/`layout`.

## Compact example

```yaml
project: tt-toplike
theme: tt-brand
defaults: { cols: 200, rows: 50, backend: "--host", outputs: [cast, gif] }

servers:
  qwen3:
    start: "tt-serve qwen3-8b"
    stop:  "tt-serve --stop qwen3-8b"
    ready:
      log: "warmed up and ready"
      health_url: "http://localhost:8000/tt-liveness"
      ready_field: "model_ready"
      runner_key: "qwen3-8b"
      timeout: 360s

scenes:
  - id: cold-load
    title: "Cold model load"
    layout: split
    server: qwen3
    left:  { run: "tt-serve qwen3-8b", wait_for: "warmed up and ready" }
    right: { run: "tt-toplike {backend} --mode arcade" }
    split_ratio: 40
    duration: 90s
    caption: "Power steps up in plateaus as weights load; the hero climbs."

  - id: qa-short
    layout: single
    right: { run: "tt-toplike {backend} --mode starfield" }
    caption: "A short prompt spikes current, then settles."

  - id: gui-dashboard   # escape hatch
    raw_tape: demo/raw/gui.tape
```

See `examples/demos.yaml` for the full hardware-free (`--host`) tt-toplike reference, and
`docs/superpowers/specs/2026-07-18-tt-demo-maker-design.md` §4–§6 for the full rationale.
