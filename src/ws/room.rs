//! Document room for coordinating multiple WebSocket connections.

use super::connection::{ConnectionId, WsConnection};
use super::protocol;
use crate::document::DocumentStore;
use crate::events::{CommitBroadcaster, CommitNotification};
use crate::store::CommitStore;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::ReadTxn;
use yrs::Transact;

/// Error from room operations.
#[derive(Debug, thiserror::Error)]
pub enum RoomError {
    #[error("document not found")]
    DocumentNotFound,
    #[error("document has no Yjs state")]
    NoYjsState,
    #[error("failed to decode update: {0}")]
    DecodeError(String),
    #[error("failed to apply update: {0}")]
    ApplyError(String),
}

/// A room manages all WebSocket connections to a single document.
pub struct Room {
    /// Document ID
    doc_id: String,

    /// Connected clients
    connections: RwLock<HashMap<ConnectionId, Arc<RwLock<WsConnection>>>>,

    /// Document store for Yjs operations
    doc_store: Arc<DocumentStore>,

    /// Commit store for persistence (optional)
    commit_store: Option<Arc<CommitStore>>,

    /// Broadcaster for commit notifications (for Phase 2: commonplace extensions)
    #[allow(dead_code)]
    broadcaster: Option<CommitBroadcaster>,
}

impl Room {
    /// Create a new room for a document.
    pub fn new(
        doc_id: String,
        doc_store: Arc<DocumentStore>,
        commit_store: Option<Arc<CommitStore>>,
        broadcaster: Option<CommitBroadcaster>,
    ) -> Self {
        Self {
            doc_id,
            connections: RwLock::new(HashMap::new()),
            doc_store,
            commit_store,
            broadcaster,
        }
    }

    /// Add a connection to this room.
    pub async fn add_connection(&self, conn: Arc<RwLock<WsConnection>>) {
        let id = conn.read().await.id.clone();
        self.connections.write().await.insert(id, conn);
    }

    /// Remove a connection from this room.
    pub async fn remove_connection(&self, conn_id: &str) {
        self.connections.write().await.remove(conn_id);
    }

    /// Get the number of active connections.
    pub async fn connection_count(&self) -> usize {
        self.connections.read().await.len()
    }

    /// Handle SyncStep1 from a client (client sends its state vector).
    /// Returns SyncStep2 with the updates the client is missing.
    pub async fn handle_sync_step1(&self, state_vector_bytes: &[u8]) -> Result<Vec<u8>, RoomError> {
        // Get the document
        let doc = self
            .doc_store
            .get_document(&self.doc_id)
            .await
            .ok_or(RoomError::DocumentNotFound)?;

        let ydoc = doc.ydoc.as_ref().ok_or(RoomError::NoYjsState)?;

        // Decode client's state vector
        let client_sv = yrs::StateVector::decode_v1(state_vector_bytes)
            .map_err(|e| RoomError::DecodeError(e.to_string()))?;

        // Compute diff: what the client is missing
        let txn = ydoc.transact();
        let diff = txn.encode_state_as_update_v1(&client_sv);

        // Encode as SyncStep2
        Ok(protocol::encode_sync_step2(&diff))
    }

    /// Get server's state vector for SyncStep1 request to client.
    pub async fn get_state_vector(&self) -> Result<Vec<u8>, RoomError> {
        let doc = self
            .doc_store
            .get_document(&self.doc_id)
            .await
            .ok_or(RoomError::DocumentNotFound)?;

        let ydoc = doc.ydoc.as_ref().ok_or(RoomError::NoYjsState)?;

        let txn = ydoc.transact();
        let sv = txn.state_vector();
        Ok(sv.encode_v1())
    }

    /// Handle an update from a client.
    /// Applies to document store and broadcasts to other connections.
    pub async fn handle_update(&self, from_conn_id: &str, update: &[u8]) -> Result<(), RoomError> {
        // Apply to document store
        self.doc_store
            .apply_yjs_update(&self.doc_id, update)
            .await
            .map_err(|e| RoomError::ApplyError(format!("{:?}", e)))?;

        // Broadcast to other connections
        let encoded = protocol::encode_update(update);
        self.broadcast_except(from_conn_id, encoded).await;

        Ok(())
    }

    /// Broadcast a message to all connections except one.
    pub async fn broadcast_except(&self, except_conn_id: &str, message: Vec<u8>) {
        let connections = self.connections.read().await;
        for (conn_id, conn) in connections.iter() {
            if conn_id != except_conn_id {
                let conn = conn.read().await;
                // Non-blocking send, drop if buffer full
                let _ = conn.try_send_binary(message.clone());
            }
        }
    }

    /// Broadcast a message to all connections.
    pub async fn broadcast_all(&self, message: Vec<u8>) {
        let connections = self.connections.read().await;
        for conn in connections.values() {
            let conn = conn.read().await;
            let _ = conn.try_send_binary(message.clone());
        }
    }

    /// Handle a commit notification from the broadcaster.
    /// This is called when an edit comes in via HTTP API.
    pub async fn handle_commit_notification(&self, notification: &CommitNotification) {
        // Only handle notifications for this document
        if notification.doc_id != self.doc_id {
            return;
        }

        // Get the commit's update from the commit store
        if let Some(store) = &self.commit_store {
            if let Ok(commit) = store.get_commit(&notification.commit_id).await {
                // Decode the update from base64
                if let Ok(update_bytes) = crate::b64::decode(&commit.update) {
                    // Broadcast to all WebSocket connections
                    let encoded = protocol::encode_update(&update_bytes);
                    self.broadcast_all(encoded).await;
                }
            }
        }
    }

    /// Get document ID.
    pub fn doc_id(&self) -> &str {
        &self.doc_id
    }
}

/// Manager for all document rooms.
pub struct RoomManager {
    rooms: RwLock<HashMap<String, Arc<Room>>>,
    doc_store: Arc<DocumentStore>,
    commit_store: Option<Arc<CommitStore>>,
    broadcaster: Option<CommitBroadcaster>,
}

impl RoomManager {
    /// Create a new room manager.
    pub fn new(
        doc_store: Arc<DocumentStore>,
        commit_store: Option<Arc<CommitStore>>,
        broadcaster: Option<CommitBroadcaster>,
    ) -> Self {
        Self {
            rooms: RwLock::new(HashMap::new()),
            doc_store,
            commit_store,
            broadcaster,
        }
    }

    /// Get or create a room for a document.
    pub async fn get_or_create_room(&self, doc_id: &str) -> Arc<Room> {
        // Check with read lock first
        {
            let rooms = self.rooms.read().await;
            if let Some(room) = rooms.get(doc_id) {
                return room.clone();
            }
        }

        // Create with write lock
        let mut rooms = self.rooms.write().await;

        // Double-check
        if let Some(room) = rooms.get(doc_id) {
            return room.clone();
        }

        let room = Arc::new(Room::new(
            doc_id.to_string(),
            self.doc_store.clone(),
            self.commit_store.clone(),
            self.broadcaster.clone(),
        ));

        rooms.insert(doc_id.to_string(), room.clone());
        room
    }

    /// Remove empty rooms.
    pub async fn cleanup_empty_rooms(&self) {
        let mut rooms = self.rooms.write().await;
        let mut to_remove = Vec::new();

        for (doc_id, room) in rooms.iter() {
            if room.connection_count().await == 0 {
                to_remove.push(doc_id.clone());
            }
        }

        for doc_id in to_remove {
            rooms.remove(&doc_id);
        }
    }

    /// Get broadcaster for spawning listener task.
    pub fn broadcaster(&self) -> Option<&CommitBroadcaster> {
        self.broadcaster.as_ref()
    }

    /// Get all rooms (for broadcasting commit notifications).
    pub async fn get_all_rooms(&self) -> Vec<Arc<Room>> {
        self.rooms.read().await.values().cloned().collect()
    }
}
