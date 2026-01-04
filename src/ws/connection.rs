//! Per-connection state for WebSocket connections.

use super::protocol::ProtocolMode;
use std::time::Instant;
use tokio::sync::mpsc;

/// Unique connection ID.
pub type ConnectionId = String;

/// Per-connection state.
#[derive(Debug)]
pub struct WsConnection {
    /// Unique connection ID (server-generated UUID)
    pub id: ConnectionId,

    /// Document ID this connection is subscribed to
    pub doc_id: String,

    /// Negotiated protocol mode
    pub protocol: ProtocolMode,

    /// Yjs client ID for this connection (used for origin tracking)
    pub client_id: u64,

    /// Last activity timestamp (for timeout detection)
    pub last_activity: Instant,

    /// Sender for outgoing messages to this connection
    pub sender: mpsc::Sender<OutgoingMessage>,
}

/// Outgoing message to send to a WebSocket client.
#[derive(Debug, Clone)]
pub enum OutgoingMessage {
    /// Binary message (Yjs updates, sync messages)
    Binary(Vec<u8>),
    /// Close the connection
    Close,
}

impl WsConnection {
    /// Create a new connection.
    pub fn new(
        doc_id: String,
        protocol: ProtocolMode,
        sender: mpsc::Sender<OutgoingMessage>,
    ) -> Self {
        let uuid = uuid::Uuid::new_v4();
        // Use first 8 bytes of UUID as client_id
        let uuid_bytes = uuid.as_bytes();
        let client_id = u64::from_le_bytes([
            uuid_bytes[0],
            uuid_bytes[1],
            uuid_bytes[2],
            uuid_bytes[3],
            uuid_bytes[4],
            uuid_bytes[5],
            uuid_bytes[6],
            uuid_bytes[7],
        ]);

        Self {
            id: uuid.to_string(),
            doc_id,
            protocol,
            client_id,
            last_activity: Instant::now(),
            sender,
        }
    }

    /// Update last activity timestamp.
    pub fn touch(&mut self) {
        self.last_activity = Instant::now();
    }

    /// Send a message to this connection (non-blocking).
    /// Returns false if the channel is full or closed.
    pub fn try_send(&self, msg: OutgoingMessage) -> bool {
        self.sender.try_send(msg).is_ok()
    }

    /// Send a binary message.
    pub fn try_send_binary(&self, data: Vec<u8>) -> bool {
        self.try_send(OutgoingMessage::Binary(data))
    }
}
