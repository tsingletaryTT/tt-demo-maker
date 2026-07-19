//! Record scenes: resolve plan, (dry-run) print it, else drive lib/ capture scripts.
use crate::{
    compile,
    manifest::{Layout, Manifest},
    orchestrate::{plan, Step},
    ready,
};
use anyhow::Context;
use std::path::PathBuf;
use std::time::{Duration, Instant};

pub fn home() -> PathBuf {
    std::env::var("TT_DEMO_HOME").map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(".."))
}

/// Parse a duration string like `"8s"` into whole seconds, falling back to `default` for
/// anything missing or unparseable (never panics on a malformed manifest value).
fn parse_secs_u32(s: Option<&str>, default: u32) -> u32 {
    s.and_then(|s| s.trim_end_matches('s').parse::<u32>().ok()).unwrap_or(default)
}

/// Parse a timeout string like `"360s"` into a `Duration`, falling back to `default_secs`.
fn parse_timeout(s: Option<&str>, default_secs: u64) -> Duration {
    let secs = s.and_then(|s| s.trim_end_matches('s').parse::<u64>().ok()).unwrap_or(default_secs);
    Duration::from_secs(secs)
}

/// Tier-1 readiness: poll a logfile on disk until its contents match `pattern`, or bail after
/// `timeout`. Mirrors `ready::poll_http`'s loop shape but reads a file instead of an HTTP
/// endpoint, since a server's own stdout/stderr (captured by `lib/serve.sh`) is the cheap
/// marker here.
fn wait_for_log(path: &str, pattern: &str, timeout: Duration) -> anyhow::Result<()> {
    let start = Instant::now();
    loop {
        if let Ok(contents) = std::fs::read_to_string(path) {
            if ready::log_matches(&contents, pattern)? {
                return Ok(());
            }
        }
        if start.elapsed() >= timeout {
            anyhow::bail!("readiness timeout after {timeout:?} waiting for log pattern `{pattern}` in {path}");
        }
        std::thread::sleep(Duration::from_secs(1));
    }
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
                let Some(server_name) = server else { continue };
                // Manifest validation already rejects unknown server references at parse
                // time, so this should always hit — but never panic on a stale/edited
                // manifest that slipped past validation some other way.
                let Some(def) = m.servers.get(server_name) else { continue };

                // TODO(v1.1): stop prior server + board reset on switch (hardware path).
                // Today we only ever start the next server; nothing tears down whatever
                // was running before it, and no `tt-smi -r` board reset happens here.

                std::fs::create_dir_all("demo/assets").context("creating demo/assets")?;
                let logfile = format!("demo/assets/.{server_name}.log");
                let pid_output = std::process::Command::new("bash")
                    .arg(home().join("lib/serve.sh"))
                    .arg(&logfile)
                    .arg("bash")
                    .arg("-c")
                    .arg(&def.start)
                    .output()
                    .with_context(|| format!("spawning serve.sh for server `{server_name}`"))?;
                if !pid_output.status.success() {
                    anyhow::bail!("serve.sh failed to start server `{server_name}`");
                }
                let pid = String::from_utf8_lossy(&pid_output.stdout).trim().to_string();
                println!("   started {server_name} (pid {pid}), logging to {logfile}");

                if let Some(readiness) = &def.ready {
                    let timeout = parse_timeout(readiness.timeout.as_deref(), 300);
                    println!("   waiting for {server_name} readiness (timeout {timeout:?})...");
                    if let Some(url) = &readiness.health_url {
                        ready::poll_http(url, readiness.ready_field.as_deref(), readiness.runner_key.as_deref(), timeout)
                            .with_context(|| format!("waiting for `{server_name}` readiness at {url}"))?;
                    } else if let Some(pat) = &readiness.log {
                        wait_for_log(&logfile, pat, timeout)
                            .with_context(|| format!("waiting for `{server_name}` readiness (log pattern `{pat}`)"))?;
                    }
                    println!("   {server_name} ready");
                }
            }
            Step::Record { scene } => {
                let s = m.scene(scene).unwrap();

                // Raw-hatch scenes (`raw_tape`/`raw_script`) are handled before ever
                // touching `compile::compile_scene`: that function unconditionally requires
                // a `right` pane (it was only ever designed for declarative left/right
                // scenes), and a raw scene by construction never has one (the manifest
                // validator rejects a scene that sets both a raw hatch and declarative
                // panes) — calling it here would `bail!` on every raw scene, in dry-run
                // included. CLI capture of raw scenes is deferred to v1.1 (see
                // README/AGENTS "v1 limitations"); this path only prints and skips, never
                // errors, matching the manifest's own contract that raw is a valid shape.
                if s.is_raw() {
                    println!("== record {scene} [raw]");
                    if dry_run {
                        std::fs::create_dir_all("demo/assets").ok();
                        std::fs::write(format!("demo/assets/{scene}.cast"), "{\"version\":2}\n[0.0,\"o\",\"[dry-run]\"]\n").ok();
                        continue;
                    }
                    println!("   raw scenes not yet CLI-captured (v1.1) — run vhs/asciinema manually for `{scene}`");
                    continue;
                }

                let compiled = compile::compile_scene(s, &m, &tmpl)?;
                println!("== record {} [{}/{}]", scene, format!("{:?}", compiled.engine).to_lowercase(), compiled.kind);
                if dry_run {
                    std::fs::create_dir_all("demo/assets").ok();
                    std::fs::write(format!("demo/assets/{scene}.cast"), "{\"version\":2}\n[0.0,\"o\",\"[dry-run]\"]\n").ok();
                    continue;
                }

                // Real capture: run the TESTED lib/ scripts against the scene's RAW run
                // commands. The compiled tape/driver text (`compiled.text`, above) is only
                // used to validate the manifest compiles cleanly and report engine/kind —
                // executing it is the v1.1 capture-wiring path (see compile.rs TODO), not
                // this one.
                let cols = m.defaults.cols.unwrap_or(200);
                let rows = m.defaults.rows.unwrap_or(50);
                let ratio = s.split_ratio.unwrap_or(40);
                let dur = parse_secs_u32(s.duration.as_deref(), 8);
                let backend = m.defaults.backend.clone().unwrap_or_default();

                std::fs::create_dir_all("demo/assets").context("creating demo/assets")?;
                let out = PathBuf::from(format!("demo/assets/{scene}.cast"));

                let right = s.right.as_ref().context("scene needs a `right` pane or a raw hatch")?;
                let right_run = compile::interp(&right.run, &backend);

                let status = if s.layout == Layout::Split && s.left.is_some() {
                    let left_run = compile::interp(&s.left.as_ref().unwrap().run, &backend);
                    std::process::Command::new("bash")
                        .arg(home().join("lib/split.sh"))
                        .arg(&out)
                        .arg(cols.to_string())
                        .arg(rows.to_string())
                        .arg(ratio.to_string())
                        .arg(&left_run)
                        .arg(&right_run)
                        .arg(dur.to_string())
                        .status()
                        .with_context(|| format!("spawning split.sh for scene `{scene}`"))?
                } else {
                    // Single pane: capture `dur` seconds of a possibly-non-exiting viz, then
                    // stop it cleanly (SIGTERM, then wait) rather than letting tmux_capture.sh
                    // run forever. Wrap the entire run command in a subshell so that
                    // multi-statement commands (e.g. "setup; long-viz") are fully backgrounded
                    // together, rather than only the last statement.
                    let inner = format!(
                        "( {right_run} ) & __ttp=$!; sleep {dur}; kill $__ttp 2>/dev/null; wait $__ttp 2>/dev/null; true"
                    );
                    std::process::Command::new("bash")
                        .arg(home().join("lib/tmux_capture.sh"))
                        .arg(&out)
                        .arg(cols.to_string())
                        .arg(rows.to_string())
                        .arg("bash")
                        .arg("-c")
                        .arg(&inner)
                        .status()
                        .with_context(|| format!("spawning tmux_capture.sh for scene `{scene}`"))?
                };

                if !status.success() {
                    anyhow::bail!(
                        "capture failed for scene `{scene}` (exit {})",
                        status.code().map(|c| c.to_string()).unwrap_or_else(|| "signal".into())
                    );
                }
                println!("recorded {}", out.display());
            }
        }
    }
    if dry_run { println!("[dry-run] {} step(s); no hardware touched", steps.len()); }
    Ok(())
}
