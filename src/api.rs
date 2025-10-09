use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{delete, get, post, put},
    Router,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::document::DocumentStore;

#[derive(Clone)]
pub struct ApiState {
    pub store: Arc<DocumentStore>,
}

pub fn router() -> Router {
    let store = Arc::new(DocumentStore::new());
    let state = ApiState { store };

    Router::new()
        .route("/documents", post(create_document))
        .route("/documents/:id", get(get_document))
        .route("/documents/:id", put(update_document))
        .route("/documents/:id", delete(delete_document))
        .route("/documents", get(list_documents))
        .with_state(state)
}

#[derive(Deserialize)]
struct CreateDocumentRequest {
    name: Option<String>,
}

#[derive(Serialize)]
struct DocumentResponse {
    id: String,
    name: String,
}

async fn create_document(
    State(state): State<ApiState>,
    Json(payload): Json<CreateDocumentRequest>,
) -> Result<Json<DocumentResponse>, StatusCode> {
    let name = payload.name.clone();
    let id = state.store.create_document(payload.name).await;
    Ok(Json(DocumentResponse {
        id: id.clone(),
        name: name.unwrap_or_else(|| id),
    }))
}

async fn get_document(
    State(state): State<ApiState>,
    Path(id): Path<String>,
) -> Result<Json<Vec<u8>>, StatusCode> {
    state
        .store
        .get_document(&id)
        .await
        .map(Json)
        .ok_or(StatusCode::NOT_FOUND)
}

#[derive(Deserialize)]
struct UpdateDocumentRequest {
    update: Vec<u8>,
}

async fn update_document(
    State(state): State<ApiState>,
    Path(id): Path<String>,
    Json(payload): Json<UpdateDocumentRequest>,
) -> Result<StatusCode, StatusCode> {
    if state.store.apply_update(&id, payload.update).await {
        Ok(StatusCode::OK)
    } else {
        Err(StatusCode::NOT_FOUND)
    }
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

#[derive(Serialize)]
struct ListDocumentsResponse {
    documents: Vec<String>,
}

async fn list_documents(State(state): State<ApiState>) -> Json<ListDocumentsResponse> {
    let documents = state.store.list_documents().await;
    Json(ListDocumentsResponse { documents })
}
