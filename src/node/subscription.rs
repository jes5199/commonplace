use super::types::{Edit, Event, NodeId, NodeMessage};
use tokio::sync::broadcast;

/// A subscription to a node's blue port (edits only)
pub struct BlueSubscription {
    /// The node this subscription is from
    pub source: NodeId,
    /// Receiver for edit messages
    pub receiver: broadcast::Receiver<Edit>,
}

impl BlueSubscription {
    /// Create a new blue subscription
    pub fn new(source: NodeId, receiver: broadcast::Receiver<Edit>) -> Self {
        Self { source, receiver }
    }

    /// Receive the next edit, waiting if necessary
    pub async fn recv(&mut self) -> Result<Edit, broadcast::error::RecvError> {
        self.receiver.recv().await
    }
}

/// A subscription to a node's red port (events only)
pub struct RedSubscription {
    /// The node this subscription is from
    pub source: NodeId,
    /// Receiver for event messages
    pub receiver: broadcast::Receiver<Event>,
}

impl RedSubscription {
    /// Create a new red subscription
    pub fn new(source: NodeId, receiver: broadcast::Receiver<Event>) -> Self {
        Self { source, receiver }
    }

    /// Receive the next event, waiting if necessary
    pub async fn recv(&mut self) -> Result<Event, broadcast::error::RecvError> {
        self.receiver.recv().await
    }
}

/// A combined subscription to both ports (legacy behavior)
pub struct Subscription {
    /// The node this subscription is from
    pub source: NodeId,
    /// Receiver for edit messages (blue port)
    blue: broadcast::Receiver<Edit>,
    /// Receiver for event messages (red port)
    red: broadcast::Receiver<Event>,
}

impl Subscription {
    /// Create a new combined subscription
    pub fn new(
        source: NodeId,
        blue: broadcast::Receiver<Edit>,
        red: broadcast::Receiver<Event>,
    ) -> Self {
        Self { source, blue, red }
    }

    /// Receive the next message from either port, waiting if necessary
    pub async fn recv(&mut self) -> Result<NodeMessage, broadcast::error::RecvError> {
        tokio::select! {
            biased;
            result = self.blue.recv() => result.map(NodeMessage::Edit),
            result = self.red.recv() => result.map(NodeMessage::Event),
        }
    }
}

/// A unique identifier for a subscription (used for unsubscribe/unwire)
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SubscriptionId(pub uuid::Uuid);

impl SubscriptionId {
    pub fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }
}

impl Default for SubscriptionId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for SubscriptionId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}
