use super::subscription::{BlueSubscription, RedSubscription, Subscription};
use super::types::{Edit, Event, NodeError, NodeId};
use super::Node;
use async_trait::async_trait;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::broadcast;

/// A transient node representing an SSE connection.
///
/// ConnectionNode is created when an SSE client connects to subscribe to a document.
/// It has a server-generated UUID and is automatically cleaned up when the TCP
/// connection closes.
///
/// ## Ports
///
/// - **Blue port (outbound)**: Forwards edits from the target document to the SSE client
/// - **Red port**: Has its own red port for receiving events from clients
///
/// ## Lifecycle
///
/// 1. Client connects via `GET /sse/nodes/:id`
/// 2. Server creates ConnectionNode with server-generated UUID
/// 3. ConnectionNode subscribes to target document's blue port
/// 4. Client receives edits via SSE stream
/// 5. When TCP connection closes, ConnectionNode is unregistered
pub struct ConnectionNode {
    /// Server-generated UUID for this connection
    id: NodeId,
    /// The document node this connection subscribes to
    target_id: NodeId,
    /// Reference to target node for blue subscription
    target: Arc<dyn Node>,
    /// Red channel for events directed at this connection
    red_tx: broadcast::Sender<Event>,
    /// Shutdown flag
    is_shutdown: AtomicBool,
}

impl ConnectionNode {
    /// Create a new ConnectionNode that subscribes to the given target node.
    /// The connection will have a server-generated UUID.
    pub fn new(target: Arc<dyn Node>) -> Self {
        let id = NodeId::new(uuid::Uuid::new_v4().to_string());
        let (red_tx, _) = broadcast::channel(256);

        Self {
            id,
            target_id: target.id().clone(),
            target,
            red_tx,
            is_shutdown: AtomicBool::new(false),
        }
    }

    /// Create a new ConnectionNode with a specific ID (for testing)
    pub fn with_id(id: impl Into<String>, target: Arc<dyn Node>) -> Self {
        let (red_tx, _) = broadcast::channel(256);

        Self {
            id: NodeId::new(id),
            target_id: target.id().clone(),
            target,
            red_tx,
            is_shutdown: AtomicBool::new(false),
        }
    }

    /// Get the target node ID that this connection subscribes to
    pub fn target_id(&self) -> &NodeId {
        &self.target_id
    }

    /// Get a blue subscription from the target node.
    /// This is the primary way to get edits for the SSE stream.
    pub fn get_target_blue_subscription(&self) -> BlueSubscription {
        self.target.subscribe_blue()
    }
}

#[async_trait]
impl Node for ConnectionNode {
    fn id(&self) -> &NodeId {
        &self.id
    }

    fn node_type(&self) -> &'static str {
        "connection"
    }

    /// ConnectionNode doesn't process edits - it's a subscriber, not a document
    async fn receive_edit(&self, _edit: Edit) -> Result<(), NodeError> {
        if self.is_shutdown.load(Ordering::Relaxed) {
            return Err(NodeError::Shutdown);
        }
        // Connection nodes don't store or process edits
        // They're read-only subscribers to documents
        Ok(())
    }

    /// Forward events to red port subscribers
    async fn receive_event(&self, event: Event) -> Result<(), NodeError> {
        if self.is_shutdown.load(Ordering::Relaxed) {
            return Err(NodeError::Shutdown);
        }

        // Forward to our red subscribers with our ID as source
        let outgoing_event = Event {
            source: self.id.clone(),
            ..event
        };
        let _ = self.red_tx.send(outgoing_event);
        Ok(())
    }

    /// Subscribe to blue port - forwards from target document
    fn subscribe_blue(&self) -> BlueSubscription {
        // Forward to target's blue subscription
        self.target.subscribe_blue()
    }

    /// Subscribe to red port - our own event broadcasts
    fn subscribe_red(&self) -> RedSubscription {
        RedSubscription::new(self.id.clone(), self.red_tx.subscribe())
    }

    /// Subscribe to both ports
    fn subscribe(&self) -> Subscription {
        Subscription::new(
            self.id.clone(),
            self.target.subscribe_blue().receiver,
            self.red_tx.subscribe(),
        )
    }

    fn blue_subscriber_count(&self) -> usize {
        // We don't have our own blue channel - we forward from target
        0
    }

    fn red_subscriber_count(&self) -> usize {
        self.red_tx.receiver_count()
    }

    async fn shutdown(&self) -> Result<(), NodeError> {
        self.is_shutdown.store(true, Ordering::Relaxed);
        Ok(())
    }

    fn is_healthy(&self) -> bool {
        !self.is_shutdown.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::ContentType;
    use crate::node::DocumentNode;

    #[tokio::test]
    async fn test_connection_node_creation() {
        let doc = Arc::new(DocumentNode::new("doc-1", ContentType::Json));
        let conn = ConnectionNode::new(doc.clone());

        assert_eq!(conn.node_type(), "connection");
        assert_eq!(conn.target_id().0, "doc-1");
        assert!(conn.is_healthy());
        // Connection node has its own UUID
        assert_ne!(conn.id().0, "doc-1");
    }

    #[tokio::test]
    async fn test_connection_node_with_id() {
        let doc = Arc::new(DocumentNode::new("doc-1", ContentType::Json));
        let conn = ConnectionNode::with_id("conn-123", doc.clone());

        assert_eq!(conn.id().0, "conn-123");
        assert_eq!(conn.target_id().0, "doc-1");
    }

    #[tokio::test]
    async fn test_connection_node_red_events() {
        let doc = Arc::new(DocumentNode::new("doc-1", ContentType::Json));
        let conn = ConnectionNode::new(doc.clone());

        // Subscribe to red port
        let mut red_sub = conn.subscribe_red();

        // Send an event to the connection
        let event = Event {
            event_type: "cursor".to_string(),
            payload: serde_json::json!({"x": 100}),
            source: NodeId::new("external"),
        };
        conn.receive_event(event).await.unwrap();

        // Should receive it with connection's ID as source
        let received = red_sub.recv().await.unwrap();
        assert_eq!(received.event_type, "cursor");
        assert_eq!(received.source, *conn.id());
    }

    #[tokio::test]
    async fn test_connection_node_shutdown() {
        let doc = Arc::new(DocumentNode::new("doc-1", ContentType::Json));
        let conn = ConnectionNode::new(doc.clone());

        assert!(conn.is_healthy());
        conn.shutdown().await.unwrap();
        assert!(!conn.is_healthy());

        // Events should fail after shutdown
        let event = Event {
            event_type: "test".to_string(),
            payload: serde_json::json!({}),
            source: NodeId::new("other"),
        };
        let result = conn.receive_event(event).await;
        assert!(matches!(result, Err(NodeError::Shutdown)));
    }
}
