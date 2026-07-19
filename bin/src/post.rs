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
