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
