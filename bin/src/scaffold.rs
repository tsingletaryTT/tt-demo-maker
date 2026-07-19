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
