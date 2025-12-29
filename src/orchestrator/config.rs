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
}
