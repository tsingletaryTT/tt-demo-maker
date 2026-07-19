//! Dependency preflight for tt-demo.
use which::which;

/// For each tool name, report whether it resolves on PATH.
pub fn check_deps(names: &[&str]) -> Vec<(String, bool)> {
    names.iter().map(|n| (n.to_string(), which(n).is_ok())).collect()
}

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
