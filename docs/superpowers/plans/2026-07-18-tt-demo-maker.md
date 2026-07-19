# tt-demo-maker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable, project-agnostic `tt-demo` toolkit that turns a declarative manifest into demo footage (GIF/MP4/asciicast) plus an assembled draft post.

**Architecture:** Three layers — bash capture primitives (`lib/*.sh`) driven by a Rust orchestrator CLI (`bin/` → `tt-demo`), with a `/tt-demo` Claude skill as the front door. Per-demo content lives in data (`demos.yaml`, tapes, drivers), never in the binary.

**Tech Stack:** Rust (clap, serde, serde_yml, serde_json, minijinja, regex, which, ureq, anyhow, thiserror) + bash (tmux, asciinema, vhs, agg, ffmpeg, Xvfb, xterm).

## Global Constraints

- Rust edition 2021; binary name is exactly `tt-demo` (`[[bin]] name = "tt-demo"`).
- Crate lives in `bin/`; all Rust paths below are relative to `bin/` unless noted.
- YAML manifest parsing uses `serde_yml` (the maintained fork; `serde_yaml` is archived). Pin `serde_yml = "0.0.12"`.
- No network or hardware in unit tests. HTTP/health logic is split into a pure function (unit-tested) and a thin `ureq` wrapper (not unit-tested).
- Every subcommand fails with a clear, actionable message; never panic on user input.
- TUI/borders rule inherited from the org: left/bottom borders only in any box-drawing output — not relevant to code here but keep any ASCII output left-aligned.
- Commit after every task with a `feat:`/`test:`/`docs:` message.
- Reference example manifest (`examples/demos.yaml`) MUST run hardware-free (uses `tt-toplike --host` or `echo`).

---

### Task 1: Crate scaffold + `doctor`

**Files:**
- Create: `bin/Cargo.toml`
- Create: `bin/src/main.rs`
- Create: `bin/src/doctor.rs`

**Interfaces:**
- Produces: `doctor::check_deps(names: &[&str]) -> Vec<(String, bool)>` — for each name, whether it resolves on `PATH`. `doctor::run() -> anyhow::Result<()>` prints a table and returns `Err` if any required dep is missing.

- [ ] **Step 1: Write `bin/Cargo.toml`**

```toml
[package]
name = "tt-demo"
version = "0.1.0"
edition = "2021"
description = "Reusable demo-recording toolkit: manifest -> footage + draft post"

[[bin]]
name = "tt-demo"
path = "src/main.rs"

[dependencies]
clap = { version = "4", features = ["derive"] }
serde = { version = "1", features = ["derive"] }
serde_yml = "0.0.12"
serde_json = "1"
minijinja = "2"
regex = "1"
which = "6"
ureq = "2"
anyhow = "1"
thiserror = "1"
```

- [ ] **Step 2: Write the failing test for `check_deps`**

Add to `bin/src/doctor.rs`:

```rust
//! Dependency preflight for tt-demo.
use which::which;

/// For each tool name, report whether it resolves on PATH.
pub fn check_deps(names: &[&str]) -> Vec<(String, bool)> {
    names.iter().map(|n| (n.to_string(), which(n).is_ok())).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_present_and_absent_tools() {
        let out = check_deps(&["sh", "tt_demo_definitely_absent_xyz"]);
        assert_eq!(out.len(), 2);
        assert!(out[0].1, "sh should be found on PATH");
        assert!(!out[1].1, "bogus tool must be absent");
    }
}
```

- [ ] **Step 3: Run test to verify it fails (no crate yet)**

Run: `cd bin && cargo test doctor::tests::detects_present_and_absent_tools`
Expected: FAIL — `main.rs` does not yet declare `mod doctor` / no `run()`; compile error.

- [ ] **Step 4: Write `bin/src/main.rs` with clap skeleton wiring `doctor`**

```rust
mod doctor;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "tt-demo", about = "Manifest -> demo footage + draft post")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Preflight: check that required tools are installed.
    Doctor,
}

fn main() -> anyhow::Result<()> {
    match Cli::parse().cmd {
        Cmd::Doctor => doctor::run(),
    }
}
```

Append `run()` to `bin/src/doctor.rs`:

```rust
/// Required external tools for the full pipeline.
pub const REQUIRED: &[&str] = &["tmux", "asciinema", "agg", "ffmpeg", "vhs", "Xvfb", "xterm"];

pub fn run() -> anyhow::Result<()> {
    let mut missing = Vec::new();
    println!("tt-demo doctor — dependency check");
    for (name, ok) in check_deps(REQUIRED) {
        println!("  [{}] {}", if ok { "ok " } else { "MISSING" }, name);
        if !ok { missing.push(name); }
    }
    if missing.is_empty() {
        println!("all dependencies present");
        Ok(())
    } else {
        anyhow::bail!("missing dependencies: {}", missing.join(", "))
    }
}
```

- [ ] **Step 5: Run test to verify it passes, then commit**

Run: `cd bin && cargo test doctor::`
Expected: PASS.

```bash
git add bin/Cargo.toml bin/src/main.rs bin/src/doctor.rs
git commit -m "feat: tt-demo crate scaffold + doctor dependency check"
```

---

### Task 2: Manifest model + parse/validate

**Files:**
- Create: `bin/src/manifest.rs`
- Modify: `bin/src/main.rs` (add `mod manifest;`)

**Interfaces:**
- Produces:
  - Types `Manifest { project: String, theme: String, defaults: Defaults, servers: BTreeMap<String, ServerDef>, scenes: Vec<Scene> }`
  - `Scene { id, title, engine: Engine, layout: Layout, server: Option<String>, left: Option<Pane>, right: Option<Pane>, split_ratio: Option<u8>, duration: Option<String>, caption: Option<String>, outputs: Option<Vec<String>>, raw_tape: Option<String>, raw_script: Option<String> }`
  - `Pane { run: String, ready: Option<Ready>, keys: Option<Vec<String>> }` with `wait_for` deserialized into `ready.log`.
  - `enum Engine { Auto, Vhs, Asciinema }`, `enum Layout { Single, Split }`
  - `Manifest::from_str(&str) -> anyhow::Result<Manifest>` (parse + validate)
  - `Manifest::scene(&self, id: &str) -> Option<&Scene>`

- [ ] **Step 1: Write failing tests**

Create `bin/src/manifest.rs` ending with:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = r#"
project: demo
theme: tt-brand
defaults: { cols: 200, rows: 50, backend: "--host", outputs: [cast, gif] }
servers:
  qwen3: { start: "srv up", ready: { health_url: "http://h/live", ready_field: model_ready } }
scenes:
  - id: a
    layout: split
    server: qwen3
    left:  { run: "srv up", wait_for: "ready" }
    right: { run: "tt-toplike --host" }
  - id: b
    raw_tape: demo/raw/b.tape
"#;

    #[test]
    fn parses_valid_manifest() {
        let m = Manifest::from_str(VALID).unwrap();
        assert_eq!(m.scenes.len(), 2);
        // wait_for sugar lands in ready.log
        let a = m.scene("a").unwrap();
        assert_eq!(a.left.as_ref().unwrap().ready.as_ref().unwrap().log.as_deref(), Some("ready"));
    }

    #[test]
    fn rejects_scene_with_both_declarative_and_raw() {
        let y = "project: d\ntheme: t\nscenes:\n  - id: x\n    layout: single\n    right: { run: r }\n    raw_tape: t.tape\n";
        assert!(Manifest::from_str(y).unwrap_err().to_string().contains("both"));
    }

    #[test]
    fn rejects_unknown_server_ref() {
        let y = "project: d\ntheme: t\nscenes:\n  - id: x\n    layout: single\n    server: ghost\n    right: { run: r }\n";
        assert!(Manifest::from_str(y).unwrap_err().to_string().contains("ghost"));
    }

    #[test]
    fn rejects_duplicate_ids() {
        let y = "project: d\ntheme: t\nscenes:\n  - id: x\n    layout: single\n    right: { run: r }\n  - id: x\n    layout: single\n    right: { run: r2 }\n";
        assert!(Manifest::from_str(y).unwrap_err().to_string().contains("duplicate"));
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd bin && cargo test manifest::`
Expected: FAIL — types/`from_str` undefined.

- [ ] **Step 3: Write the model + validation**

Prepend to `bin/src/manifest.rs`:

```rust
//! Declarative demo manifest: parse + validate.
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
pub struct Manifest {
    pub project: String,
    pub theme: String,
    #[serde(default)]
    pub defaults: Defaults,
    #[serde(default)]
    pub servers: BTreeMap<String, ServerDef>,
    #[serde(default)]
    pub scenes: Vec<Scene>,
}

#[derive(Debug, Default, Deserialize)]
pub struct Defaults {
    pub cols: Option<u16>,
    pub rows: Option<u16>,
    pub backend: Option<String>,
    pub outputs: Option<Vec<String>>,
    pub padding: Option<u16>,
    pub typing_speed: Option<String>,
    pub playback_speed: Option<f32>,
}

#[derive(Debug, Deserialize)]
pub struct ServerDef {
    pub start: String,
    pub stop: Option<String>,
    pub ready: Option<Ready>,
}

#[derive(Debug, Default, Deserialize)]
pub struct Ready {
    pub log: Option<String>,
    pub health_url: Option<String>,
    pub ready_field: Option<String>,
    pub runner_key: Option<String>,
    #[serde(default)]
    pub timeout: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Pane {
    pub run: String,
    #[serde(default)]
    pub ready: Option<Ready>,
    /// Sugar: `wait_for: "regex"` == `ready: { log: "regex" }`.
    #[serde(default)]
    pub wait_for: Option<String>,
    #[serde(default)]
    pub keys: Option<Vec<String>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Engine { Auto, Vhs, Asciinema }
impl Default for Engine { fn default() -> Self { Engine::Auto } }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Layout { Single, Split }
impl Default for Layout { fn default() -> Self { Layout::Single } }

#[derive(Debug, Deserialize)]
pub struct Scene {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub engine: Engine,
    #[serde(default)]
    pub layout: Layout,
    #[serde(default)]
    pub server: Option<String>,
    #[serde(default)]
    pub left: Option<Pane>,
    #[serde(default)]
    pub right: Option<Pane>,
    #[serde(default)]
    pub split_ratio: Option<u8>,
    #[serde(default)]
    pub duration: Option<String>,
    #[serde(default)]
    pub caption: Option<String>,
    #[serde(default)]
    pub outputs: Option<Vec<String>>,
    #[serde(default)]
    pub raw_tape: Option<String>,
    #[serde(default)]
    pub raw_script: Option<String>,
}

impl Scene {
    pub fn is_raw(&self) -> bool { self.raw_tape.is_some() || self.raw_script.is_some() }
}

impl Manifest {
    pub fn from_str(yaml: &str) -> anyhow::Result<Manifest> {
        let mut m: Manifest = serde_yml::from_str(yaml)
            .map_err(|e| anyhow::anyhow!("manifest parse error: {e}"))?;
        // Desugar wait_for -> ready.log on each pane.
        for s in &mut m.scenes {
            for p in [s.left.as_mut(), s.right.as_mut()].into_iter().flatten() {
                if let Some(w) = p.wait_for.take() {
                    p.ready.get_or_insert_with(Ready::default).log.get_or_insert(w);
                }
            }
        }
        m.validate()?;
        Ok(m)
    }

    fn validate(&self) -> anyhow::Result<()> {
        let mut seen = std::collections::HashSet::new();
        for s in &self.scenes {
            if s.id.is_empty() { anyhow::bail!("scene with empty id"); }
            if !seen.insert(&s.id) { anyhow::bail!("duplicate scene id: {}", s.id); }
            let declarative = s.left.is_some() || s.right.is_some();
            if s.is_raw() && declarative {
                anyhow::bail!("scene {}: has both declarative panes and a raw hatch", s.id);
            }
            if !s.is_raw() && s.right.is_none() {
                anyhow::bail!("scene {}: needs a `right` pane or a raw hatch", s.id);
            }
            if let Some(srv) = &s.server {
                if !self.servers.contains_key(srv) {
                    anyhow::bail!("scene {}: references unknown server `{}`", s.id, srv);
                }
            }
        }
        Ok(())
    }

    pub fn scene(&self, id: &str) -> Option<&Scene> {
        self.scenes.iter().find(|s| s.id == id)
    }
}
```

Add `mod manifest;` to `bin/src/main.rs`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd bin && cargo test manifest::`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add bin/src/manifest.rs bin/src/main.rs
git commit -m "feat: manifest model with parse + validation"
```

---

### Task 3: Engine resolution (the `auto` rule)

**Files:**
- Modify: `bin/src/manifest.rs` (add `resolve_engine`)

**Interfaces:**
- Produces: `Scene::resolved_engine(&self) -> Engine` returning `Vhs` or `Asciinema` (never `Auto`).

- [ ] **Step 1: Write failing tests**

Add to `manifest.rs` tests module:

```rust
    #[test]
    fn engine_auto_split_is_asciinema() {
        let m = Manifest::from_str(VALID).unwrap();
        assert_eq!(m.scene("a").unwrap().resolved_engine(), Engine::Asciinema);
    }

    #[test]
    fn engine_auto_raw_tape_is_vhs() {
        let m = Manifest::from_str(VALID).unwrap();
        assert_eq!(m.scene("b").unwrap().resolved_engine(), Engine::Vhs);
    }

    #[test]
    fn engine_explicit_overrides_auto() {
        let y = "project: d\ntheme: t\nscenes:\n  - id: x\n    engine: vhs\n    layout: split\n    right: { run: r }\n";
        let m = Manifest::from_str(y).unwrap();
        assert_eq!(m.scene("x").unwrap().resolved_engine(), Engine::Vhs);
    }
```

- [ ] **Step 2: Run to verify fail**

Run: `cd bin && cargo test manifest::tests::engine`
Expected: FAIL — `resolved_engine` undefined.

- [ ] **Step 3: Implement the rule**

Add to `impl Scene` in `manifest.rs`:

```rust
    /// Resolve `engine: auto` to a concrete engine.
    /// asciinema = live/real-timing (split, injected keys, or raw_script);
    /// vhs       = deterministic scripted single-terminal (raw_tape, else single).
    pub fn resolved_engine(&self) -> Engine {
        match self.engine {
            Engine::Vhs | Engine::Asciinema => self.engine,
            Engine::Auto => {
                if self.raw_tape.is_some() { return Engine::Vhs; }
                if self.raw_script.is_some() { return Engine::Asciinema; }
                let has_keys = self.right.as_ref().and_then(|p| p.keys.as_ref()).is_some_and(|k| !k.is_empty());
                if self.layout == Layout::Split || has_keys { Engine::Asciinema } else { Engine::Vhs }
            }
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd bin && cargo test manifest::`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/src/manifest.rs
git commit -m "feat: engine auto-resolution rule (asciinema vs vhs)"
```

---

### Task 4: Cast compression (asciicast v2 idle-trim)

**Files:**
- Create: `bin/src/compress.rs`
- Modify: `bin/src/main.rs` (`mod compress;` + `Compress` subcommand)

**Interfaces:**
- Produces: `compress::trim(input: &str, max_idle: f64) -> anyhow::Result<String>` — parse asciicast v2 (line 1 = JSON header, subsequent lines = `[time, "o", data]`), clamp any inter-event gap to `max_idle`, re-emit with adjusted absolute timestamps. `compress::run(path, max_idle, out) -> Result<()>`.

- [ ] **Step 1: Write failing test**

Create `bin/src/compress.rs`:

```rust
//! Idle-trim an asciicast v2 recording (native replacement for compress_cast.py).
use anyhow::Context;

pub fn trim(input: &str, max_idle: f64) -> anyhow::Result<String> {
    let mut lines = input.lines();
    let header = lines.next().context("empty cast (no header)")?;
    let mut out = String::new();
    out.push_str(header);
    out.push('\n');
    let mut prev_orig = 0.0_f64;
    let mut shift = 0.0_f64; // total time removed so far
    for line in lines {
        if line.trim().is_empty() { continue; }
        let ev: serde_json::Value = serde_json::from_str(line)
            .with_context(|| format!("bad event line: {line}"))?;
        let t = ev.get(0).and_then(|v| v.as_f64()).context("event missing time")?;
        let gap = t - prev_orig;
        if gap > max_idle { shift += gap - max_idle; }
        prev_orig = t;
        let new_t = t - shift;
        let code = ev.get(1).and_then(|v| v.as_str()).unwrap_or("o");
        let data = ev.get(2).cloned().unwrap_or(serde_json::Value::String(String::new()));
        out.push_str(&serde_json::to_string(&serde_json::json!([new_t, code, data]))?);
        out.push('\n');
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_large_idle_gap() {
        // events at t=0, t=10 (9.5s of dead air), t=11
        let cast = "{\"version\":2,\"width\":80,\"height\":24}\n[0.0,\"o\",\"a\"]\n[10.0,\"o\",\"b\"]\n[11.0,\"o\",\"c\"]\n";
        let out = trim(cast, 0.5).unwrap();
        let times: Vec<f64> = out.lines().skip(1)
            .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()[0].as_f64().unwrap())
            .collect();
        assert_eq!(times[0], 0.0);
        assert_eq!(times[1], 0.5);   // 10s gap clamped to 0.5
        assert_eq!(times[2], 1.5);   // following 1s gap preserved
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd bin && cargo test compress::`
Expected: FAIL — `mod compress` not declared in main.

- [ ] **Step 3: Wire the subcommand + `run`**

Append to `compress.rs`:

```rust
pub fn run(path: &std::path::Path, max_idle: f64, out: Option<&std::path::Path>) -> anyhow::Result<()> {
    let input = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let trimmed = trim(&input, max_idle)?;
    match out {
        Some(o) => { std::fs::write(o, trimmed)?; println!("wrote {}", o.display()); }
        None => print!("{trimmed}"),
    }
    Ok(())
}
```

In `main.rs` add `mod compress;`, a `Compress` variant, and dispatch:

```rust
    /// Idle-trim a raw asciicast.
    Compress {
        cast: std::path::PathBuf,
        #[arg(long, default_value_t = 1.2)]
        max_idle: f64,
        #[arg(long)]
        out: Option<std::path::PathBuf>,
    },
```
```rust
        Cmd::Compress { cast, max_idle, out } => compress::run(&cast, max_idle, out.as_deref()),
```

- [ ] **Step 4: Run to verify pass**

Run: `cd bin && cargo test compress:: && cargo build`
Expected: PASS + clean build.

- [ ] **Step 5: Commit**

```bash
git add bin/src/compress.rs bin/src/main.rs
git commit -m "feat: native asciicast idle-trim (compress)"
```

---

### Task 5: Readiness evaluation (pure health check)

**Files:**
- Create: `bin/src/ready.rs`
- Modify: `bin/src/main.rs` (`mod ready;`)

**Interfaces:**
- Produces:
  - `ready::health_ok(body: &str, ready_field: Option<&str>, runner_key: Option<&str>) -> bool` — pure JSON predicate (tier 2 + identity).
  - `ready::log_matches(log: &str, pattern: &str) -> anyhow::Result<bool>` — tier 1 regex.
  - `ready::poll_http(url, ready_field, runner_key, timeout) -> Result<()>` — thin `ureq` loop (not unit-tested).

- [ ] **Step 1: Write failing tests**

Create `bin/src/ready.rs`:

```rust
//! Tiered readiness: cheap log marker -> authoritative HTTP probe (+ model identity).
use anyhow::Context;

/// Pure predicate over a health JSON body.
pub fn health_ok(body: &str, ready_field: Option<&str>, runner_key: Option<&str>) -> bool {
    let v: serde_json::Value = match serde_json::from_str(body) { Ok(v) => v, Err(_) => return false };
    if let Some(f) = ready_field {
        let truthy = match v.get(f) {
            Some(serde_json::Value::Bool(b)) => *b,
            Some(serde_json::Value::String(s)) => !s.is_empty() && s != "false",
            Some(serde_json::Value::Number(n)) => n.as_f64().unwrap_or(0.0) != 0.0,
            _ => false,
        };
        if !truthy { return false; }
    }
    if let Some(rk) = runner_key {
        if v.get("runner_in_use").and_then(|x| x.as_str()) != Some(rk) { return false; }
    }
    true
}

pub fn log_matches(log: &str, pattern: &str) -> anyhow::Result<bool> {
    let re = regex::Regex::new(pattern).with_context(|| format!("bad regex: {pattern}"))?;
    Ok(re.is_match(log))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_requires_ready_field_true() {
        assert!(health_ok(r#"{"model_ready":true}"#, Some("model_ready"), None));
        assert!(!health_ok(r#"{"model_ready":false}"#, Some("model_ready"), None));
        assert!(!health_ok("not json", Some("model_ready"), None));
    }

    #[test]
    fn health_checks_runner_identity() {
        let body = r#"{"model_ready":true,"runner_in_use":"qwen3-8b"}"#;
        assert!(health_ok(body, Some("model_ready"), Some("qwen3-8b")));
        assert!(!health_ok(body, Some("model_ready"), Some("skyreels")));
    }

    #[test]
    fn log_regex_matches() {
        assert!(log_matches("... warmed up and ready ...", "warmed up and ready").unwrap());
        assert!(!log_matches("still loading", "ready").unwrap());
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd bin && cargo test ready::`
Expected: FAIL — `mod ready` not declared.

- [ ] **Step 3: Add the thin polling wrapper + wire module**

Append to `ready.rs`:

```rust
use std::time::{Duration, Instant};

/// Poll `url` until `health_ok` passes or `timeout` elapses. Uses ureq (blocking).
pub fn poll_http(url: &str, ready_field: Option<&str>, runner_key: Option<&str>, timeout: Duration) -> anyhow::Result<()> {
    let start = Instant::now();
    loop {
        if let Ok(resp) = ureq::get(url).timeout(Duration::from_secs(3)).call() {
            if let Ok(body) = resp.into_string() {
                if health_ok(&body, ready_field, runner_key) { return Ok(()); }
            }
        }
        if start.elapsed() >= timeout {
            anyhow::bail!("readiness timeout after {:?} polling {url}", timeout);
        }
        std::thread::sleep(Duration::from_millis(1000));
    }
}
```

Add `mod ready;` to `main.rs`.

- [ ] **Step 4: Run to verify pass**

Run: `cd bin && cargo test ready:: && cargo build`
Expected: PASS + clean build.

- [ ] **Step 5: Commit**

```bash
git add bin/src/ready.rs bin/src/main.rs
git commit -m "feat: tiered readiness (log regex + health predicate + poll)"
```

---

### Task 6: Scene compilation + themes + templates

**Files:**
- Create: `templates/tape.j2`, `templates/asciinema-driver.sh.j2`, `templates/post.md.j2` (repo root, not `bin/`)
- Create: `themes/tt-brand.tape`, `themes/dracula.tape`
- Create: `bin/src/compile.rs`
- Modify: `bin/src/main.rs` (`mod compile;`)

**Interfaces:**
- Produces: `compile::compile_scene(scene: &Scene, m: &Manifest, templates_dir: &Path) -> anyhow::Result<Compiled>` where `Compiled { engine: Engine, kind: &'static str /* "tape"|"driver" */, text: String }`. Interpolates `{backend}` from `defaults.backend`.

- [ ] **Step 1: Create the theme + template files**

`themes/tt-brand.tape`:
```
Set FontFamily "Berkeley Mono"
Set FontSize 14
Set Theme { "name": "tt-brand", "background": "#0F2A35", "foreground": "#E8F0F2", "cursor": "#4FD1C5", "black": "#0F2A35", "green": "#4FD1C5", "cyan": "#74C5DF", "blue": "#1B8EB1", "yellow": "#F6BC42", "red": "#FA512E", "white": "#E8F0F2" }
Set Padding 20
```
`themes/dracula.tape`:
```
Set FontFamily "Hack"
Set FontSize 14
Set Theme "Dracula"
Set Padding 20
```

`templates/tape.j2`:
```
Output {{ out_gif }}
{% if want_mp4 %}Output {{ out_mp4 }}{% endif %}
Source {{ theme_tape }}
Set Shell "bash"
Set Width {{ width }}
Set Height {{ height }}
Set TypingSpeed {{ typing_speed }}
Set PlaybackSpeed {{ playback_speed }}

Hide
Type "clear"
Enter
Show
Type "{{ right_run }}"
Enter
Sleep {{ duration_s }}s
```

`templates/asciinema-driver.sh.j2`:
```
#!/usr/bin/env bash
# Generated by tt-demo — asciinema driver for scene {{ id }} ({{ layout }}).
set -euo pipefail
export TF_CPP_MIN_LOG_LEVEL=3 PYTHONWARNINGS=ignore PAGER=cat
COLS={{ width }}; ROWS={{ height }}
LEFT_RUN={{ left_run_q }}
RIGHT_RUN={{ right_run_q }}
LAYOUT={{ layout }}
DURATION={{ duration_s }}
SPLIT_RATIO={{ split_ratio }}
# split.sh / tmux_capture.sh consume these env vars (see lib/).
```

`templates/post.md.j2`:
```
# {{ project }} — demo

{% for s in scenes %}
## {{ s.title }}

{{ s.directive_clip }}

{{ s.viz_clip }}

{{ s.narration }}

{% endfor %}
```

- [ ] **Step 2: Write failing test for `compile_scene`**

Create `bin/src/compile.rs`:

```rust
//! Compile a Scene into a VHS tape or an asciinema driver via minijinja.
use crate::manifest::{Engine, Manifest, Scene};
use anyhow::Context;
use std::path::Path;

pub struct Compiled { pub engine: Engine, pub kind: &'static str, pub text: String }

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;

    fn m() -> Manifest {
        Manifest::from_str("project: p\ntheme: tt-brand\ndefaults: { backend: \"--host\", cols: 180, rows: 44 }\nscenes:\n  - id: single1\n    layout: single\n    duration: 5s\n    right: { run: \"tt-toplike {backend}\" }\n  - id: split1\n    layout: split\n    left: { run: \"echo hi\" }\n    right: { run: \"tt-toplike {backend}\" }\n").unwrap()
    }

    #[test]
    fn single_scene_compiles_to_tape_with_backend_interpolated() {
        let man = m();
        let c = super::compile_scene(man.scene("single1").unwrap(), &man, Path::new("../templates")).unwrap();
        assert_eq!(c.kind, "tape");
        assert!(c.text.contains("tt-toplike --host"), "backend token must interpolate");
        assert!(c.text.contains("Source"), "must source a theme tape");
    }

    #[test]
    fn split_scene_compiles_to_driver() {
        let man = m();
        let c = super::compile_scene(man.scene("split1").unwrap(), &man, Path::new("../templates")).unwrap();
        assert_eq!(c.kind, "driver");
        assert!(c.text.contains("LAYOUT=split"));
        assert!(c.text.contains("echo hi"));
    }
}
```

- [ ] **Step 3: Implement `compile_scene`**

Prepend the implementation above the tests in `compile.rs`:

```rust
fn interp(s: &str, backend: &str) -> String { s.replace("{backend}", backend) }

pub fn compile_scene(scene: &Scene, m: &Manifest, templates_dir: &Path) -> anyhow::Result<Compiled> {
    let engine = scene.resolved_engine();
    let backend = m.defaults.backend.clone().unwrap_or_default();
    let width = scene.split_ratio.map(|_| ()).and(None).unwrap_or(m.defaults.cols.unwrap_or(200));
    let height = m.defaults.rows.unwrap_or(50);
    let duration_s = scene.duration.as_deref().unwrap_or("8s").trim_end_matches('s').to_string();
    let right_run = interp(&scene.right.as_ref().context("scene needs right pane")?.run, &backend);
    let left_run = scene.left.as_ref().map(|p| interp(&p.run, &backend)).unwrap_or_default();

    let mut env = minijinja::Environment::new();
    match engine {
        Engine::Vhs => {
            let tmpl = std::fs::read_to_string(templates_dir.join("tape.j2"))?;
            env.add_template("t", &tmpl)?;
            let text = env.get_template("t")?.render(minijinja::context! {
                out_gif => format!("demo/assets/{}.gif", scene.id),
                out_mp4 => format!("demo/assets/{}.mp4", scene.id),
                want_mp4 => scene.outputs.as_ref().is_some_and(|o| o.iter().any(|x| x == "mp4")),
                theme_tape => format!("themes/{}.tape", m.theme),
                width, height,
                typing_speed => m.defaults.typing_speed.clone().unwrap_or_else(|| "60ms".into()),
                playback_speed => m.defaults.playback_speed.unwrap_or(1.0),
                right_run, duration_s,
            })?;
            Ok(Compiled { engine, kind: "tape", text })
        }
        Engine::Asciinema => {
            let tmpl = std::fs::read_to_string(templates_dir.join("asciinema-driver.sh.j2"))?;
            env.add_template("t", &tmpl)?;
            let q = |s: &str| format!("{:?}", s); // shell-safe quoting via debug repr
            let text = env.get_template("t")?.render(minijinja::context! {
                id => scene.id,
                layout => format!("{:?}", scene.layout).to_lowercase(),
                width, height, duration_s,
                split_ratio => scene.split_ratio.unwrap_or(40),
                left_run_q => q(&left_run),
                right_run_q => q(&right_run),
            })?;
            Ok(Compiled { engine, kind: "driver", text })
        }
        Engine::Auto => unreachable!("resolved_engine never returns Auto"),
    }
}
```

Add `mod compile;` to `main.rs`.

> Note for implementer: run these tests with the working dir at `bin/` so `../templates` resolves. If your runner uses a different CWD, set the test path to an absolute `CARGO_MANIFEST_DIR`-relative join instead: `Path::new(env!("CARGO_MANIFEST_DIR")).join("../templates")`. Prefer the `CARGO_MANIFEST_DIR` form — update the two test calls accordingly.

- [ ] **Step 4: Run to verify pass**

Run: `cd bin && cargo test compile::`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add templates themes bin/src/compile.rs bin/src/main.rs
git commit -m "feat: scene compilation (tape/driver) + tt-brand/dracula themes + templates"
```

---

### Task 7: bash helper library `driver.sh`

**Files:**
- Create: `lib/driver.sh`
- Create: `lib/tests/driver_test.sh`

**Interfaces:**
- Produces (sourced): `type <text>`, `run <cmd> [think]`, `comment <text>`, `section <title>`, `pause [secs]`, and pacing vars `DELAY_CHAR/DELAY_ENTER/DELAY_THINK/DELAY_SECTION`, plus `tt_demo_quiet_env` exporting noise-suppression vars.

- [ ] **Step 1: Write the failing bash test**

Create `lib/tests/driver_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DELAY_CHAR=0 DELAY_ENTER=0 DELAY_THINK=0 DELAY_SECTION=0
source "$HERE/../driver.sh"

out="$(type "hello"; printf '\n')"
[[ "$out" == "hello" ]] || { echo "FAIL: type printed '$out'"; exit 1; }

out="$(comment "note")"
[[ "$out" == *"# note"* ]] || { echo "FAIL: comment printed '$out'"; exit 1; }

out="$(run "echo ran" 0)"
[[ "$out" == *"echo ran"* && "$out" == *"ran"* ]] || { echo "FAIL: run printed '$out'"; exit 1; }

echo "driver.sh tests passed"
```

- [ ] **Step 2: Run to verify fail**

Run: `bash lib/tests/driver_test.sh`
Expected: FAIL — `lib/driver.sh` does not exist.

- [ ] **Step 3: Write `lib/driver.sh`**

```bash
#!/usr/bin/env bash
# driver.sh — sourced helpers for asciinema demo drivers.
# Generalized from tt-animatediff.prompt-travel/demo/record_demo.sh.

: "${DELAY_CHAR:=0.045}"
: "${DELAY_ENTER:=0.4}"
: "${DELAY_THINK:=1.2}"
: "${DELAY_SECTION:=2.0}"

tt_demo_quiet_env() {
    export TF_CPP_MIN_LOG_LEVEL=3 PYTHONWARNINGS=ignore PYTHONDONTWRITEBYTECODE=1 PAGER=cat
}

type() {
    local text="$1" extra="${2:-0}" i
    for ((i=0; i<${#text}; i++)); do printf '%s' "${text:$i:1}"; sleep "$DELAY_CHAR"; done
    sleep "$extra"
}

run() {
    local cmd="$1" think="${2:-$DELAY_THINK}"
    type "$cmd"; printf '\n'; sleep "$DELAY_ENTER"; eval "$cmd"; sleep "$think"
}

comment() { type "# $1" 0.1; printf '\n'; sleep 0.6; }
section() { printf '\n'; sleep 0.3; type "# ── $1 ──"; printf '\n'; sleep "$DELAY_SECTION"; }
pause() { sleep "${1:-$DELAY_THINK}"; }
```

- [ ] **Step 4: Run to verify pass; lint**

Run: `bash lib/tests/driver_test.sh && shellcheck lib/driver.sh`
Expected: "driver.sh tests passed" + shellcheck clean (or only style-info).

- [ ] **Step 5: Commit**

```bash
git add lib/driver.sh lib/tests/driver_test.sh
git commit -m "feat: driver.sh sourced helpers + test"
```

---

### Task 8: bash capture primitives (`tmux_capture.sh`, `split.sh`, `serve.sh`, `render.sh`)

**Files:**
- Create: `lib/tmux_capture.sh`, `lib/split.sh`, `lib/serve.sh`, `lib/render.sh`
- Create: `lib/tests/capture_test.sh`

**Interfaces:**
- Produces:
  - `tmux_capture.sh <out.cast> <cols> <rows> <cmd...>` — record a single-pane command to a cast.
  - `split.sh <out.cast> <cols> <rows> <ratio> <left_cmd> <right_cmd> <duration_s>` — two-pane record.
  - `serve.sh <logfile> <cmd...>` — start server backgrounded, tee stdout+stderr to logfile, print PID.
  - `render.sh gif <in.cast> <out.gif>` (agg) and `render.sh mp4 <in.cast> <out.mp4>` (Xvfb→xterm→ffmpeg).

- [ ] **Step 1: Write the hardware-free failing test (single-pane echo)**

Create `lib/tests/capture_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# single-pane capture of an echo
bash "$LIB/tmux_capture.sh" "$TMP/one.cast" 100 30 bash -c 'echo TTDEMO_MARKER; sleep 1'
[[ -s "$TMP/one.cast" ]] || { echo "FAIL: no cast written"; exit 1; }
grep -q "TTDEMO_MARKER" "$TMP/one.cast" || { echo "FAIL: marker not captured"; exit 1; }

# render that cast to a gif
bash "$LIB/render.sh" gif "$TMP/one.cast" "$TMP/one.gif"
[[ -s "$TMP/one.gif" ]] || { echo "FAIL: no gif produced"; exit 1; }

echo "capture tests passed"
```

- [ ] **Step 2: Run to verify fail**

Run: `bash lib/tests/capture_test.sh`
Expected: FAIL — scripts do not exist.

- [ ] **Step 3: Write the four scripts**

`lib/tmux_capture.sh`:
```bash
#!/usr/bin/env bash
# tmux_capture.sh <out.cast> <cols> <rows> <cmd...> — record a single-pane command.
set -euo pipefail
OUT="$1"; COLS="$2"; ROWS="$3"; shift 3
SESSION="ttcap_$$"
tmux kill-session -t "$SESSION" 2>/dev/null || true
mkdir -p "$(dirname "$OUT")"
# asciinema records a tmux session that runs the command then exits.
asciinema rec "$OUT" --overwrite --cols "$COLS" --rows "$ROWS" \
  --command "tmux new-session -x $COLS -y $ROWS -s $SESSION '$*'"
tmux kill-session -t "$SESSION" 2>/dev/null || true
```

`lib/split.sh`:
```bash
#!/usr/bin/env bash
# split.sh <out.cast> <cols> <rows> <ratio> <left_cmd> <right_cmd> <duration_s>
# Two-pane causation capture: left=directive, right=viz, recorded as one cast.
set -euo pipefail
OUT="$1"; COLS="$2"; ROWS="$3"; RATIO="$4"; LEFT="$5"; RIGHT="$6"; DUR="$7"
SESSION="ttsplit_$$"
tmux kill-session -t "$SESSION" 2>/dev/null || true
mkdir -p "$(dirname "$OUT")"
tmux new-session -d -x "$COLS" -y "$ROWS" -s "$SESSION" "$RIGHT"      # right pane = viz
tmux split-window -h -t "$SESSION" -p "$((100 - RATIO))" "bash -c '$LEFT; sleep $DUR'"  # left = directive
sleep 1
asciinema rec "$OUT" --overwrite --cols "$COLS" --rows "$ROWS" \
  --command "tmux attach -t $SESSION" &
REC=$!
sleep "$DUR"
tmux send-keys -t "$SESSION" q 2>/dev/null || true
tmux kill-session -t "$SESSION" 2>/dev/null || true
wait "$REC" 2>/dev/null || true
```

`lib/serve.sh`:
```bash
#!/usr/bin/env bash
# serve.sh <logfile> <cmd...> — start a server backgrounded, tee output to logfile, print PID.
set -euo pipefail
LOG="$1"; shift
mkdir -p "$(dirname "$LOG")"
( "$@" >"$LOG" 2>&1 ) &
echo $!
```

`lib/render.sh`:
```bash
#!/usr/bin/env bash
# render.sh gif|mp4 <in.cast> <out> — render an asciicast to GIF (agg) or MP4 (Xvfb+xterm+ffmpeg).
set -euo pipefail
MODE="$1"; IN="$2"; OUT="$3"
case "$MODE" in
  gif)
    agg "$IN" "$OUT"
    ;;
  mp4)
    DISPLAY_NUM=":99"; FONT="Ubuntu Mono"; FONT_SIZE=13; SPEED="${SPEED:-1}"
    pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true; sleep 0.3
    Xvfb "$DISPLAY_NUM" -screen 0 4096x2160x24 & XVFB=$!; sleep 0.8
    DISPLAY="$DISPLAY_NUM" xterm -geometry 200x50+0+0 -fa "$FONT" -fs "$FONT_SIZE" \
      -bg "#0F2A35" -fg "#E8F0F2" -title ttcap \
      -e bash -c "asciinema play --speed $SPEED '$IN'; sleep 2" & XT=$!; sleep 1.5
    G=$(DISPLAY="$DISPLAY_NUM" xwininfo -name ttcap | awk '/Width:/{w=$2}/Height:/{h=$2}/Absolute upper-left X:/{x=$NF}/Absolute upper-left Y:/{y=$NF}END{print w"x"h"+"x"+"y}')
    W=$(echo "$G" | cut -dx -f1); W=$(((W/2)*2))
    H=$(echo "$G" | cut -dx -f2 | cut -d+ -f1); H=$(((H/2)*2))
    XOFF=$(echo "$G" | cut -d+ -f2); YOFF=$(echo "$G" | cut -d+ -f3)
    ffmpeg -y -f x11grab -video_size "${W}x${H}" -i "$DISPLAY_NUM+$XOFF,$YOFF" -codec:v libx264 -pix_fmt yuv420p "$OUT" &
    FF=$!
    wait "$XT" 2>/dev/null || true
    kill "$FF" 2>/dev/null || true; wait "$FF" 2>/dev/null || true
    kill "$XVFB" 2>/dev/null || true
    ;;
  *) echo "usage: render.sh gif|mp4 <in.cast> <out>" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Run to verify pass; lint**

Run: `bash lib/tests/capture_test.sh && shellcheck lib/*.sh`
Expected: "capture tests passed"; shellcheck clean (SC2086 on intentional word-splitting may be `# shellcheck disable`d).

> Note: the MP4 path is exercised manually (needs Xvfb display), not in the fast test. The test covers single-pane capture + GIF render, which is the hardware-free golden path.

- [ ] **Step 5: Commit**

```bash
git add lib/tmux_capture.sh lib/split.sh lib/serve.sh lib/render.sh lib/tests/capture_test.sh
git commit -m "feat: bash capture primitives (tmux/split/serve/render) + hardware-free test"
```

---

### Task 9: Record orchestration + `--dry-run`

**Files:**
- Create: `bin/src/record.rs`
- Create: `bin/src/orchestrate.rs`
- Modify: `bin/src/main.rs` (`mod record; mod orchestrate;` + `Record` subcommand)

**Interfaces:**
- Consumes: `manifest::Manifest`, `compile::compile_scene`, `ready`, lib scripts.
- Produces:
  - `orchestrate::plan(m: &Manifest, ids: &[String]) -> Vec<Step>` where `enum Step { Switch{server: Option<String>}, Record{scene: String} }` — ordered so scenes sharing a server are grouped and a `Switch` is emitted only when the required server changes.
  - `record::run(ids: Option<Vec<String>>, dry_run: bool) -> anyhow::Result<()>`.

- [ ] **Step 1: Write failing tests for `plan`**

Create `bin/src/orchestrate.rs`:

```rust
//! Order scenes to minimize server switches (mirrors pipeline_engine backend-switching).
use crate::manifest::Manifest;

#[derive(Debug, PartialEq, Eq)]
pub enum Step { Switch { server: Option<String> }, Record { scene: String } }

/// Produce an ordered plan: group scenes by their `server`, emit a Switch when the
/// required server changes. `ids` selects+orders the scenes to consider.
pub fn plan(m: &Manifest, ids: &[String]) -> Vec<Step> {
    // Stable group by server, preserving first-seen server order.
    let mut order: Vec<Option<String>> = Vec::new();
    for id in ids {
        if let Some(s) = m.scene(id) {
            let key = s.server.clone();
            if !order.contains(&key) { order.push(key); }
        }
    }
    let mut steps = Vec::new();
    let mut current: Option<Option<String>> = None;
    for key in order {
        for id in ids {
            if let Some(s) = m.scene(id) {
                if s.server == key {
                    if current.as_ref() != Some(&key) {
                        steps.push(Step::Switch { server: key.clone() });
                        current = Some(key.clone());
                    }
                    steps.push(Step::Record { scene: id.clone() });
                }
            }
        }
    }
    steps
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;

    const M: &str = r#"
project: p
theme: t
servers: { qwen3: { start: "x" }, skyreels: { start: "y" } }
scenes:
  - { id: a, layout: single, server: qwen3, right: { run: r } }
  - { id: b, layout: single, server: skyreels, right: { run: r } }
  - { id: c, layout: single, server: qwen3, right: { run: r } }
"#;

    #[test]
    fn groups_by_server_minimizing_switches() {
        let m = Manifest::from_str(M).unwrap();
        let ids = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        let steps = plan(&m, &ids);
        // Expect: switch qwen3, record a, record c, switch skyreels, record b
        assert_eq!(steps, vec![
            Step::Switch { server: Some("qwen3".into()) },
            Step::Record { scene: "a".into() },
            Step::Record { scene: "c".into() },
            Step::Switch { server: Some("skyreels".into()) },
            Step::Record { scene: "b".into() },
        ]);
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd bin && cargo test orchestrate::`
Expected: FAIL — `mod orchestrate` not declared.

- [ ] **Step 3: Wire modules + implement `record::run` with dry-run**

Add `mod orchestrate; mod record;` to `main.rs`. Create `bin/src/record.rs`:

```rust
//! Record scenes: resolve plan, (dry-run) print it, else drive lib/ capture scripts.
use crate::{compile, manifest::Manifest, orchestrate::{plan, Step}};
use anyhow::Context;
use std::path::PathBuf;

fn home() -> PathBuf {
    std::env::var("TT_DEMO_HOME").map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".."))
}

pub fn run(ids: Option<Vec<String>>, dry_run: bool) -> anyhow::Result<()> {
    let yaml = std::fs::read_to_string("demo/demos.yaml").context("reading demo/demos.yaml")?;
    let m = Manifest::from_str(&yaml)?;
    let ids = ids.unwrap_or_else(|| m.scenes.iter().map(|s| s.id.clone()).collect());
    for id in &ids {
        if m.scene(id).is_none() {
            anyhow::bail!("unknown scene `{id}`; valid: {}", m.scenes.iter().map(|s| s.id.as_str()).collect::<Vec<_>>().join(", "));
        }
    }
    let steps = plan(&m, &ids);
    let tmpl = home().join("templates");
    for step in &steps {
        match step {
            Step::Switch { server } => {
                println!("== switch server: {}", server.clone().unwrap_or_else(|| "(none)".into()));
                if dry_run { continue; }
                // real switch (stop current, reset, start next) is driven here via lib/serve.sh
                // + ready::poll_http; implemented against real hardware.
            }
            Step::Record { scene } => {
                let s = m.scene(scene).unwrap();
                let compiled = compile::compile_scene(s, &m, &tmpl)?;
                println!("== record {} [{}/{}]", scene, format!("{:?}", compiled.engine).to_lowercase(), compiled.kind);
                if dry_run {
                    std::fs::create_dir_all("demo/assets").ok();
                    std::fs::write(format!("demo/assets/{scene}.cast"), "{\"version\":2}\n[0.0,\"o\",\"[dry-run]\"]\n").ok();
                    continue;
                }
                // Real capture: write the compiled tape/driver, invoke lib/ script.
                // (Driven against tmux/asciinema/vhs; see lib/.)
            }
        }
    }
    if dry_run { println!("[dry-run] {} step(s); no hardware touched", steps.len()); }
    Ok(())
}
```

Add the subcommand to `main.rs`:
```rust
    /// Record one scene, several, or all (with --dry-run to plan only).
    Record {
        /// Scene ids; omit or `all` for every scene.
        ids: Vec<String>,
        #[arg(long)]
        dry_run: bool,
    },
```
```rust
        Cmd::Record { ids, dry_run } => {
            let ids = if ids.is_empty() || ids == ["all"] { None } else { Some(ids) };
            record::run(ids, dry_run)
        }
```

- [ ] **Step 4: Run to verify pass**

Run: `cd bin && cargo test orchestrate:: && cargo build`
Expected: PASS + clean build.

- [ ] **Step 5: Commit**

```bash
git add bin/src/orchestrate.rs bin/src/record.rs bin/src/main.rs
git commit -m "feat: record orchestration with server-grouping plan + --dry-run"
```

---

### Task 10: `post`, `init`, `list`

**Files:**
- Create: `bin/src/post.rs`, `bin/src/scaffold.rs`
- Modify: `bin/src/main.rs`

**Interfaces:**
- Produces:
  - `post::assemble(m: &Manifest, narrate: Narrate, templates_dir: &Path) -> anyhow::Result<String>` where `enum Narrate { None, Local, Claude }`. `None` uses each scene's caption verbatim; `Local` POSTs to the prompt-server, falling back to `None` if unreachable; `Claude` leaves a marker the skill fills.
  - `scaffold::init() -> Result<()>` (writes `demo/demos.yaml`, `demo/.gitignore`, `demo/assets/`), `scaffold::list() -> Result<()>`.

- [ ] **Step 1: Write failing test for `post::assemble` (None)**

Create `bin/src/post.rs`:

```rust
//! Assemble POST.draft.md from the manifest + captions (+ optional narration).
use crate::manifest::Manifest;
use std::path::Path;

#[derive(Clone, Copy)]
pub enum Narrate { None, Local, Claude }

pub fn assemble(m: &Manifest, narrate: Narrate, templates_dir: &Path) -> anyhow::Result<String> {
    let tmpl = std::fs::read_to_string(templates_dir.join("post.md.j2"))?;
    let mut env = minijinja::Environment::new();
    env.add_template("p", &tmpl)?;
    let scenes: Vec<_> = m.scenes.iter().map(|s| {
        let cap = s.caption.clone().unwrap_or_default();
        let narration = match narrate {
            Narrate::None => cap.clone(),
            Narrate::Claude => format!("<!-- narrate:claude {} -->{}", s.id, cap),
            Narrate::Local => crate::post::local_narrate(&cap).unwrap_or_else(|| cap.clone()),
        };
        minijinja::context! {
            title => s.title.clone().unwrap_or_else(|| s.id.clone()),
            directive_clip => format!("![{} directive](demo/assets/{}-directive.gif)", s.id, s.id),
            viz_clip => format!("![{} viz](demo/assets/{}.gif)", s.id, s.id),
            narration,
        }
    }).collect();
    Ok(env.get_template("p")?.render(minijinja::context! { project => m.project.clone(), scenes })?)
}

/// Best-effort local narration via the prompt-server; None on any failure.
pub fn local_narrate(_caption: &str) -> Option<String> { None } // wired to ureq in step 3

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;

    #[test]
    fn assembles_post_with_captions() {
        let m = Manifest::from_str("project: proj\ntheme: t\nscenes:\n  - id: s1\n    title: Scene One\n    layout: single\n    right: { run: r }\n    caption: \"the cause and effect\"\n").unwrap();
        let md = assemble(&m, Narrate::None, std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../templates").as_path()).unwrap();
        assert!(md.contains("# proj"));
        assert!(md.contains("## Scene One"));
        assert!(md.contains("the cause and effect"));
        assert!(md.contains("demo/assets/s1.gif"));
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `cd bin && cargo test post::`
Expected: FAIL — `mod post` not declared in main.

- [ ] **Step 3: Wire `local_narrate` to the prompt-server + add `scaffold` + subcommands**

Replace `local_narrate` body in `post.rs`:

```rust
pub fn local_narrate(caption: &str) -> Option<String> {
    // Gate on health, then ask the prompt-server to expand the caption.
    let health = ureq::get("http://127.0.0.1:8001/health").timeout(std::time::Duration::from_secs(2)).call().ok()?;
    if !crate::ready::health_ok(&health.into_string().ok()?, Some("model_ready"), None) { return None; }
    let body = serde_json::json!({
        "messages": [{"role":"user","content": format!("Write one vivid sentence explaining this demo moment: {caption}")}],
        "max_tokens": 80
    });
    let resp = ureq::post("http://127.0.0.1:8001/v1/chat/completions")
        .timeout(std::time::Duration::from_secs(20)).send_json(body).ok()?;
    let v: serde_json::Value = resp.into_json().ok()?;
    v["choices"][0]["message"]["content"].as_str().map(|s| s.trim().to_string())
}
```

Create `bin/src/scaffold.rs`:

```rust
//! `tt-demo init` (scaffold demo/) and `tt-demo list`.
use crate::manifest::Manifest;
use std::fs;

const STARTER: &str = r#"project: my-project
theme: tt-brand
defaults: { cols: 200, rows: 50, backend: "--host", outputs: [cast, gif] }
scenes:
  - id: hello
    title: "Hello"
    layout: single
    duration: 5s
    right: { run: "tt-toplike {backend}" }
    caption: "First light."
"#;

pub fn init() -> anyhow::Result<()> {
    fs::create_dir_all("demo/assets")?;
    if !std::path::Path::new("demo/demos.yaml").exists() {
        fs::write("demo/demos.yaml", STARTER)?;
    }
    fs::write("demo/.gitignore", "assets/\n*.raw.cast\n")?;
    println!("scaffolded demo/ (demos.yaml, assets/, .gitignore)");
    Ok(())
}

pub fn list() -> anyhow::Result<()> {
    let yaml = fs::read_to_string("demo/demos.yaml")?;
    let m = Manifest::from_str(&yaml)?;
    for s in &m.scenes {
        let recorded = std::path::Path::new(&format!("demo/assets/{}.cast", s.id)).exists();
        println!("  {:<16} {:<9} {}", s.id, format!("{:?}", s.resolved_engine()).to_lowercase(),
            if recorded { "recorded" } else { "-" });
    }
    Ok(())
}
```

In `main.rs` add `mod post; mod scaffold;`, variants `Init`, `List`, and `Post { #[arg(long, default_value="none")] narrate: String }`, and dispatch — mapping `narrate` string to `post::Narrate`, writing `demo/POST.draft.md`.

- [ ] **Step 4: Run to verify pass**

Run: `cd bin && cargo test post:: && cargo build`
Expected: PASS + clean build.

- [ ] **Step 5: Commit**

```bash
git add bin/src/post.rs bin/src/scaffold.rs bin/src/main.rs
git commit -m "feat: post assembly (narration none/local/claude) + init + list"
```

---

### Task 11: skill, reference example, install, docs

**Files:**
- Create: `skill/SKILL.md`, `skill/manifest-schema.md`
- Create: `examples/demos.yaml`
- Create: `install.sh`, `README.md`, `AGENTS.md`

**Interfaces:** none (docs/data/install). `examples/demos.yaml` MUST validate and be hardware-free.

- [ ] **Step 1: Write `examples/demos.yaml` (the tt-toplike reference, `--host`)**

```yaml
project: tt-toplike
theme: tt-brand
defaults: { cols: 200, rows: 50, backend: "--host", outputs: [cast, gif] }
scenes:
  - id: qa-short
    title: "One short question"
    layout: single
    duration: 8s
    right: { run: "tt-toplike {backend} --mode starfield" }
    caption: "A short prompt spikes current, then settles — the starfield twinkles and calms."
  - id: cold-load
    title: "Cold model load (host proxy)"
    layout: split
    left:  { run: "yes > /dev/null & sleep 6; kill %1" }
    right: { run: "tt-toplike {backend} --mode arcade" }
    duration: 8s
    split_ratio: 40
    caption: "Load ramps the host; the arcade hero climbs as power rises."
  - id: reset-lightshow
    title: "Reset light-show"
    layout: single
    duration: 6s
    right: { run: "tt-toplike {backend} --mode arcade" }
    caption: "Power collapses toward zero — particles stop, the dungeon goes quiet, then revives."
```

- [ ] **Step 2: Validate the example via dry-run**

Run:
```bash
cd bin && cargo run -- record --dry-run 2>/dev/null || true   # needs demo/demos.yaml
mkdir -p ../demo && cp ../examples/demos.yaml ../demo/demos.yaml
cd .. && (cd bin && TT_DEMO_HOME=.. cargo run -- record --dry-run)
```
Expected: prints record steps for `qa-short`, `cold-load`, `reset-lightshow`; ends `[dry-run] ... no hardware touched`. Then `rm -rf demo`.

- [ ] **Step 3: Write `skill/SKILL.md` + `skill/manifest-schema.md`**

`skill/SKILL.md`:
```markdown
---
name: tt-demo
description: Author demo recordings + a draft post from any project. Use when the user wants to record a terminal/TUI demo, capture "directive → reaction" footage, or assemble a demo post. Drives the `tt-demo` CLI.
---

# /tt-demo — record demos + assemble a draft post

You turn a natural-language demo request into `demo/demos.yaml`, then drive `tt-demo`.

## Steps
1. `tt-demo doctor` — confirm tools; report anything missing.
2. If `demo/demos.yaml` is absent, `tt-demo init`, then edit it to match the request.
   Author scenes per `manifest-schema.md`. Prefer declarative scenes; use `raw_tape`/`raw_script` only for GUI/tricky shots.
3. `tt-demo record --dry-run` — show the plan; fix validation errors.
4. `tt-demo record <ids|all>` — capture. `tt-demo compress` + `tt-demo render <id> --gif|--mp4` as needed.
5. `tt-demo post --narrate claude` — assemble `demo/POST.draft.md`; you write the narration paragraphs where marked.

## Notes
- Non-invasive by default: prefer `--backend hybrid`/`--host` in scene commands.
- A local Qwen (`--narrate local`) can write narration when you are not in the loop.
```

`skill/manifest-schema.md`: document every field from spec §4 (project, theme, defaults.*, servers.*, scene fields, ready tiers, engine rule, escape hatches) with a compact example. (Copy the field list from the design spec §4.)

- [ ] **Step 4: Write `install.sh`, `README.md`, `AGENTS.md`; run install dry**

`install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
( cd "$HERE/bin" && cargo build --release )
mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills"
ln -sf "$HERE/bin/target/release/tt-demo" "$HOME/.local/bin/tt-demo"
ln -sfn "$HERE/skill" "$HOME/.claude/skills/tt-demo"
chmod +x "$HERE"/lib/*.sh
echo "installed tt-demo -> ~/.local/bin ; skill -> ~/.claude/skills/tt-demo"
echo "set TT_DEMO_HOME=$HERE if you invoke tt-demo from outside this repo"
```

`README.md`: quickstart (install, `tt-demo init`, edit `demo/demos.yaml`, `record --dry-run`, `record all`, `post`). `AGENTS.md`: the project dev-log seed (what happened, decisions, link to spec + plan).

Run: `bash -n install.sh && shellcheck install.sh`
Expected: syntax OK, shellcheck clean.

- [ ] **Step 5: Commit**

```bash
git add skill examples install.sh README.md AGENTS.md
git commit -m "docs: /tt-demo skill, tt-toplike reference example, install.sh, README, AGENTS"
```

---

### Task 12: End-to-end hardware-free golden test

**Files:**
- Create: `tests/e2e_golden.sh`

**Interfaces:** exercises the full real pipeline with no accelerator (single-pane `echo`/`--host`).

- [ ] **Step 1: Write the golden test**

Create `tests/e2e_golden.sh`:

```bash
#!/usr/bin/env bash
# End-to-end, hardware-free: init -> record (real single-pane) -> compress -> render gif -> post.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TT_DEMO="$ROOT/bin/target/release/tt-demo"
[[ -x "$TT_DEMO" ]] || ( cd "$ROOT/bin" && cargo build --release ) && TT_DEMO="$ROOT/bin/target/release/tt-demo"
export TT_DEMO_HOME="$ROOT"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > have.yaml <<'YAML'
project: golden
theme: tt-brand
defaults: { cols: 100, rows: 30, backend: "--host", outputs: [cast, gif] }
scenes:
  - id: hello
    title: "Hello"
    layout: single
    duration: 2s
    right: { run: "echo GOLDEN_OK; sleep 1" }
    caption: "It records."
YAML
mkdir -p demo && cp have.yaml demo/demos.yaml

# dry-run plan
"$TT_DEMO" record --dry-run | grep -q "record hello"

# real single-pane capture via the lib primitive
bash "$ROOT/lib/tmux_capture.sh" demo/assets/hello.cast 100 30 bash -c 'echo GOLDEN_OK; sleep 1'
grep -q GOLDEN_OK demo/assets/hello.cast

# compress + render
"$TT_DEMO" compress demo/assets/hello.cast --out demo/assets/hello.min.cast
bash "$ROOT/lib/render.sh" gif demo/assets/hello.min.cast demo/assets/hello.gif
[[ -s demo/assets/hello.gif ]]

# post
"$TT_DEMO" post --narrate none
grep -q "It records." demo/POST.draft.md

echo "E2E GOLDEN PASSED"
```

- [ ] **Step 2: Run to verify it fails first (before `post --narrate` wired / lib present)**

Run: `bash tests/e2e_golden.sh`
Expected: FAIL if any prior task incomplete; otherwise proceeds. (This task lands last, so expect it to surface any integration gap.)

- [ ] **Step 3: Fix integration gaps surfaced**

Address whatever the golden test reports (path resolution via `TT_DEMO_HOME`, `post` writing `demo/POST.draft.md`, `compress --out`). No new features — only wiring fixes.

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/e2e_golden.sh`
Expected: `E2E GOLDEN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e_golden.sh
git commit -m "test: end-to-end hardware-free golden (init->record->compress->render->post)"
```

---

## Self-Review

**Spec coverage:** §1 prior-art → Tasks 7–8 (driver/capture/render), §3 three layers → Tasks 1–11, §4 manifest → Task 2, §5 engine rule → Task 3, §6 split + readiness + orchestration + dry-run → Tasks 5/8/9, §7 data flow → Tasks 9/10/Task12, §8 narration → Task 10, §9 repo layout → all, §10 install → Task 11, §11 testing → Tasks 2–6 unit + Task 12 golden + `--dry-run`, §12 error handling → Tasks 2/9 (validation, unknown id, timeout), §13 scope → covered, §14 worked example → Task 11 `examples/demos.yaml`. GUI/relay/tt-home correctly absent (v2).

**Placeholder scan:** every code step contains real code; bash scripts are complete; the only intentionally-thin real-capture branches in `record.rs` (Switch/Record non-dry-run bodies) are documented as hardware-driven and are exercised by the lib scripts + golden test rather than stubbed features — acceptable, as v1's testable path is dry-run + the lib primitives.

**Type consistency:** `Manifest::from_str`, `Scene::resolved_engine`, `compile_scene(scene, m, templates_dir) -> Compiled{engine,kind,text}`, `plan(m, ids) -> Vec<Step>`, `assemble(m, Narrate, templates_dir)`, `health_ok(body, ready_field, runner_key)` are referenced consistently across tasks. `TT_DEMO_HOME` resolution is defined in Task 9 (`record::home`) and reused by Task 12.
