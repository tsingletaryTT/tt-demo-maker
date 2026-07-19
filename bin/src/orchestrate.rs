//! Order scenes to minimize server switches (mirrors pipeline_engine backend-switching).
use crate::manifest::Manifest;

#[derive(Debug, PartialEq, Eq)]
pub enum Step { Switch { server: Option<String> }, Record { scene: String } }

/// Produce an ordered plan: group scenes by their `server`, emit a Switch when the
/// required server changes. `ids` selects+orders the scenes to consider.
pub fn plan(m: &Manifest, ids: &[String]) -> Vec<Step> {
    // Stable group by server, preserving first-seen server order.
    let mut order: Vec<Option<String>> = Vec::new();
    for id in ids {
        if let Some(s) = m.scene(id) {
            let key = s.server.clone();
            if !order.contains(&key) { order.push(key); }
        }
    }
    let mut steps = Vec::new();
    let mut current: Option<Option<String>> = None;
    for key in order {
        for id in ids {
            if let Some(s) = m.scene(id) {
                if s.server == key {
                    if current.as_ref() != Some(&key) {
                        steps.push(Step::Switch { server: key.clone() });
                        current = Some(key.clone());
                    }
                    steps.push(Step::Record { scene: id.clone() });
                }
            }
        }
    }
    steps
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;

    const M: &str = r#"
project: p
theme: t
servers: { qwen3: { start: "x" }, skyreels: { start: "y" } }
scenes:
  - { id: a, layout: single, server: qwen3, right: { run: r } }
  - { id: b, layout: single, server: skyreels, right: { run: r } }
  - { id: c, layout: single, server: qwen3, right: { run: r } }
"#;

    #[test]
    fn groups_by_server_minimizing_switches() {
        let m = Manifest::from_str(M).unwrap();
        let ids = vec!["a".to_string(), "b".to_string(), "c".to_string()];
        let steps = plan(&m, &ids);
        // Expect: switch qwen3, record a, record c, switch skyreels, record b
        assert_eq!(steps, vec![
            Step::Switch { server: Some("qwen3".into()) },
            Step::Record { scene: "a".into() },
            Step::Record { scene: "c".into() },
            Step::Switch { server: Some("skyreels".into()) },
            Step::Record { scene: "b".into() },
        ]);
    }
}
