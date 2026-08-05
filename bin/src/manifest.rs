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
    // Parsed from the manifest but not yet consulted by record/compile — a scene's own
    // `outputs:` field is what's actually read today (see compile.rs). Reserved for v1.1
    // (a project-wide output-format default with no per-scene override).
    #[allow(dead_code)]
    pub outputs: Option<Vec<String>>,
    // Parsed but not yet threaded into the VHS template — reserved for v1.1 (VHS theme
    // padding is currently fixed by the theme .tape file itself, not by this default).
    #[allow(dead_code)]
    pub padding: Option<u16>,
    pub typing_speed: Option<String>,
    pub playback_speed: Option<f32>,
    /// Encoding options for `tt-demo render` (see RenderOpts).
    #[serde(default)]
    pub render: Option<RenderOpts>,
}

/// GIF/artifact encoding knobs consumed by `tt-demo render` (agg flags).
/// All optional; omitted fields fall back to agg's own defaults.
#[derive(Debug, Default, Deserialize)]
pub struct RenderOpts {
    /// agg --fps-cap: cap frames/second (biggest GIF size lever for animated TUIs).
    pub fps_cap: Option<u16>,
    /// agg --font-size: pixel size of the rendered glyphs (smaller = smaller file).
    pub font_size: Option<u16>,
    /// agg --speed: playback speed multiplier.
    pub speed: Option<f32>,
}

#[derive(Debug, Deserialize)]
pub struct ServerDef {
    pub start: String,
    // Parsed but not yet invoked by record.rs — switching servers today only ever starts
    // the next one (see the `TODO(v1.1)` in record.rs's `Step::Switch` handling). Reserved
    // for v1.1's stop-prior-server + board-reset path.
    #[allow(dead_code)]
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
        if let Some(r) = &self.defaults.render {
            if r.fps_cap == Some(0) {
                anyhow::bail!("defaults.render.fps_cap must be >= 1");
            }
            if r.font_size == Some(0) {
                anyhow::bail!("defaults.render.font_size must be >= 1");
            }
            if let Some(s) = r.speed {
                if !(s.is_finite() && s > 0.0) {
                    anyhow::bail!("defaults.render.speed must be a positive number");
                }
            }
        }
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
    fn parses_render_defaults() {
        let y = "project: d\ntheme: t\ndefaults: { render: { fps_cap: 10, font_size: 12, speed: 1.25 } }\nscenes:\n  - id: x\n    right: { run: r }\n";
        let m = Manifest::from_str(y).unwrap();
        let r = m.defaults.render.as_ref().unwrap();
        assert_eq!(r.fps_cap, Some(10));
        assert_eq!(r.font_size, Some(12));
        assert_eq!(r.speed, Some(1.25));
    }

    #[test]
    fn render_defaults_absent_is_none() {
        let m = Manifest::from_str(VALID).unwrap();
        assert!(m.defaults.render.is_none());
    }

    #[test]
    fn rejects_zero_fps_cap_and_nonpositive_speed() {
        let y = "project: d\ntheme: t\ndefaults: { render: { fps_cap: 0 } }\nscenes:\n  - id: x\n    right: { run: r }\n";
        assert!(Manifest::from_str(y).unwrap_err().to_string().contains("fps_cap"));
        let y2 = "project: d\ntheme: t\ndefaults: { render: { speed: 0.0 } }\nscenes:\n  - id: x\n    right: { run: r }\n";
        assert!(Manifest::from_str(y2).unwrap_err().to_string().contains("speed"));
    }

    #[test]
    fn engine_explicit_overrides_auto() {
        let y = "project: d\ntheme: t\nscenes:\n  - id: x\n    engine: vhs\n    layout: split\n    right: { run: r }\n";
        let m = Manifest::from_str(y).unwrap();
        assert_eq!(m.scene("x").unwrap().resolved_engine(), Engine::Vhs);
    }
}
