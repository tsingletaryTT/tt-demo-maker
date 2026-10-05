//! Idle-trim an asciicast v2 recording (native replacement for compress_cast.py).
use anyhow::Context;

/// Drops the end-of-capture tail that tmux appends when the recorded program
/// exits: a final `[exited]` line, and the screen clear (`ESC[2J`) tmux draws
/// just before it. Left in, the last frame of a looped clip is a blank screen
/// reading `[exited]`.
///
/// Only a trailing `[exited]` event is acted on. A cast that does not end in
/// one is returned unchanged (byte for byte), the clear is dropped only when it
/// directly precedes that line, and `[exited]` text elsewhere is kept. Event
/// times are not touched. `record`, `render` and `compress` all go through
/// this, so the cleanup does not depend on running `compress`.
pub fn strip_exit_tail_text(input: &str) -> anyhow::Result<String> {
    let mut lines: Vec<&str> = input.lines().filter(|l| !l.trim().is_empty()).collect();
    let data_of = |line: &str| -> Option<String> {
        let ev: serde_json::Value = serde_json::from_str(line).ok()?;
        ev.get(2)?.as_str().map(str::to_string)
    };
    // Lines past the header only: the header is never an event.
    let is_exited = lines.len() > 1
        && lines.last().and_then(|l| data_of(l)).is_some_and(|d| d.trim() == "[exited]");
    if !is_exited {
        return Ok(input.to_string());
    }
    lines.pop();
    if lines.len() > 1
        && lines.last().and_then(|l| data_of(l)).is_some_and(|d| d.contains("\u{1b}[2J"))
    {
        lines.pop();
    }
    Ok(lines.join("\n") + "\n")
}

/// Strips the exit tail from the cast at `path` in place. Returns whether the
/// file changed. Leaves the file untouched when there is nothing to strip.
pub fn strip_exit_tail_file(path: &std::path::Path) -> anyhow::Result<bool> {
    let input = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let cleaned = strip_exit_tail_text(&input)?;
    if cleaned == input {
        return Ok(false);
    }
    std::fs::write(path, cleaned).with_context(|| format!("writing {}", path.display()))?;
    Ok(true)
}

/// If the cast at `path` ends in the exit tail, writes a cleaned copy to the
/// temp dir and returns its path; otherwise `None`. `render` uses this so an
/// older cast (recorded before `record` cleaned them) still renders without
/// the `[exited]` frame, without editing the user's file.
pub fn cleaned_copy(path: &std::path::Path) -> anyhow::Result<Option<std::path::PathBuf>> {
    let input = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let cleaned = strip_exit_tail_text(&input)?;
    if cleaned == input {
        return Ok(None);
    }
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("cast");
    let tmp = std::env::temp_dir().join(format!("tt-demo-clean-{}-{name}", std::process::id()));
    std::fs::write(&tmp, cleaned).with_context(|| format!("writing {}", tmp.display()))?;
    Ok(Some(tmp))
}

pub fn trim(input: &str, max_idle: f64) -> anyhow::Result<String> {
    let cleaned = strip_exit_tail_text(input)?;
    let mut lines = cleaned.lines();
    let header = lines.next().context("empty cast (no header)")?;
    let mut out = String::new();
    out.push_str(header);
    out.push('\n');
    let mut prev_orig = 0.0_f64;
    let mut shift = 0.0_f64; // total time removed so far
    for line in lines {
        if line.trim().is_empty() { continue; }
        let ev: serde_json::Value = serde_json::from_str(line)
            .with_context(|| format!("bad event line: {line}"))?;
        let t = ev.get(0).and_then(|v| v.as_f64()).context("event missing time")?;
        let gap = t - prev_orig;
        if gap > max_idle { shift += gap - max_idle; }
        prev_orig = t;
        let new_t = t - shift;
        let code = ev.get(1).and_then(|v| v.as_str()).unwrap_or("o");
        let data = ev.get(2).cloned().unwrap_or(serde_json::Value::String(String::new()));
        out.push_str(&serde_json::to_string(&serde_json::json!([new_t, code, data]))?);
        out.push('\n');
    }
    Ok(out)
}

/// Default output path for a trimmed cast: `x.cast` -> `x.min.cast` (the name
/// `render_target()` prefers). Errors on `*.min.cast` (double-compress) and on
/// non-`.cast` inputs rather than guessing.
pub fn default_out(input: &std::path::Path) -> anyhow::Result<std::path::PathBuf> {
    let name = input
        .file_name()
        .and_then(|n| n.to_str())
        .with_context(|| format!("bad cast path: {}", input.display()))?;
    if name.ends_with(".min.cast") {
        anyhow::bail!("{name} is already a compressed (.min.cast) file");
    }
    let stem = name
        .strip_suffix(".cast")
        .with_context(|| format!("expected a .cast file, got {name}"))?;
    Ok(input.with_file_name(format!("{stem}.min.cast")))
}

pub fn run(
    path: &std::path::Path,
    max_idle: f64,
    out: Option<&std::path::Path>,
    to_stdout: bool,
) -> anyhow::Result<()> {
    let input = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let trimmed = trim(&input, max_idle)?;
    if to_stdout {
        print!("{trimmed}");
        return Ok(());
    }
    let target = match out {
        Some(o) => o.to_path_buf(),
        None => default_out(path)?,
    };
    std::fs::write(&target, trimmed)?;
    println!("wrote {}", target.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_large_idle_gap_preserves_small_one() {
        // events at t=0, t=10 (big dead air), t=10.3 (small gap UNDER the limit)
        let cast = "{\"version\":2,\"width\":80,\"height\":24}\n[0.0,\"o\",\"a\"]\n[10.0,\"o\",\"b\"]\n[10.3,\"o\",\"c\"]\n";
        let out = trim(cast, 0.5).unwrap();
        let times: Vec<f64> = out.lines().skip(1)
            .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()[0].as_f64().unwrap())
            .collect();
        assert_eq!(times[0], 0.0);
        assert_eq!(times[1], 0.5);              // 10s gap clamped to max_idle (0.5)
        assert!((times[2] - 0.8).abs() < 1e-9); // following 0.3s gap (< max_idle) preserved: 0.5 + 0.3
    }

    #[test]
    fn default_out_swaps_cast_for_min_cast() {
        let p = default_out(std::path::Path::new("demo/assets/foo.cast")).unwrap();
        assert_eq!(p, std::path::PathBuf::from("demo/assets/foo.min.cast"));
    }

    #[test]
    fn default_out_rejects_already_min() {
        let err = default_out(std::path::Path::new("demo/assets/foo.min.cast")).unwrap_err();
        assert!(err.to_string().contains("already"));
    }

    #[test]
    fn default_out_rejects_non_cast_extension() {
        assert!(default_out(std::path::Path::new("demo/assets/foo.gif")).is_err());
    }

    fn data_of(cast: &str) -> Vec<String> {
        cast.lines().skip(1)
            .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()[2].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn drops_the_trailing_exited_line_and_the_clear_before_it() {
        let cast = "{\"version\":2,\"width\":80,\"height\":24}\n\
            [0.1,\"o\",\"frame\"]\n\
            [0.2,\"o\",\"\\u001b[H\\u001b[2J\"]\n\
            [0.2,\"o\",\"[exited]\\r\\n\"]\n";
        let out = trim(cast, 0.5).unwrap();
        assert_eq!(data_of(&out), vec!["frame"]);
    }

    #[test]
    fn keeps_a_screen_clear_that_is_not_followed_by_exited() {
        let cast = "{\"version\":2,\"width\":80,\"height\":24}\n\
            [0.1,\"o\",\"\\u001b[2J\"]\n\
            [0.2,\"o\",\"frame\"]\n";
        let out = trim(cast, 0.5).unwrap();
        assert_eq!(data_of(&out).len(), 2);
    }

    #[test]
    fn keeps_exited_text_in_the_middle_of_a_cast() {
        let cast = "{\"version\":2,\"width\":80,\"height\":24}\n\
            [0.1,\"o\",\"[exited]\"]\n\
            [0.2,\"o\",\"frame\"]\n";
        let out = trim(cast, 0.5).unwrap();
        assert_eq!(data_of(&out), vec!["[exited]", "frame"]);
    }

    const TAILED: &str = "{\"version\":2,\"width\":80,\"height\":24}\n\
        [0.1,\"o\",\"frame\"]\n\
        [0.2,\"o\",\"\\u001b[H\\u001b[2J\"]\n\
        [0.2,\"o\",\"[exited]\\r\\n\"]\n";

    #[test]
    fn strip_text_leaves_a_clean_cast_byte_for_byte() {
        let clean = "{\"version\":2}\n[0.1,\"o\",\"x\"]\n";
        assert_eq!(strip_exit_tail_text(clean).unwrap(), clean);
        // A header-only cast and an empty string are fine too.
        assert_eq!(strip_exit_tail_text("{\"version\":2}\n").unwrap(), "{\"version\":2}\n");
        assert_eq!(strip_exit_tail_text("").unwrap(), "");
    }

    #[test]
    fn strip_text_keeps_event_times() {
        let out = strip_exit_tail_text(TAILED).unwrap();
        assert_eq!(out, "{\"version\":2,\"width\":80,\"height\":24}\n[0.1,\"o\",\"frame\"]\n");
    }

    #[test]
    fn strip_file_edits_in_place_once_then_reports_no_change() {
        let p = std::env::temp_dir().join(format!("tt-demo-strip-{}.cast", std::process::id()));
        std::fs::write(&p, TAILED).unwrap();
        assert!(strip_exit_tail_file(&p).unwrap());
        assert!(!std::fs::read_to_string(&p).unwrap().contains("[exited]"));
        assert!(!strip_exit_tail_file(&p).unwrap(), "second pass finds nothing");
        std::fs::remove_file(&p).ok();
    }

    #[test]
    fn cleaned_copy_leaves_the_original_alone() {
        let p = std::env::temp_dir().join(format!("tt-demo-copy-{}.cast", std::process::id()));
        std::fs::write(&p, TAILED).unwrap();
        let copy = cleaned_copy(&p).unwrap().expect("a tailed cast gets a copy");
        assert!(!std::fs::read_to_string(&copy).unwrap().contains("[exited]"));
        assert_eq!(std::fs::read_to_string(&p).unwrap(), TAILED, "original untouched");
        std::fs::write(&p, "{\"version\":2}\n[0.1,\"o\",\"x\"]\n").unwrap();
        assert!(cleaned_copy(&p).unwrap().is_none());
        std::fs::remove_file(&p).ok();
        std::fs::remove_file(&copy).ok();
    }
}
