//! commonplace-orchestrator: Process supervisor for commonplace services
//!
//! This binary manages the lifecycle of commonplace-store and commonplace-http,
//! starting them with appropriate configuration and restarting on failure.

use clap::Parser;
use commonplace_doc::cli::OrchestratorArgs;

#[tokio::main]
async fn main() {
    let args = OrchestratorArgs::parse();
    println!("Config: {:?}", args.config);
}
