use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrchestratorConfig {
    #[serde(default = "default_mqtt_broker")]
    pub mqtt_broker: String,
    pub processes: HashMap<String, ProcessConfig>,
}

fn default_mqtt_broker() -> String {
    "localhost:1883".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessConfig {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub restart: RestartPolicy,
    #[serde(default)]
    pub depends_on: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RestartPolicy {
    #[serde(default = "default_policy")]
    pub policy: RestartMode,
    #[serde(default = "default_backoff")]
    pub backoff_ms: u64,
    #[serde(default = "default_max_backoff")]
    pub max_backoff_ms: u64,
}

impl Default for RestartPolicy {
    fn default() -> Self {
        Self {
            policy: RestartMode::Always,
            backoff_ms: 500,
            max_backoff_ms: 10000,
        }
    }
}

fn default_policy() -> RestartMode {
    RestartMode::Always
}

fn default_backoff() -> u64 {
    500
}

fn default_max_backoff() -> u64 {
    10000
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum RestartMode {
    Always,
    OnFailure,
    Never,
}

impl OrchestratorConfig {
    pub fn load(path: &PathBuf) -> Result<Self, Box<dyn std::error::Error>> {
        let content = std::fs::read_to_string(path)?;
        let config: Self = serde_json::from_str(&content)?;
        Ok(config)
    }

    /// Returns process names in dependency order (dependencies first)
    pub fn startup_order(&self) -> Result<Vec<String>, String> {
        let mut order = Vec::new();
        let mut visited = std::collections::HashSet::new();
        let mut visiting = std::collections::HashSet::new();

        fn visit(
            name: &str,
            processes: &HashMap<String, ProcessConfig>,
            visited: &mut std::collections::HashSet<String>,
            visiting: &mut std::collections::HashSet<String>,
            order: &mut Vec<String>,
        ) -> Result<(), String> {
            if visited.contains(name) {
                return Ok(());
            }
            if visiting.contains(name) {
                return Err(format!("Dependency cycle detected involving '{}'", name));
            }
            visiting.insert(name.to_string());

            if let Some(config) = processes.get(name) {
                for dep in &config.depends_on {
                    if !processes.contains_key(dep) {
                        return Err(format!(
                            "Unknown dependency '{}' for process '{}'",
                            dep, name
                        ));
                    }
                    visit(dep, processes, visited, visiting, order)?;
                }
            }

            visiting.remove(name);
            visited.insert(name.to_string());
            order.push(name.to_string());
            Ok(())
        }

        // Sort keys for deterministic ordering
        let mut keys: Vec<_> = self.processes.keys().collect();
        keys.sort();

        for name in keys {
            visit(name, &self.processes, &mut visited, &mut visiting, &mut order)?;
        }

        Ok(order)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_minimal_config() {
        let json = r#"{
            "processes": {
                "store": {
                    "command": "commonplace-store"
                }
            }
        }"#;
        let config: OrchestratorConfig = serde_json::from_str(json).unwrap();
        assert_eq!(config.mqtt_broker, "localhost:1883");
        assert_eq!(config.processes.len(), 1);
        assert_eq!(config.processes["store"].command, "commonplace-store");
        assert_eq!(config.processes["store"].restart.policy, RestartMode::Always);
    }

    #[test]
    fn test_parse_full_config() {
        let json = r#"{
            "mqtt_broker": "localhost:1884",
            "processes": {
                "store": {
                    "command": "commonplace-store",
                    "args": ["--database", "./data.redb"],
                    "restart": { "policy": "on_failure", "backoff_ms": 1000, "max_backoff_ms": 30000 }
                },
                "http": {
                    "command": "commonplace-http",
                    "args": ["--port", "3000"],
                    "depends_on": ["store"]
                }
            }
        }"#;
        let config: OrchestratorConfig = serde_json::from_str(json).unwrap();
        assert_eq!(config.mqtt_broker, "localhost:1884");
        assert_eq!(config.processes["store"].restart.policy, RestartMode::OnFailure);
        assert_eq!(config.processes["store"].restart.backoff_ms, 1000);
        assert_eq!(config.processes["http"].depends_on, vec!["store"]);
    }

    #[test]
    fn test_dependency_order() {
        let json = r#"{
            "processes": {
                "http": { "command": "http", "depends_on": ["store"] },
                "store": { "command": "store", "depends_on": ["broker"] },
                "broker": { "command": "broker" }
            }
        }"#;
        let config: OrchestratorConfig = serde_json::from_str(json).unwrap();
        let order = config.startup_order().unwrap();
        assert_eq!(order, vec!["broker", "store", "http"]);
    }

    #[test]
    fn test_dependency_cycle_detected() {
        let json = r#"{
            "processes": {
                "a": { "command": "a", "depends_on": ["b"] },
                "b": { "command": "b", "depends_on": ["a"] }
            }
        }"#;
        let config: OrchestratorConfig = serde_json::from_str(json).unwrap();
        assert!(config.startup_order().is_err());
    }
}
