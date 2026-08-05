//! Visual QA: tile evenly-spaced frames of a rendered artifact into a single
//! contact-sheet PNG (demo/assets/<id>.sheet.png) via lib/verify.sh.
use crate::manifest::Manifest;
use crate::record::home;
use anyhow::Context;
use std::path::{Path, PathBuf};

/// The rendered artifact to verify for `id`: prefer the GIF (what READMEs
/// embed), fall back to the MP4. None if neither has been rendered yet.
pub fn artifact_for(id: &str, assets_dir: &Path) -> Option<PathBuf> {
    let gif = assets_dir.join(format!("{id}.gif"));
    if gif.exists() {
        return Some(gif);
    }
    let mp4 = assets_dir.join(format!("{id}.mp4"));
    if mp4.exists() {
        return Some(mp4);
    }
    None
}

/// `tt-demo verify <id> [--frames N]`: validate the scene exists, then tile N
/// evenly-spaced frames of its rendered artifact into demo/assets/<id>.sheet.png.
pub fn run(id: &str, frames: u32) -> anyhow::Result<()> {
    if frames == 0 {
        anyhow::bail!("--frames must be >= 1");
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
    let artifact = artifact_for(id, &assets_dir).with_context(|| {
        format!("no rendered artifact for scene `{id}`; run `tt-demo render {id} --gif` first")
    })?;
    let out = assets_dir.join(format!("{id}.sheet.png"));

    let status = std::process::Command::new("bash")
        .arg(home().join("lib/verify.sh"))
        .arg(&artifact)
        .arg(&out)
        .arg(frames.to_string())
        .status()
        .context("spawning lib/verify.sh")?;
    if !status.success() {
        anyhow::bail!(
            "verify.sh failed for scene `{id}` (exit {})",
            status.code().map(|c| c.to_string()).unwrap_or_else(|| "signal".into())
        );
    }
    println!("wrote {}", out.display());
    println!("open it (or have your agent Read it) to check the footage frame-by-frame");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artifact_for_prefers_gif_over_mp4() {
        let dir = std::env::temp_dir().join(format!("tt-demo-verify-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        // Nothing rendered -> None.
        assert!(artifact_for("s", &dir).is_none());

        // Only mp4 -> mp4.
        std::fs::write(dir.join("s.mp4"), "x").unwrap();
        assert_eq!(artifact_for("s", &dir), Some(dir.join("s.mp4")));

        // gif appears -> prefer gif.
        std::fs::write(dir.join("s.gif"), "x").unwrap();
        assert_eq!(artifact_for("s", &dir), Some(dir.join("s.gif")));

        std::fs::remove_dir_all(&dir).ok();
    }
}
