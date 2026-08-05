//! Idle-trim an asciicast v2 recording (native replacement for compress_cast.py).
use anyhow::Context;

pub fn trim(input: &str, max_idle: f64) -> anyhow::Result<String> {
    let mut lines = input.lines();
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
}
