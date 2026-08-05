//! Render a recorded scene's asciicast into a shareable artifact (GIF/MP4),
//! by shelling out to `lib/render.sh` (agg for GIF, Xvfb+xterm+ffmpeg for MP4).
use crate::manifest::Manifest;
use crate::record::home;
use anyhow::Context;
use std::path::{Path, PathBuf};

/// Resolve which cast file to render for `id` and what the output path should be.
///
/// Prefers `<id>.min.cast` (the idle-trimmed cast produced by `tt-demo compress`) over the
/// raw `<id>.cast` when both exist in `assets_dir`. `which` is the target format ("gif" |
/// "mp4") and becomes the output file's extension.
///
/// PURE aside from an `exists()` filesystem check — no process spawning, so it's safe and
/// fast to exercise directly in tests.
pub fn render_target(id: &str, which: &str, assets_dir: &Path) -> (PathBuf, PathBuf) {
    let min_cast = assets_dir.join(format!("{id}.min.cast"));
    let cast = if min_cast.exists() {
        min_cast
    } else {
        assets_dir.join(format!("{id}.cast"))
    };
    let out = assets_dir.join(format!("{id}.{which}"));
    (cast, out)
}

/// Environment pairs for lib/render.sh: the agg theme string (from
/// `themes/<theme>.agg` under TT_DEMO_HOME, if present) plus any
/// `defaults.render` encoding options. Missing theme file = no pair (agg
/// falls back to its default palette) — never an error, so themes without
/// an agg variant keep working.
pub fn agg_env(m: &Manifest, home: &Path) -> Vec<(String, String)> {
    let mut env = Vec::new();
    let theme_file = home.join("themes").join(format!("{}.agg", m.theme));
    if let Ok(s) = std::fs::read_to_string(&theme_file) {
        let s = s.trim();
        if !s.is_empty() {
            env.push(("AGG_THEME".to_string(), s.to_string()));
        }
    }
    if let Some(r) = &m.defaults.render {
        if let Some(f) = r.fps_cap { env.push(("AGG_FPS_CAP".to_string(), f.to_string())); }
        if let Some(f) = r.font_size { env.push(("AGG_FONT_SIZE".to_string(), f.to_string())); }
        if let Some(s) = r.speed { env.push(("AGG_SPEED".to_string(), s.to_string())); }
    }
    env
}

/// `tt-demo render <id> --gif|--mp4`: validate the scene exists, then invoke
/// `lib/render.sh <which> <in.cast> <out>` for each requested format.
pub fn run(id: &str, gif: bool, mp4: bool) -> anyhow::Result<()> {
    if !gif && !mp4 {
        anyhow::bail!("specify --gif and/or --mp4");
    }

    let yaml = std::fs::read_to_string("demo/demos.yaml").context("reading demo/demos.yaml")?;
    let m = Manifest::from_str(&yaml)?;
    if m.scene(id).is_none() {
        anyhow::bail!(
            "unknown scene `{id}`; valid: {}",
            m.scenes.iter().map(|s| s.id.as_str()).collect::<Vec<_>>().join(", ")
        );
    }

    let assets_dir = PathBuf::from("demo/assets");
    let script = home().join("lib/render.sh");
    let env = agg_env(&m, &home());

    let mut formats = Vec::new();
    if gif { formats.push("gif"); }
    if mp4 { formats.push("mp4"); }

    for which in formats {
        let (cast, out) = render_target(id, which, &assets_dir);
        if !cast.exists() {
            anyhow::bail!(
                "no cast found for scene `{id}` ({}); record it first with `tt-demo record {id}`",
                cast.display()
            );
        }
        println!("== render {id} -> {which} ({})", out.display());
        let status = std::process::Command::new("bash")
            .arg(&script)
            .arg(which)
            .arg(&cast)
            .arg(&out)
            .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .status()
            .with_context(|| format!("spawning {}", script.display()))?;
        if !status.success() {
            anyhow::bail!(
                "render.sh {which} failed for scene `{id}` (exit {})",
                status.code().map(|c| c.to_string()).unwrap_or_else(|| "signal".into())
            );
        }
        println!("wrote {}", out.display());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn render_target_prefers_min_cast() {
        let dir = std::env::temp_dir().join(format!("tt-demo-render-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        // Only the raw cast exists -> use it.
        std::fs::write(dir.join("s.cast"), "{}").unwrap();
        let (cast, out) = render_target("s", "gif", &dir);
        assert_eq!(cast, dir.join("s.cast"));
        assert_eq!(out, dir.join("s.gif"));

        // Once the compressed cast shows up too, prefer it.
        std::fs::write(dir.join("s.min.cast"), "{}").unwrap();
        let (cast, out) = render_target("s", "gif", &dir);
        assert_eq!(cast, dir.join("s.min.cast"));
        assert_eq!(out, dir.join("s.gif"));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn agg_env_includes_theme_and_render_opts() {
        // Fake home with a theme file for theme `tb`.
        let home = std::env::temp_dir().join(format!("tt-demo-aggenv-{}", std::process::id()));
        std::fs::create_dir_all(home.join("themes")).unwrap();
        std::fs::write(home.join("themes/tb.agg"), "0F2A35,E8F0F2,0F2A35\n").unwrap();

        let y = "project: d\ntheme: tb\ndefaults: { render: { fps_cap: 10, font_size: 12, speed: 1.25 } }\nscenes:\n  - id: x\n    right: { run: r }\n";
        let m = crate::manifest::Manifest::from_str(y).unwrap();
        let env = agg_env(&m, &home);
        assert!(env.contains(&("AGG_THEME".into(), "0F2A35,E8F0F2,0F2A35".into())));
        assert!(env.contains(&("AGG_FPS_CAP".into(), "10".into())));
        assert!(env.contains(&("AGG_FONT_SIZE".into(), "12".into())));
        assert!(env.contains(&("AGG_SPEED".into(), "1.25".into())));

        // Unknown theme file -> no AGG_THEME pair, no error.
        let y2 = "project: d\ntheme: ghost\nscenes:\n  - id: x\n    right: { run: r }\n";
        let m2 = crate::manifest::Manifest::from_str(y2).unwrap();
        let env2 = agg_env(&m2, &home);
        assert!(env2.iter().all(|(k, _)| k != "AGG_THEME"));

        std::fs::remove_dir_all(&home).ok();
    }
}
