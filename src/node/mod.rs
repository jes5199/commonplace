pub mod connection_node;
pub mod document_node;
pub mod registry;
pub mod subscription;
pub mod types;

use async_trait::async_trait;

pub use connection_node::ConnectionNode;
pub use document_node::DocumentNode;
pub use registry::NodeRegistry;
pub use subscription::{BlueSubscription, RedSubscription, Subscription, SubscriptionId};
pub use types::{Edit, Event, NodeError, NodeId, NodeMessage, Port};

/// Trait defining the interface for all nodes in the document graph.
///
/// Nodes are the fundamental building blocks that:
/// - Receive and apply edits (commits/Yjs updates) via the blue port
/// - Receive and handle ephemeral events via the red port
/// - Emit edits and events to subscribers
/// - Manage subscriptions from other nodes or external clients
///
/// ## Blue and Red Ports
///
/// Each node has two logical ports:
/// - **Blue port**: For persistent edits (Yjs commits). Subscribe to watch changes,
///   push to edit. Edits require parent context from listening first.
/// - **Red port**: For ephemeral events (JSON envelopes). Any client can fire
///   events without subscription. Subscribe to watch broadcasts.
#[async_trait]
pub trait Node: Send + Sync {
    /// Returns the unique identifier for this node
    fn id(&self) -> &NodeId;

    /// Returns a human-readable description of this node's type
    fn node_type(&self) -> &'static str;

    // --- Receiving ---

    /// Receive an edit from another node or external source.
    /// The node should apply this edit to its internal state and emit to blue subscribers.
    async fn receive_edit(&self, edit: Edit) -> Result<(), NodeError>;

    /// Receive an ephemeral event from another node or external source.
    /// Events are not persisted. The node should emit to red subscribers.
    async fn receive_event(&self, event: Event) -> Result<(), NodeError>;

    // --- Port-specific subscriptions ---

    /// Subscribe to the blue port (edits only).
    /// Returns a BlueSubscription that receives only Edit messages.
    fn subscribe_blue(&self) -> BlueSubscription;

    /// Subscribe to the red port (events only).
    /// Returns a RedSubscription that receives only Event messages.
    fn subscribe_red(&self) -> RedSubscription;

    /// Subscribe to both ports (legacy behavior).
    /// Returns a combined Subscription that receives both edits and events.
    fn subscribe(&self) -> Subscription;

    // --- Subscriber counts ---

    /// Get the number of active blue port subscribers
    fn blue_subscriber_count(&self) -> usize;

    /// Get the number of active red port subscribers
    fn red_subscriber_count(&self) -> usize;

    /// Get the total number of active subscribers (both ports)
    fn subscriber_count(&self) -> usize {
        self.blue_subscriber_count() + self.red_subscriber_count()
    }

    // --- Lifecycle ---

    /// Gracefully shut down this node
    async fn shutdown(&self) -> Result<(), NodeError>;

    /// Check if the node is healthy and operational
    fn is_healthy(&self) -> bool;
}

/// Extension trait for nodes that can be observed for specific content
#[async_trait]
pub trait ObservableNode: Node {
    /// Get the current rendered content (e.g., document text/JSON/XML)
    async fn get_content(&self) -> Result<String, NodeError>;

    /// Get content type (MIME type)
    fn content_type(&self) -> &str;
}
