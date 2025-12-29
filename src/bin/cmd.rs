//! commonplace-cmd: Send commands to document paths via MQTT
//!
//! Usage:
//!   commonplace-cmd examples/counter.json increment
//!   commonplace-cmd examples/counter.json increment --payload '{"amount": 5}'
//!   commonplace-cmd examples/counter.json reset

use clap::Parser;
use commonplace_doc::{
    cli::CmdArgs,
    mqtt::{CommandMessage, MqttClient, MqttConfig, Topic},
};
use rumqttc::QoS;
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = CmdArgs::parse();

    // Parse the payload JSON
    let payload: serde_json::Value =
        serde_json::from_str(&args.payload).map_err(|e| format!("Invalid JSON payload: {}", e))?;

    // Build the command message
    let message = CommandMessage {
        payload,
        source: Some(args.source.clone()),
    };

    // Build the topic
    let topic = Topic::commands(&args.path, &args.verb);
    let topic_str = topic.to_topic_string();

    // Connect to MQTT
    let config = MqttConfig {
        broker_url: args.mqtt_broker.clone(),
        client_id: format!("commonplace-cmd-{}", uuid::Uuid::new_v4()),
        ..Default::default()
    };

    let client = MqttClient::connect(config).await?;

    // Need to poll the event loop once to establish connection
    // Spawn the event loop briefly
    let client_for_loop = std::sync::Arc::new(client);
    let client_clone = client_for_loop.clone();

    let loop_handle = tokio::spawn(async move {
        // Run for a short time to establish connection and send message
        let _ = tokio::time::timeout(Duration::from_secs(2), client_clone.run_event_loop()).await;
    });

    // Give the connection time to establish (500ms is generous for localhost)
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Publish the command
    let payload_bytes = serde_json::to_vec(&message)?;
    client_for_loop
        .publish(&topic_str, &payload_bytes, QoS::AtLeastOnce)
        .await?;

    println!("Sent {} to {}", args.verb, args.path);

    // Wait for PUBACK confirmation (500ms for QoS1 delivery)
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Cancel the event loop
    loop_handle.abort();

    Ok(())
}
