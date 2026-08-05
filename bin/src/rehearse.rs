//! Rehearse a scene without recording: run its directive command while sampling
//! `tt-smi -s`, then report the idle -> load telemetry delta per device. Catches
//! "the viz won't react" before any footage is captured (the README session's
//! CPU-fallback-server trap).
use crate::compile;
use crate::manifest::{Layout, Manifest};
use anyhow::Context;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DeviceSample {
    pub power_w: f64,
    pub aiclk_mhz: f64,
}

/// Parse a `tt-smi -s` snapshot. Telemetry values arrive as strings with
/// leading spaces (" 15.0") — but accept bare numbers too, since firmware
/// versions differ in formatting.
pub fn parse_tt_smi(json: &str) -> anyhow::Result<Vec<DeviceSample>> {
    fn num(v: Option<&serde_json::Value>) -> f64 {
        match v {
            Some(serde_json::Value::String(s)) => s.trim().parse().unwrap_or(0.0),
            Some(serde_json::Value::Number(n)) => n.as_f64().unwrap_or(0.0),
            _ => 0.0,
        }
    }
    let v: serde_json::Value = serde_json::from_str(json).context("parsing tt-smi -s output")?;
    let devices = v
        .get("device_info")
        .and_then(|d| d.as_array())
        .context("tt-smi output has no device_info array")?;
    Ok(devices
        .iter()
        .map(|d| {
            let t = d.get("telemetry");
            DeviceSample {
                power_w: num(t.and_then(|t| t.get("power"))),
                aiclk_mhz: num(t.and_then(|t| t.get("aiclk"))),
            }
        })
        .collect())
}

/// One snapshot via the `tt-smi` on PATH. None when tt-smi is missing or its
/// output doesn't parse — rehearsal still runs the command, it just can't judge.
pub fn sample() -> Option<Vec<DeviceSample>> {
    let out = std::process::Command::new("tt-smi").arg("-s").output().ok()?;
    if !out.status.success() {
        return None;
    }
    parse_tt_smi(&String::from_utf8_lossy(&out.stdout)).ok()
}

/// Did the load move the hardware? True when any device (in the overlap of the
/// two snapshots) gained >= `min_delta_w` watts or >= 100 MHz of AI clock.
pub fn reaction(baseline: &[DeviceSample], peak: &[DeviceSample], min_delta_w: f64) -> bool {
    baseline.iter().zip(peak.iter()).any(|(b, p)| {
        p.power_w - b.power_w >= min_delta_w || p.aiclk_mhz - b.aiclk_mhz >= 100.0
    })
}

/// Element-wise max across snapshots, so the peak table shows each device's own high-water mark.
fn merge_peak(acc: &mut Vec<DeviceSample>, s: &[DeviceSample]) {
    if acc.len() < s.len() {
        acc.resize(s.len(), DeviceSample { power_w: 0.0, aiclk_mhz: 0.0 });
    }
    for (a, b) in acc.iter_mut().zip(s.iter()) {
        if b.power_w > a.power_w { a.power_w = b.power_w; }
        if b.aiclk_mhz > a.aiclk_mhz { a.aiclk_mhz = b.aiclk_mhz; }
    }
}

pub fn run(id: &str, min_delta: f64, require_reaction: bool) -> anyhow::Result<()> {
    let yaml = std::fs::read_to_string("demo/demos.yaml").context("reading demo/demos.yaml")?;
    let m = Manifest::from_str(&yaml)?;
    let s = m.scene(id).with_context(|| {
        format!(
            "unknown scene `{id}`; valid: {}",
            m.scenes.iter().map(|s| s.id.as_str()).collect::<Vec<_>>().join(", ")
        )
    })?;
    if s.is_raw() {
        anyhow::bail!("scene `{id}` is a raw hatch — rehearse only supports declarative scenes");
    }

    // The "directive" is what causes the reaction: the left pane in a split
    // scene, else the single (right) pane's own command.
    let backend = m.defaults.backend.clone().unwrap_or_default();
    let pane = if s.layout == Layout::Split && s.left.is_some() {
        s.left.as_ref().unwrap()
    } else {
        s.right.as_ref().context("scene has no pane to rehearse")?
    };
    let cmd = compile::interp(&pane.run, &backend);
    let dur_cap = s
        .duration
        .as_deref()
        .and_then(|d| d.trim_end_matches('s').parse::<u64>().ok())
        .unwrap_or(8)
        + 30; // generous cap: rehearsal must never hang on a non-exiting command

    let telemetry = sample().is_some();
    if !telemetry {
        println!("!! tt-smi not available — running the directive without telemetry judgment");
    }

    let baseline = sample().unwrap_or_default();
    println!("== rehearse {id}");
    println!("   directive: {cmd}");

    let mut child = std::process::Command::new("bash")
        .arg("-c")
        .arg(&cmd)
        .spawn()
        .context("spawning directive command")?;

    let mut peak = baseline.clone();
    let started = Instant::now();
    loop {
        match child.try_wait()? {
            Some(status) => {
                if !status.success() {
                    println!("   directive exited nonzero ({status}) — footage would capture a failure");
                }
                break;
            }
            None if started.elapsed() >= Duration::from_secs(dur_cap) => {
                child.kill().ok();
                child.wait().ok();
                println!("   directive still running after {dur_cap}s cap — killed (fine for viz-style commands)");
                break;
            }
            None => {
                if let Some(s) = sample() {
                    merge_peak(&mut peak, &s);
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    }

    if !telemetry {
        return Ok(());
    }

    println!("   dev  power (idle -> peak)   aiclk (idle -> peak)");
    for (i, (b, p)) in baseline.iter().zip(peak.iter()).enumerate() {
        println!(
            "   {i:>3}  {:>6.1}W -> {:>6.1}W     {:>5.0} -> {:>5.0} MHz",
            b.power_w, p.power_w, b.aiclk_mhz, p.aiclk_mhz
        );
    }
    let reacted = reaction(&baseline, &peak, min_delta);
    if reacted {
        println!("reaction detected — the viz will have something to show");
    } else {
        println!("NO reaction detected (>= {min_delta}W or >= 100MHz on any device) — recording now would capture a quiet board");
        if require_reaction {
            anyhow::bail!("rehearsal found no hardware reaction for scene `{id}`");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Shape mirrors real `tt-smi -s` output: telemetry values are STRINGS with
    // leading spaces (e.g. " 15.0"), power in watts, aiclk in MHz.
    const SNAP: &str = r#"{
        "device_info": [
            { "telemetry": { "power": " 15.0", "aiclk": " 800" } },
            { "telemetry": { "power": "144.0", "aiclk": "1350" } }
        ]
    }"#;

    #[test]
    fn parses_tt_smi_snapshot_strings() {
        let d = parse_tt_smi(SNAP).unwrap();
        assert_eq!(d.len(), 2);
        assert_eq!(d[0].power_w, 15.0);
        assert_eq!(d[0].aiclk_mhz, 800.0);
        assert_eq!(d[1].power_w, 144.0);
        assert_eq!(d[1].aiclk_mhz, 1350.0);
    }

    #[test]
    fn reaction_on_power_delta_or_clock_jump() {
        let base = vec![DeviceSample { power_w: 15.0, aiclk_mhz: 800.0 }];
        // Below min delta, same clock -> no reaction.
        let quiet = vec![DeviceSample { power_w: 20.0, aiclk_mhz: 800.0 }];
        assert!(!reaction(&base, &quiet, 10.0));
        // Power delta >= min_delta -> reaction.
        let loud = vec![DeviceSample { power_w: 30.0, aiclk_mhz: 800.0 }];
        assert!(reaction(&base, &loud, 10.0));
        // Clock jump alone (>= 100 MHz) -> reaction.
        let clocked = vec![DeviceSample { power_w: 16.0, aiclk_mhz: 1350.0 }];
        assert!(reaction(&base, &clocked, 10.0));
    }

    #[test]
    fn reaction_handles_device_count_mismatch() {
        // Peak saw more devices than baseline (hot-plug/noise): compare the overlap only.
        let base = vec![DeviceSample { power_w: 15.0, aiclk_mhz: 800.0 }];
        let peak = vec![
            DeviceSample { power_w: 40.0, aiclk_mhz: 800.0 },
            DeviceSample { power_w: 12.0, aiclk_mhz: 800.0 },
        ];
        assert!(reaction(&base, &peak, 10.0));
    }
}
