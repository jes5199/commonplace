//! Integration tests for filesystem-in-JSON feature.

use commonplace_doc::{
    create_router_with_config,
    document::{ContentType, DocumentStore},
    fs::FilesystemReconciler,
    RouterConfig,
};
use std::sync::Arc;

/// Test that reconciler creates documents from filesystem JSON.
#[tokio::test]
async fn test_reconciler_creates_documents() {
    let store = Arc::new(DocumentStore::new());

    // Create fs-root document
    store
        .get_or_create_with_id("test-fs", ContentType::Json)
        .await;

    let reconciler = Arc::new(FilesystemReconciler::new(
        "test-fs".to_string(),
        store.clone(),
    ));

    // Reconcile with a simple filesystem
    let content = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "notes.txt": { "type": "doc" },
                "data.json": { "type": "doc", "content_type": "application/json" }
            }
        }
    }"#;

    reconciler.reconcile(content).await.unwrap();

    // Verify documents were created with derived IDs
    assert!(
        store.get_document("test-fs:notes.txt").await.is_some(),
        "notes.txt document should exist"
    );
    assert!(
        store.get_document("test-fs:data.json").await.is_some(),
        "data.json document should exist"
    );
}

/// Test that explicit node_id is used instead of derived ID.
#[tokio::test]
async fn test_reconciler_uses_explicit_node_id() {
    let store = Arc::new(DocumentStore::new());

    store
        .get_or_create_with_id("test-fs", ContentType::Json)
        .await;

    let reconciler = Arc::new(FilesystemReconciler::new(
        "test-fs".to_string(),
        store.clone(),
    ));

    let content = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "stable.txt": {
                    "type": "doc",
                    "node_id": "my-stable-id"
                }
            }
        }
    }"#;

    reconciler.reconcile(content).await.unwrap();

    // Verify explicit ID was used
    assert!(
        store.get_document("my-stable-id").await.is_some(),
        "explicit node ID should exist"
    );
    assert!(
        store.get_document("test-fs:stable.txt").await.is_none(),
        "derived ID should NOT exist"
    );
}

/// Test that removing entry from JSON doesn't delete the document.
#[tokio::test]
async fn test_reconciler_non_destructive() {
    let store = Arc::new(DocumentStore::new());

    store
        .get_or_create_with_id("test-fs", ContentType::Json)
        .await;

    let reconciler = Arc::new(FilesystemReconciler::new(
        "test-fs".to_string(),
        store.clone(),
    ));

    // First, create a document
    let content1 = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "file.txt": { "type": "doc" }
            }
        }
    }"#;

    reconciler.reconcile(content1).await.unwrap();

    assert!(store.get_document("test-fs:file.txt").await.is_some());

    // Remove entry from JSON
    let content2 = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {}
        }
    }"#;

    reconciler.reconcile(content2).await.unwrap();

    // Document should still exist (non-destructive)
    assert!(
        store.get_document("test-fs:file.txt").await.is_some(),
        "document should NOT be deleted"
    );
}

/// Test that invalid JSON triggers error.
#[tokio::test]
async fn test_reconciler_handles_invalid_json() {
    let store = Arc::new(DocumentStore::new());

    store
        .get_or_create_with_id("test-fs", ContentType::Json)
        .await;

    let reconciler = Arc::new(FilesystemReconciler::new(
        "test-fs".to_string(),
        store.clone(),
    ));

    let result = reconciler.reconcile("not valid json").await;
    assert!(result.is_err());
}

/// Test that invalid entry names are rejected.
#[tokio::test]
async fn test_reconciler_rejects_invalid_names() {
    let store = Arc::new(DocumentStore::new());

    store
        .get_or_create_with_id("test-fs", ContentType::Json)
        .await;

    let reconciler = Arc::new(FilesystemReconciler::new(
        "test-fs".to_string(),
        store.clone(),
    ));

    // Entry with slash in name
    let content = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "invalid/name": { "type": "doc" }
            }
        }
    }"#;

    let result = reconciler.reconcile(content).await;
    assert!(result.is_err());
}

/// Test that unsupported version is rejected.
#[tokio::test]
async fn test_reconciler_rejects_unsupported_version() {
    let store = Arc::new(DocumentStore::new());

    store
        .get_or_create_with_id("test-fs", ContentType::Json)
        .await;

    let reconciler = Arc::new(FilesystemReconciler::new(
        "test-fs".to_string(),
        store.clone(),
    ));

    let content = r#"{"version": 99}"#;

    let result = reconciler.reconcile(content).await;
    assert!(result.is_err());
}

/// Test that non-directory root is rejected.
#[tokio::test]
async fn test_reconciler_rejects_non_directory_root() {
    let store = Arc::new(DocumentStore::new());

    store
        .get_or_create_with_id("test-fs", ContentType::Json)
        .await;

    let reconciler = Arc::new(FilesystemReconciler::new(
        "test-fs".to_string(),
        store.clone(),
    ));

    // Root is a doc instead of a dir
    let content = r#"{
        "version": 1,
        "root": { "type": "doc" }
    }"#;

    let result = reconciler.reconcile(content).await;
    assert!(result.is_err(), "non-directory root should be rejected");
}

/// Test nested directories.
#[tokio::test]
async fn test_reconciler_nested_dirs() {
    let store = Arc::new(DocumentStore::new());

    store
        .get_or_create_with_id("test-fs", ContentType::Json)
        .await;

    let reconciler = Arc::new(FilesystemReconciler::new(
        "test-fs".to_string(),
        store.clone(),
    ));

    let content = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "level1": {
                    "type": "dir",
                    "entries": {
                        "level2": {
                            "type": "dir",
                            "entries": {
                                "deep.txt": { "type": "doc" }
                            }
                        }
                    }
                }
            }
        }
    }"#;

    reconciler.reconcile(content).await.unwrap();

    assert!(
        store
            .get_document("test-fs:level1/level2/deep.txt")
            .await
            .is_some(),
        "deeply nested document should exist"
    );
}

/// Test that documents are recreated if deleted externally.
#[tokio::test]
async fn test_reconciler_recreates_deleted_documents() {
    let store = Arc::new(DocumentStore::new());

    store
        .get_or_create_with_id("test-fs", ContentType::Json)
        .await;

    let reconciler = Arc::new(FilesystemReconciler::new(
        "test-fs".to_string(),
        store.clone(),
    ));

    let content = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "file.txt": { "type": "doc" }
            }
        }
    }"#;

    // First reconcile creates the document
    reconciler.reconcile(content).await.unwrap();

    assert!(store.get_document("test-fs:file.txt").await.is_some());

    // Delete the document externally (simulating DELETE /docs/:id)
    store.delete_document("test-fs:file.txt").await;
    assert!(
        store.get_document("test-fs:file.txt").await.is_none(),
        "document should be deleted"
    );

    // Re-reconcile should recreate the document
    reconciler.reconcile(content).await.unwrap();
    assert!(
        store.get_document("test-fs:file.txt").await.is_some(),
        "document should be recreated after external deletion"
    );
}

/// Test that router with fs_root creates the fs-root node.
#[tokio::test]
async fn test_router_with_fs_root() {
    let _app = create_router_with_config(RouterConfig {
        commit_store: None,
        fs_root: Some("my-filesystem".to_string()),
        mqtt: None,
        mqtt_subscribe: vec![],
    })
    .await;

    // The router should have created the fs-root node internally
    // This test mainly verifies that the async setup doesn't panic
}
