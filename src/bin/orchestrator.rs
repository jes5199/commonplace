//! commonplace-orchestrator: Process supervisor for commonplace services
//!
//! Starts and manages child processes (store, http) with automatic restart on failure.

use clap::Parser;
use commonplace_doc::cli::OrchestratorArgs;
use commonplace_doc::orchestrator::{OrchestratorConfig, ProcessManager};
use std::net::TcpStream;
use std::time::Duration;
use tokio::signal;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[tokio::main]
async fn main() {
    let args = OrchestratorArgs::parse();

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    tracing::info!("[orchestrator] Starting commonplace-orchestrator");
    tracing::info!("[orchestrator] Config file: {:?}", args.config);

    let config = match OrchestratorConfig::load(&args.config) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("[orchestrator] Failed to load config: {}", e);
            std::process::exit(1);
        }
    };

    let broker = args.mqtt_broker.as_ref().unwrap_or(&config.mqtt_broker);

    tracing::info!("[orchestrator] Checking MQTT broker at {}", broker);
    match TcpStream::connect_timeout(
        &broker.parse().expect("Invalid broker address"),
        Duration::from_secs(5),
    ) {
        Ok(_) => {
            tracing::info!("[orchestrator] MQTT broker is reachable");
        }
        Err(e) => {
            tracing::error!(
                "[orchestrator] Cannot connect to MQTT broker at {}: {}",
                broker,
                e
            );
            tracing::error!(
                "[orchestrator] Make sure mosquitto is running (systemctl status mosquitto)"
            );
            std::process::exit(1);
        }
    }

    let mut manager = ProcessManager::new(config, args.mqtt_broker.clone(), args.disable.clone());

    if let Some(only) = &args.only {
        tracing::info!("[orchestrator] Running only: {}", only);
        if let Err(e) = manager.spawn_process(only).await {
            tracing::error!("[orchestrator] Failed to start '{}': {}", only, e);
            std::process::exit(1);
        }
        // Wait for the single process
        tokio::select! {
            _ = signal::ctrl_c() => {
                tracing::info!("[orchestrator] Received Ctrl+C");
            }
        }
        manager.shutdown().await;
    } else {
        // Spawn the run loop in a task so we can handle shutdown
        let run_handle = tokio::spawn(async move {
            if let Err(e) = manager.run().await {
                tracing::error!("[orchestrator] Run error: {}", e);
            }
            manager
        });

        tokio::select! {
            _ = signal::ctrl_c() => {
                tracing::info!("[orchestrator] Received Ctrl+C");
            }
        }

        // Abort the run loop and get manager back for shutdown
        run_handle.abort();
        // Note: We can't easily get the manager back after abort, so we'll just exit
        // The OS will clean up child processes
        tracing::info!("[orchestrator] Shutdown complete");
    }
}
