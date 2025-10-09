use axum::{
    extract::{Path, State},
    response::sse::{Event, Sse},
    routing::get,
    Router,
};
use futures::stream::Stream;
use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;

use crate::document::DocumentStore;

#[derive(Clone)]
pub struct SseState {
    pub store: Arc<DocumentStore>,
}

pub fn router() -> Router {
    let store = Arc::new(DocumentStore::new());
    let state = SseState { store };

    Router::new()
        .route("/documents/:id", get(subscribe_to_document))
        .with_state(state)
}

async fn subscribe_to_document(
    State(_state): State<SseState>,
    Path(id): Path<String>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    // For now, this is a placeholder that sends a heartbeat
    // In a full implementation, this would use Yjs awareness or observation
    // to broadcast actual document updates

    let mut interval = tokio::time::interval(Duration::from_secs(30));

    let stream = async_stream::stream! {
        loop {
            interval.tick().await;
            yield Ok(Event::default()
                .event("heartbeat")
                .data(format!("Document {} is alive", id)));
        }
    };

    Sse::new(stream)
}
