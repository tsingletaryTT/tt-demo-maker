//! Compile a Scene into a VHS tape or an asciinema driver via minijinja.
use crate::manifest::{Engine, Manifest, Scene};
use anyhow::Context;
use std::path::Path;

pub struct Compiled {
    pub engine: Engine,
    pub kind: &'static str,
    // Rendered tape/driver text, produced (and unit-tested) here but not yet executed —
    // record.rs's real (non-dry-run) capture path drives the scene's raw `left`/`right` run
    // commands directly against the tested lib/ scripts instead. Reserved for v1.1: the
    // compiled-VHS-tape / asciinema-driver execution path.
    #[allow(dead_code)]
    pub text: String,
}

/// Interpolate the `{backend}` token. `pub(crate)` so `record.rs` can reuse the exact same
/// substitution when driving real (non-dry-run) capture — one definition, shared.
pub(crate) fn interp(s: &str, backend: &str) -> String { s.replace("{backend}", backend) }

pub fn compile_scene(scene: &Scene, m: &Manifest, templates_dir: &Path) -> anyhow::Result<Compiled> {
    let engine = scene.resolved_engine();
    let backend = m.defaults.backend.clone().unwrap_or_default();
    let width = m.defaults.cols.unwrap_or(200);
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
            // TODO(v1.1 capture-wiring): replace Debug-quote with real POSIX shell quoting
            // before executing compiled drivers.
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
        let templates_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../templates");
        let c = super::compile_scene(man.scene("single1").unwrap(), &man, templates_dir.as_path()).unwrap();
        assert_eq!(c.kind, "tape");
        assert!(c.text.contains("tt-toplike --host"), "backend token must interpolate");
        assert!(c.text.contains("Source"), "must source a theme tape");
    }

    #[test]
    fn split_scene_compiles_to_driver() {
        let man = m();
        let templates_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../templates");
        let c = super::compile_scene(man.scene("split1").unwrap(), &man, templates_dir.as_path()).unwrap();
        assert_eq!(c.kind, "driver");
        assert!(c.text.contains("LAYOUT=split"));
        assert!(c.text.contains("echo hi"));
    }
}
