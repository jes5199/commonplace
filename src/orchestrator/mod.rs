mod config;
mod discovered_manager;
mod discovery;
mod manager;

pub use config::{OrchestratorConfig, ProcessConfig, RestartMode, RestartPolicy};
pub use discovered_manager::{
    DiscoveredProcessManager, DiscoveredProcessState, ManagedDiscoveredProcess,
};
pub use discovery::{CommandSpec, DiscoveredProcess, ProcessesConfig};
pub use manager::{ManagedProcess, ProcessManager, ProcessState};
