use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use serde::Serialize;
use std::sync::Arc;

use crate::document::{ContentType, DocumentStore};

#[derive(Clone)]
pub struct ApiState {
    pub store: Arc<DocumentStore>,
}

pub fn router() -> Router {
    let store = Arc::new(DocumentStore::new());
    let state = ApiState { store };

    Router::new()
        .route("/docs", post(create_document))
        .route("/docs/:id", get(get_document))
        .route("/docs/:id", delete(delete_document))
        .with_state(state)
}

#[derive(Serialize)]
struct CreateDocumentResponse {
    id: String,
}

async fn create_document(
    State(state): State<ApiState>,
    headers: HeaderMap,
) -> Result<Json<CreateDocumentResponse>, StatusCode> {
    // Get Content-Type header
    let content_type_str = headers
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/json");

    // Parse content type
    let content_type = ContentType::from_mime(content_type_str)
        .ok_or(StatusCode::UNSUPPORTED_MEDIA_TYPE)?;

    // Create document
    let id = state.store.create_document(content_type).await;

    Ok(Json(CreateDocumentResponse { id }))
}

async fn get_document(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Response, StatusCode> {
    let doc = state
        .store
        .get_document(&id)
        .await
        .ok_or(StatusCode::NOT_FOUND)?;

    // Return content with appropriate Content-Type header
    Ok((
        [(
            axum::http::header::CONTENT_TYPE,
            doc.content_type.to_mime(),
        )],
        doc.content,
    )
        .into_response())
}

async fn delete_document(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<StatusCode, StatusCode> {
    if state.store.delete_document(&id).await {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(StatusCode::NOT_FOUND)
    }
}
