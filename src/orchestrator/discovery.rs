//! Discovery module for `.processes.json` files.
//!
//! This module provides the configuration format and parsing for
//! processes discovered from `.processes.json` files in the filesystem.
//!
//! For process lifecycle management, see the `discovered_manager` module.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

/// Configuration parsed from `.processes.json` files.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessesConfig {
    pub processes: HashMap<String, DiscoveredProcess>,
}

/// A process discovered from a `.processes.json` file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredProcess {
    /// Command to run (either a string or array of strings)
    pub command: CommandSpec,
    /// Relative path within same directory that this process owns
    pub owns: String,
    /// Required absolute path on host for working directory
    pub cwd: PathBuf,
}

/// Command specification - supports both simple string and array formats.
///
/// Note: The simple string form uses whitespace splitting, not shell-style quoting.
/// For commands with spaces in arguments, use the array form instead.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum CommandSpec {
    /// Simple command string (split on whitespace - no quoting support)
    Simple(String),
    /// Array of command and arguments (recommended for complex commands)
    Array(Vec<String>),
}

impl CommandSpec {
    /// Get the program to execute.
    pub fn program(&self) -> &str {
        match self {
            CommandSpec::Simple(s) => s.split_whitespace().next().unwrap_or(""),
            CommandSpec::Array(arr) => arr.first().map(|s| s.as_str()).unwrap_or(""),
        }
    }

    /// Get the arguments for the command.
    pub fn args(&self) -> Vec<&str> {
        match self {
            CommandSpec::Simple(s) => s.split_whitespace().skip(1).collect(),
            CommandSpec::Array(arr) => arr.iter().skip(1).map(|s| s.as_str()).collect(),
        }
    }
}

impl ProcessesConfig {
    /// Load a `.processes.json` file from the given path.
    pub fn load(path: &PathBuf) -> Result<Self, Box<dyn std::error::Error>> {
        let content = std::fs::read_to_string(path)?;
        let config: Self = serde_json::from_str(&content)?;
        Ok(config)
    }

    /// Parse from a JSON string.
    pub fn parse(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_processes_json_with_string_command() {
        let json = r#"{
            "processes": {
                "counter": {
                    "command": "python counter.py",
                    "owns": "counter.json",
                    "cwd": "/home/user/examples"
                }
            }
        }"#;

        let config = ProcessesConfig::parse(json).unwrap();
        assert_eq!(config.processes.len(), 1);

        let counter = &config.processes["counter"];
        assert!(matches!(counter.command, CommandSpec::Simple(_)));
        assert_eq!(counter.command.program(), "python");
        assert_eq!(counter.command.args(), vec!["counter.py"]);
        assert_eq!(counter.owns, "counter.json");
        assert_eq!(counter.cwd, PathBuf::from("/home/user/examples"));
    }

    #[test]
    fn test_parse_processes_json_with_array_command() {
        let json = r#"{
            "processes": {
                "server": {
                    "command": ["node", "server.js", "--port", "3000"],
                    "owns": "state.json",
                    "cwd": "/opt/app"
                }
            }
        }"#;

        let config = ProcessesConfig::parse(json).unwrap();
        assert_eq!(config.processes.len(), 1);

        let server = &config.processes["server"];
        assert!(matches!(server.command, CommandSpec::Array(_)));
        assert_eq!(server.command.program(), "node");
        assert_eq!(server.command.args(), vec!["server.js", "--port", "3000"]);
        assert_eq!(server.owns, "state.json");
        assert_eq!(server.cwd, PathBuf::from("/opt/app"));
    }

    #[test]
    fn test_command_spec_deserialization() {
        // Test simple string
        let simple: CommandSpec = serde_json::from_str(r#""echo hello world""#).unwrap();
        assert!(matches!(simple, CommandSpec::Simple(_)));
        assert_eq!(simple.program(), "echo");
        assert_eq!(simple.args(), vec!["hello", "world"]);

        // Test array
        let array: CommandSpec = serde_json::from_str(r#"["echo", "hello", "world"]"#).unwrap();
        assert!(matches!(array, CommandSpec::Array(_)));
        assert_eq!(array.program(), "echo");
        assert_eq!(array.args(), vec!["hello", "world"]);
    }

    #[test]
    fn test_command_spec_serialization() {
        let simple = CommandSpec::Simple("python script.py".to_string());
        let json = serde_json::to_string(&simple).unwrap();
        assert_eq!(json, r#""python script.py""#);

        let array = CommandSpec::Array(vec![
            "python".to_string(),
            "script.py".to_string(),
            "--verbose".to_string(),
        ]);
        let json = serde_json::to_string(&array).unwrap();
        assert_eq!(json, r#"["python","script.py","--verbose"]"#);
    }

    #[test]
    fn test_empty_command() {
        let spec = CommandSpec::Simple("".to_string());
        assert_eq!(spec.program(), "");
        assert!(spec.args().is_empty());

        let spec = CommandSpec::Array(vec![]);
        assert_eq!(spec.program(), "");
        assert!(spec.args().is_empty());
    }

    #[test]
    fn test_multiple_processes() {
        let json = r#"{
            "processes": {
                "frontend": {
                    "command": "npm start",
                    "owns": "frontend-state.json",
                    "cwd": "/app/frontend"
                },
                "backend": {
                    "command": ["cargo", "run", "--release"],
                    "owns": "backend-state.json",
                    "cwd": "/app/backend"
                }
            }
        }"#;

        let config = ProcessesConfig::parse(json).unwrap();
        assert_eq!(config.processes.len(), 2);
        assert!(config.processes.contains_key("frontend"));
        assert!(config.processes.contains_key("backend"));
    }
}
