//! Publish rendered demo artifacts: copy them from gitignored demo/assets/ into
//! a committed directory and emit a markdown gallery (optionally spliced into a
//! README between `<!-- tt-demo:gallery:begin/end -->` markers).
use crate::manifest::Manifest;
use crate::verify::artifact_for;
use anyhow::Context;
use std::path::{Path, PathBuf};

pub const BEGIN: &str = "<!-- tt-demo:gallery:begin -->";
pub const END: &str = "<!-- tt-demo:gallery:end -->";

/// Markdown gallery for published entries (scene id + repo-relative artifact
/// path): bold title (falling back to the id), caption sentence, image embed.
pub fn gallery_md(m: &Manifest, entries: &[(String, PathBuf)]) -> String {
    let mut md = String::new();
    for (id, path) in entries {
        let s = m.scene(id).expect("published entries come from the manifest");
        let title = s.title.as_deref().unwrap_or(id);
        md.push_str(&format!("**{title}**"));
        if let Some(c) = &s.caption {
            md.push_str(&format!(" — {c}"));
        }
        md.push_str(&format!("\n\n![{title}]({})\n\n", path.display()));
    }
    md
}

/// Replace the text between the gallery markers, keeping the markers so the
/// operation is repeatable. Errors when either marker is missing.
pub fn splice(readme: &str, block: &str) -> anyhow::Result<String> {
    let start = readme.find(BEGIN).context("README is missing the begin marker")?;
    let end = readme.find(END).context("README is missing the end marker")?;
    if end < start {
        anyhow::bail!("gallery markers are out of order");
    }
    let mut out = String::new();
    out.push_str(&readme[..start + BEGIN.len()]);
    out.push('\n');
    out.push_str(block.trim_end());
    out.push('\n');
    out.push_str(&readme[end..]);
    Ok(out)
}

/// `tt-demo publish [ids] [--dir media] [--readme README.md]`.
pub fn run(ids: Option<Vec<String>>, dir: &str, readme: Option<&Path>) -> anyhow::Result<()> {
    let yaml = std::fs::read_to_string("demo/demos.yaml").context("reading demo/demos.yaml")?;
    let m = Manifest::from_str(&yaml)?;
    let ids = ids.unwrap_or_else(|| m.scenes.iter().map(|s| s.id.clone()).collect());
    for id in &ids {
        if m.scene(id).is_none() {
            anyhow::bail!(
                "unknown scene `{id}`; valid: {}",
                m.scenes.iter().map(|s| s.id.as_str()).collect::<Vec<_>>().join(", ")
            );
        }
    }

    let assets_dir = PathBuf::from("demo/assets");
    std::fs::create_dir_all(dir).with_context(|| format!("creating {dir}/"))?;

    let mut entries = Vec::new();
    for id in &ids {
        match artifact_for(id, &assets_dir) {
            Some(src) => {
                let dest = Path::new(dir).join(src.file_name().unwrap());
                std::fs::copy(&src, &dest)
                    .with_context(|| format!("copying {} -> {}", src.display(), dest.display()))?;
                println!("published {}", dest.display());
                entries.push((id.clone(), dest));
            }
            None => println!("!! skipping `{id}` — no rendered artifact (run `tt-demo render {id} --gif`)"),
        }
    }
    if entries.is_empty() {
        anyhow::bail!("nothing published: no scene in the selection has a rendered artifact");
    }

    let block = gallery_md(&m, &entries);
    match readme {
        Some(r) => {
            let text = std::fs::read_to_string(r).with_context(|| format!("reading {}", r.display()))?;
            let updated = splice(&text, &block)?;
            std::fs::write(r, updated).with_context(|| format!("writing {}", r.display()))?;
            println!("updated gallery in {}", r.display());
        }
        None => {
            println!("\n-- gallery markdown (paste into your README, or use --readme with {BEGIN} / {END} markers) --\n");
            print!("{block}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest() -> Manifest {
        Manifest::from_str(
            "project: d\ntheme: t\nscenes:\n  - id: a\n    title: \"Scene A\"\n    right: { run: r }\n    caption: \"It reacts.\"\n  - id: b\n    right: { run: r }\n",
        )
        .unwrap()
    }

    #[test]
    fn gallery_md_includes_title_caption_and_image() {
        let m = manifest();
        let entries = vec![("a".to_string(), std::path::PathBuf::from("media/a.gif"))];
        let md = gallery_md(&m, &entries);
        assert!(md.contains("**Scene A**"));
        assert!(md.contains("It reacts."));
        assert!(md.contains("![Scene A](media/a.gif)"));
    }

    #[test]
    fn gallery_md_falls_back_to_id_when_untitled() {
        let m = manifest();
        let entries = vec![("b".to_string(), std::path::PathBuf::from("media/b.gif"))];
        let md = gallery_md(&m, &entries);
        assert!(md.contains("**b**"));
        assert!(md.contains("![b](media/b.gif)"));
    }

    #[test]
    fn splice_replaces_marker_region_only() {
        let readme = "# Title\n<!-- tt-demo:gallery:begin -->\nold\n<!-- tt-demo:gallery:end -->\ntail\n";
        let out = splice(readme, "NEW BLOCK").unwrap();
        assert!(out.contains("# Title"));
        assert!(out.contains("NEW BLOCK"));
        assert!(!out.contains("old"));
        assert!(out.contains("tail"));
        // markers survive so publish is repeatable
        assert!(out.contains("<!-- tt-demo:gallery:begin -->"));
        assert!(out.contains("<!-- tt-demo:gallery:end -->"));
    }

    #[test]
    fn splice_errors_without_markers() {
        assert!(splice("# no markers here", "X").is_err());
    }
}
