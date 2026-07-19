//! Tiered readiness: cheap log marker -> authoritative HTTP probe (+ model identity).
use anyhow::Context;

/// Pure predicate over a health JSON body.
pub fn health_ok(body: &str, ready_field: Option<&str>, runner_key: Option<&str>) -> bool {
    let v: serde_json::Value = match serde_json::from_str(body) { Ok(v) => v, Err(_) => return false };
    if let Some(f) = ready_field {
        let truthy = match v.get(f) {
            Some(serde_json::Value::Bool(b)) => *b,
            Some(serde_json::Value::String(s)) => !s.is_empty() && s != "false",
            Some(serde_json::Value::Number(n)) => n.as_f64().unwrap_or(0.0) != 0.0,
            _ => false,
        };
        if !truthy { return false; }
    }
    if let Some(rk) = runner_key {
        if v.get("runner_in_use").and_then(|x| x.as_str()) != Some(rk) { return false; }
    }
    true
}

pub fn log_matches(log: &str, pattern: &str) -> anyhow::Result<bool> {
    let re = regex::Regex::new(pattern).with_context(|| format!("bad regex: {pattern}"))?;
    Ok(re.is_match(log))
}

use std::time::{Duration, Instant};

/// Poll `url` until `health_ok` passes or `timeout` elapses. Uses ureq (blocking).
pub fn poll_http(url: &str, ready_field: Option<&str>, runner_key: Option<&str>, timeout: Duration) -> anyhow::Result<()> {
    let start = Instant::now();
    loop {
        if let Ok(resp) = ureq::get(url).timeout(Duration::from_secs(3)).call() {
            if let Ok(body) = resp.into_string() {
                if health_ok(&body, ready_field, runner_key) { return Ok(()); }
            }
        }
        if start.elapsed() >= timeout {
            anyhow::bail!("readiness timeout after {:?} polling {url}", timeout);
        }
        std::thread::sleep(Duration::from_millis(1000));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_requires_ready_field_true() {
        assert!(health_ok(r#"{"model_ready":true}"#, Some("model_ready"), None));
        assert!(!health_ok(r#"{"model_ready":false}"#, Some("model_ready"), None));
        assert!(!health_ok("not json", Some("model_ready"), None));
    }

    #[test]
    fn health_checks_runner_identity() {
        let body = r#"{"model_ready":true,"runner_in_use":"qwen3-8b"}"#;
        assert!(health_ok(body, Some("model_ready"), Some("qwen3-8b")));
        assert!(!health_ok(body, Some("model_ready"), Some("skyreels")));
    }

    #[test]
    fn log_regex_matches() {
        assert!(log_matches("... warmed up and ready ...", "warmed up and ready").unwrap());
        assert!(!log_matches("still loading", "ready").unwrap());
    }
}
