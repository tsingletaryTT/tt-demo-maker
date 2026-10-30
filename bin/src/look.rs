//! How recordings look: the font and terminal choices, asked of `lib/look.sh`.
//!
//! The preference order lives in the shell script because `lib/render.sh` needs
//! it too; Rust asks the script rather than keeping a second copy that can drift.
use std::path::Path;
use std::process::{Command, Stdio};

/// Run `lib/look.sh <arg>` and return its trimmed stdout, or `None` if the script
/// is missing or fails. `font_override` becomes `TT_DEMO_FONT` for the call.
fn ask(home: &Path, arg: &str, font_override: Option<&str>) -> Option<String> {
    let mut cmd = Command::new("bash");
    cmd.arg(home.join("lib/look.sh")).arg(arg).stderr(Stdio::null());
    if let Some(f) = font_override {
        cmd.env("TT_DEMO_FONT", f);
    }
    let out = cmd.output().ok().filter(|o| o.status.success())?;
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!s.is_empty()).then_some(s)
}

/// The font family every renderer will use. Never empty: falls back to the
/// font every renderer ends on if the script can't be run.
pub fn font(home: &Path, font_override: Option<&str>) -> String {
    ask(home, "font", font_override).unwrap_or_else(|| "DejaVu Sans Mono".to_string())
}

/// `alacritty` or `xterm`: the emulator the MP4 path will use.
pub fn terminal(home: &Path) -> String {
    ask(home, "terminal", None).unwrap_or_else(|| "xterm".to_string())
}

/// True when the resolved font is a preferred one rather than a stock fallback.
pub fn font_is_good(home: &Path) -> bool {
    ask(home, "quality", None).as_deref() == Some("good")
}

/// tmux's version as `(major, minor)`, parsed from `tmux -V` ("tmux 3.4", "tmux 3.3a",
/// "tmux next-3.5"). `None` when tmux is absent or the output is unrecognised.
pub fn tmux_version() -> Option<(u32, u32)> {
    let out = Command::new("tmux").arg("-V").output().ok()?;
    parse_tmux_version(&String::from_utf8_lossy(&out.stdout))
}

fn parse_tmux_version(s: &str) -> Option<(u32, u32)> {
    let v = s.split_whitespace().nth(1)?.trim_start_matches("next-");
    let mut parts = v.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor: String = parts.next()?.chars().take_while(|c| c.is_ascii_digit()).collect();
    Some((major, minor.parse().ok()?))
}

/// Does tmux know the `tmux-256color` terminfo entry the recording config names?
pub fn has_tmux_terminfo() -> bool {
    Command::new("infocmp")
        .arg("tmux-256color")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// What is missing from the "look" setup, as short reasons (empty when it is all in place).
/// Pure, so the policy can be tested without touching the machine.
pub fn look_gaps(font_good: bool, terminal: &str, tmux: Option<(u32, u32)>, terminfo: bool) -> Vec<String> {
    let mut gaps = Vec::new();
    if !font_good {
        gaps.push("only a stock font is installed (run `tt-demo setup` for JetBrainsMono Nerd Font)".to_string());
    }
    if terminal != "alacritty" {
        gaps.push("alacritty not installed, so MP4 falls back to xterm (truecolor and glyphs look worse)".to_string());
    }
    match tmux {
        // `terminal-features` (what carries truecolor in tmux-record.conf) arrived in 3.2.
        Some(v) if v < (3, 2) => gaps.push(format!("tmux {}.{} is older than 3.2; truecolor falls back to terminal-overrides", v.0, v.1)),
        None => gaps.push("tmux not found".to_string()),
        _ => {}
    }
    if !terminfo {
        gaps.push("terminfo entry tmux-256color is missing (install ncurses-term)".to_string());
    }
    gaps
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tmux_versions() {
        assert_eq!(parse_tmux_version("tmux 3.4\n"), Some((3, 4)));
        assert_eq!(parse_tmux_version("tmux 3.3a"), Some((3, 3)));
        assert_eq!(parse_tmux_version("tmux next-3.5"), Some((3, 5)));
        assert_eq!(parse_tmux_version("garbage"), None);
        assert_eq!(parse_tmux_version(""), None);
    }

    #[test]
    fn gaps_name_each_missing_piece() {
        assert!(look_gaps(true, "alacritty", Some((3, 4)), true).is_empty());
        assert_eq!(look_gaps(false, "alacritty", Some((3, 4)), true).len(), 1);
        assert_eq!(look_gaps(true, "xterm", Some((3, 4)), true).len(), 1);
        assert_eq!(look_gaps(true, "alacritty", Some((3, 1)), true).len(), 1);
        assert_eq!(look_gaps(true, "alacritty", None, true).len(), 1);
        assert_eq!(look_gaps(true, "alacritty", Some((3, 4)), false).len(), 1);
        assert_eq!(look_gaps(false, "xterm", None, false).len(), 4);
    }
}
