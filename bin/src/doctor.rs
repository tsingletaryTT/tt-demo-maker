//! Dependency preflight for tt-demo.
use which::which;

/// For each tool name, report whether it resolves on PATH.
pub fn check_deps(names: &[&str]) -> Vec<(String, bool)> {
    names.iter().map(|n| (n.to_string(), which(n).is_ok())).collect()
}

/// Required external tools for the full pipeline.
pub const REQUIRED: &[&str] = &["tmux", "asciinema", "agg", "ffmpeg", "vhs", "Xvfb", "xterm"];

/// Tools for the GUI/screen-capture path (`lib/screen_capture.sh`) only.
///
/// Deliberately *not* in [`REQUIRED`]: most projects demo a terminal and will never
/// record a GUI window, so a missing `obs` shouldn't fail `doctor` on a machine that
/// doesn't need it. They're reported and recommended; `--require-screen` turns them
/// into hard failures for a scripted preflight that does mean to record a GUI.
pub const SCREEN_CAPTURE: &[&str] = &["obs", "spectacle"];

/// Can `python3` import Pillow? The blank-frame check in `screen_capture.sh` needs it,
/// and without it that check can't tell a real capture from an all-black one — so this
/// is reported alongside the capture backends rather than buried.
pub fn has_pillow() -> bool {
    std::process::Command::new("python3")
        .args(["-c", "import PIL"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Summarize the screen-capture path: is there a usable backend, and can captures be
/// verified? Returns the reasons it is unusable (empty when it's good to go).
fn screen_capture_gaps(found: &[(String, bool)], pillow: bool) -> Vec<String> {
    let mut gaps = Vec::new();
    if !found.iter().any(|(_, ok)| *ok) {
        gaps.push("no capture backend (obs for video, spectacle for stills)".to_string());
    }
    if !pillow {
        gaps.push("python3 has no Pillow, so captures can't be verified".to_string());
    }
    gaps
}

pub fn run(require_screen: bool) -> anyhow::Result<()> {
    let mut missing = Vec::new();
    println!("tt-demo doctor — dependency check");
    for (name, ok) in check_deps(REQUIRED) {
        println!("  [{}] {}", if ok { "ok " } else { "MISSING" }, name);
        if !ok { missing.push(name); }
    }

    // Screen capture is a separate, optional path — see SCREEN_CAPTURE.
    println!("\nscreen capture (optional — only for recording a GUI window)");
    let screen = check_deps(SCREEN_CAPTURE);
    for (name, ok) in &screen {
        let note = match name.as_str() {
            "obs" => "video, 1080p60 via PipeWire",
            "spectacle" => "stills burst, any compositor",
            _ => "",
        };
        println!("  [{}] {:<10} {}", if *ok { "ok " } else { "-- " }, name, note);
    }
    let pillow = has_pillow();
    println!(
        "  [{}] {:<10} {}",
        if pillow { "ok " } else { "-- " },
        "Pillow",
        "python3 module; the blank-capture check needs it"
    );

    let gaps = screen_capture_gaps(&screen, pillow);
    if gaps.is_empty() {
        println!("  screen capture ready — preflight a box with `lib/screen_capture.sh detect`");
    } else {
        for gap in &gaps {
            println!("  note: {gap}");
        }
        if require_screen {
            anyhow::bail!("screen capture unusable: {}", gaps.join("; "));
        }
        println!("  (not required — pass --require-screen to make these fail)");
    }

    if missing.is_empty() {
        println!("\nall required dependencies present");
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

    #[test]
    fn screen_capture_needs_a_backend_and_a_verifier() {
        let both = vec![("obs".into(), true), ("spectacle".into(), true)];
        assert!(screen_capture_gaps(&both, true).is_empty(), "obs + Pillow is usable");

        // One backend is enough; two is not required.
        let one = vec![("obs".into(), false), ("spectacle".into(), true)];
        assert!(screen_capture_gaps(&one, true).is_empty(), "spectacle alone is usable");

        // No backend at all, or nothing to check the frames with, is a gap — the
        // second matters because an unverifiable capture is the failure mode this
        // whole path exists to prevent.
        assert_eq!(screen_capture_gaps(&[], true).len(), 1);
        assert_eq!(screen_capture_gaps(&both, false).len(), 1);
        assert_eq!(screen_capture_gaps(&[], false).len(), 2);
    }

    #[test]
    fn screen_capture_is_not_required() {
        // The regression this guards: adding obs/spectacle to REQUIRED would fail
        // doctor on every terminal-only machine.
        for tool in SCREEN_CAPTURE {
            assert!(!REQUIRED.contains(tool), "{tool} must stay optional");
        }
    }
}
