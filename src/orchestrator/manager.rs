use super::{OrchestratorConfig, ProcessConfig};
use std::collections::HashMap;
use std::time::Instant;
use tokio::process::Child;

#[derive(Debug)]
pub struct ManagedProcess {
    pub config: ProcessConfig,
    pub handle: Option<Child>,
    pub state: ProcessState,
    pub consecutive_failures: u32,
    pub last_start: Option<Instant>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProcessState {
    Stopped,
    Starting,
    Running,
    Failed,
}

pub struct ProcessManager {
    config: OrchestratorConfig,
    processes: HashMap<String, ManagedProcess>,
    mqtt_broker_override: Option<String>,
    disabled: Vec<String>,
}

impl ProcessManager {
    pub fn new(
        config: OrchestratorConfig,
        mqtt_broker_override: Option<String>,
        disabled: Vec<String>,
    ) -> Self {
        let processes = config
            .processes
            .iter()
            .map(|(name, cfg)| {
                (
                    name.clone(),
                    ManagedProcess {
                        config: cfg.clone(),
                        handle: None,
                        state: ProcessState::Stopped,
                        consecutive_failures: 0,
                        last_start: None,
                    },
                )
            })
            .collect();

        Self {
            config,
            processes,
            mqtt_broker_override,
            disabled,
        }
    }

    pub fn mqtt_broker(&self) -> &str {
        self.mqtt_broker_override
            .as_deref()
            .unwrap_or(&self.config.mqtt_broker)
    }
}
