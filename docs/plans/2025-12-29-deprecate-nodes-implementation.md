# Deprecate Node Abstraction - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove the "node" abstraction entirely - documents are just documents, identified by UUID, with paths mapped via fs-root.

**Architecture:** Delete src/node/ and src/router/ directories. DocumentStore holds UUID→Document. Path resolution reads fs-root JSON to find UUID. MQTT edits look up UUID from path, apply to DocumentStore. SSE subscribes to MQTT topics. HTTP gateway is stateless.

**Tech Stack:** Rust, MQTT (rumqttc), Yjs (yrs), Axum

**Success Criteria:** Sync tool can sync edits between two copies of the same directory.

---

## Task 1: Delete Router Module (Unused)

The router module is not used - no `--routers` args in any config.

**Files:**
- Delete: `src/router/mod.rs`
- Delete: `src/router/manager.rs`
- Delete: `src/router/schema.rs`
- Delete: `src/router/error.rs`
- Modify: `src/lib.rs` - Remove `pub mod router;`
- Modify: `src/cli.rs` - Remove `--routers` arg from StoreArgs
- Modify: `src/bin/store.rs` - Remove router initialization

**Step 1: Delete the router directory**

```bash
rm -rf src/router/
```

**Step 2: Update src/lib.rs - remove router export**

Remove this line:
```rust
pub mod router;
```

**Step 3: Update src/cli.rs - remove --routers arg**

In `StoreArgs`, remove:
```rust
    #[clap(long, value_name = "PATH")]
    pub routers: Vec<String>,
```

**Step 4: Update src/bin/store.rs - remove router code**

Remove these imports:
```rust
use commonplace_doc::router::RouterManager;
```

Remove router path validation (lines ~46-55):
```rust
    for router_path in &args.routers {
        // ... validation code
    }
```

Remove router initialization (lines ~109-126):
```rust
    // Initialize router documents
    for router_id_str in &args.routers {
        // ... router init code
    }
```

Remove router subscription (lines ~166-173):
```rust
    // Subscribe to router documents
    for router_id_str in &args.routers {
        // ...
    }
```

**Step 5: Run tests**

```bash
cargo test
```
Expected: All tests pass (router had no tests)

**Step 6: Commit**

```bash
git add -A && git commit -m "CP-li3: Delete unused router module"
```

---

## Task 2: Add Path Resolution Utility

Create a utility to resolve path→UUID from fs-root JSON content.

**Files:**
- Modify: `src/document.rs` - Add `resolve_path_to_uuid` function

**Step 1: Write the test**

Add to `src/document.rs` in the test module:

```rust
#[test]
fn test_resolve_path_to_uuid() {
    let fs_root = r#"{
        "notes": {
            "todo.txt": {"_uuid": "abc-123"},
            "ideas.md": {"_uuid": "def-456"}
        },
        "readme.txt": {"_uuid": "ghi-789"}
    }"#;

    assert_eq!(
        resolve_path_to_uuid(fs_root, "notes/todo.txt"),
        Some("abc-123".to_string())
    );
    assert_eq!(
        resolve_path_to_uuid(fs_root, "readme.txt"),
        Some("ghi-789".to_string())
    );
    assert_eq!(
        resolve_path_to_uuid(fs_root, "nonexistent.txt"),
        None
    );
}
```

**Step 2: Run test to verify it fails**

```bash
cargo test test_resolve_path_to_uuid
```
Expected: FAIL - function not defined

**Step 3: Implement the function**

Add to `src/document.rs`:

```rust
/// Resolve a path to a UUID by parsing fs-root JSON content.
/// Returns None if path not found or JSON invalid.
pub fn resolve_path_to_uuid(fs_root_content: &str, path: &str) -> Option<String> {
    let json: serde_json::Value = serde_json::from_str(fs_root_content).ok()?;

    let parts: Vec<&str> = path.split('/').collect();
    let mut current = &json;

    for part in parts {
        current = current.get(part)?;
    }

    // The leaf should have a _uuid field
    current.get("_uuid")?.as_str().map(|s| s.to_string())
}
```

**Step 4: Run test to verify it passes**

```bash
cargo test test_resolve_path_to_uuid
```
Expected: PASS

**Step 5: Commit**

```bash
git add src/document.rs && git commit -m "CP-li3: Add path to UUID resolution utility"
```

---

## Task 3: Add Create Document Method to DocumentStore

Ensure DocumentStore can create a document and return the UUID.

**Files:**
- Modify: `src/document.rs` - Verify `create_document` returns UUID

**Step 1: Verify existing behavior**

Check that `create_document` already returns UUID (it does). Add a test to confirm:

```rust
#[tokio::test]
async fn test_create_document_returns_uuid() {
    let store = DocumentStore::new();
    let uuid = store.create_document(ContentType::Text).await;

    // UUID should be valid format
    assert!(uuid.len() == 36); // UUID v4 format
    assert!(uuid.contains('-'));

    // Document should be retrievable
    let doc = store.get_document(&uuid).await;
    assert!(doc.is_some());
}
```

**Step 2: Run test**

```bash
cargo test test_create_document_returns_uuid
```
Expected: PASS (functionality already exists)

**Step 3: Commit**

```bash
git add src/document.rs && git commit -m "CP-li3: Add test for create_document UUID return"
```

---

## Task 4: Update MQTT Edits Handler

Change from NodeRegistry to DocumentStore with path resolution.

**Files:**
- Modify: `src/mqtt/edits.rs` - Use DocumentStore instead of NodeRegistry

**Step 1: Update imports and struct**

Replace:
```rust
use crate::node::{Edit, NodeId, NodeRegistry};
```

With:
```rust
use crate::document::{DocumentStore, resolve_path_to_uuid};
```

Update struct:
```rust
pub struct EditsHandler {
    client: Arc<MqttClient>,
    document_store: Arc<DocumentStore>,
    commit_store: Option<Arc<CommitStore>>,
    fs_root_content: RwLock<String>,  // Cache of fs-root JSON
    subscribed_paths: RwLock<HashSet<String>>,
}
```

**Step 2: Update constructor**

```rust
pub fn new(
    client: Arc<MqttClient>,
    document_store: Arc<DocumentStore>,
    commit_store: Option<Arc<CommitStore>>,
) -> Self {
    Self {
        client,
        document_store,
        commit_store,
        fs_root_content: RwLock::new(String::new()),
        subscribed_paths: RwLock::new(HashSet::new()),
    }
}
```

**Step 3: Add method to update fs-root cache**

```rust
pub async fn set_fs_root_content(&self, content: String) {
    let mut fs_root = self.fs_root_content.write().await;
    *fs_root = content;
}
```

**Step 4: Update handle_edit to use path resolution**

Replace the node registry lookup with:
```rust
pub async fn handle_edit(&self, topic: &Topic, payload: &[u8]) -> Result<(), MqttError> {
    // Parse the edit message
    let edit_msg: EditMessage = serde_json::from_slice(payload)
        .map_err(|e| MqttError::InvalidMessage(e.to_string()))?;

    debug!(
        "Received edit for path: {} from author: {}",
        topic.path, edit_msg.author
    );

    // Resolve path to UUID
    let fs_root = self.fs_root_content.read().await;
    let uuid = resolve_path_to_uuid(&fs_root, &topic.path)
        .ok_or_else(|| MqttError::InvalidTopic(format!("Path not mounted: {}", topic.path)))?;
    drop(fs_root);

    // ... rest of commit handling stays similar but uses document_store.apply_yjs_update(uuid, ...)
```

**Step 5: Run tests and fix compilation**

```bash
cargo build
cargo test
```

Fix any compilation errors.

**Step 6: Commit**

```bash
git add src/mqtt/edits.rs && git commit -m "CP-li3: Update EditsHandler to use DocumentStore"
```

---

## Task 5: Add Create-Document MQTT Command

Add the new command for creating documents.

**Files:**
- Modify: `src/mqtt/messages.rs` - Add CreateDocumentRequest/Response
- Modify: `src/mqtt/commands.rs` - Handle create-document command

**Step 1: Add message types**

In `src/mqtt/messages.rs`, add:

```rust
/// Request to create a new document
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateDocumentRequest {
    pub req: String,
    pub content_type: String,
}

/// Response with created document UUID
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateDocumentResponse {
    pub req: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uuid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}
```

**Step 2: Update CommandsHandler**

Replace NodeRegistry with DocumentStore:
```rust
pub struct CommandsHandler {
    client: Arc<MqttClient>,
    document_store: Arc<DocumentStore>,
    subscribed_commands: RwLock<HashMap<String, HashSet<String>>>,
}
```

**Step 3: Add create-document handler**

```rust
pub async fn handle_create_document(&self, payload: &[u8]) -> Result<(), MqttError> {
    let request: CreateDocumentRequest = serde_json::from_slice(payload)
        .map_err(|e| MqttError::InvalidMessage(e.to_string()))?;

    let content_type = ContentType::from_mime(&request.content_type)
        .ok_or_else(|| MqttError::InvalidMessage("Invalid content type".to_string()))?;

    let uuid = self.document_store.create_document(content_type).await;

    let response = CreateDocumentResponse {
        req: request.req,
        uuid: Some(uuid),
        error: None,
    };

    // Publish response to $store/responses
    let payload = serde_json::to_vec(&response)
        .map_err(|e| MqttError::InvalidMessage(e.to_string()))?;
    self.client.publish("$store/responses", &payload).await?;

    Ok(())
}
```

**Step 4: Run tests**

```bash
cargo test
```

**Step 5: Commit**

```bash
git add src/mqtt/messages.rs src/mqtt/commands.rs && git commit -m "CP-li3: Add create-document MQTT command"
```

---

## Task 6: Update Filesystem Reconciler

Change from NodeRegistry to DocumentStore.

**Files:**
- Modify: `src/fs/reconciler.rs` - Use DocumentStore

**Step 1: Update imports and struct**

Replace NodeRegistry references with DocumentStore.

**Step 2: Update reconciliation logic**

The reconciler watches fs-root for changes and creates document nodes. After this change, it should:
- Parse fs-root JSON
- For each document entry, ensure UUID exists in DocumentStore (create if missing)
- Update the EditsHandler's fs-root cache

**Step 3: Run tests**

```bash
cargo test
```

**Step 4: Commit**

```bash
git add src/fs/reconciler.rs && git commit -m "CP-li3: Update FilesystemReconciler to use DocumentStore"
```

---

## Task 7: Update SSE to Use MQTT

Change SSE from local node subscriptions to MQTT topic subscriptions.

**Files:**
- Modify: `src/sse.rs` - Subscribe to MQTT topics instead of nodes

**Step 1: Update SSE handler**

Instead of getting a node and subscribing to its broadcast channel, subscribe to the MQTT topic for that path and forward messages.

The HTTP gateway needs an MQTT client. Pass it in or create one.

**Step 2: Update the SSE stream**

```rust
pub async fn create_sse_stream(
    mqtt_client: Arc<MqttClient>,
    path: String,
) -> impl Stream<Item = Event> {
    // Subscribe to path/edits topic
    // Forward MQTT messages as SSE events
}
```

**Step 3: Run tests**

```bash
cargo test
```

**Step 4: Commit**

```bash
git add src/sse.rs && git commit -m "CP-li3: Update SSE to use MQTT subscriptions"
```

---

## Task 8: Update Store Binary

Switch from NodeRegistry to DocumentStore.

**Files:**
- Modify: `src/bin/store.rs` - Use DocumentStore

**Step 1: Replace NodeRegistry with DocumentStore**

```rust
// Before
let node_registry = Arc::new(NodeRegistry::new());

// After
let document_store = Arc::new(DocumentStore::new());
```

**Step 2: Update MqttService initialization**

Pass DocumentStore instead of NodeRegistry.

**Step 3: Update FilesystemReconciler initialization**

Pass DocumentStore instead of NodeRegistry.

**Step 4: Run and test**

```bash
cargo run --bin commonplace-store -- --database ./test.redb --fs-root fs-root.json --mqtt-broker localhost:1883
```

**Step 5: Commit**

```bash
git add src/bin/store.rs && git commit -m "CP-li3: Update store binary to use DocumentStore"
```

---

## Task 9: Update HTTP Binary (Ensure Stateless)

Verify HTTP binary has no local document storage.

**Files:**
- Modify: `src/bin/http.rs` - Remove any node references

**Step 1: Check current state**

The HTTP binary should already be mostly stateless. Verify it doesn't create NodeRegistry.

**Step 2: Update SSE endpoint**

Pass MQTT client to SSE handler for topic subscriptions.

**Step 3: Commit**

```bash
git add src/bin/http.rs && git commit -m "CP-li3: Ensure HTTP binary is stateless"
```

---

## Task 10: Delete Node Module

After all consumers are updated, delete the node abstraction.

**Files:**
- Delete: `src/node/mod.rs`
- Delete: `src/node/document_node.rs`
- Delete: `src/node/connection_node.rs`
- Delete: `src/node/registry.rs`
- Delete: `src/node/subscription.rs`
- Delete: `src/node/types.rs`
- Modify: `src/lib.rs` - Remove `pub mod node;`

**Step 1: Delete node directory**

```bash
rm -rf src/node/
```

**Step 2: Update lib.rs**

Remove:
```rust
pub mod node;
```

**Step 3: Fix any remaining references**

```bash
cargo build 2>&1 | grep "error\[E"
```

Fix any remaining NodeRegistry/Node references.

**Step 4: Run tests**

```bash
cargo test
```

**Step 5: Commit**

```bash
git add -A && git commit -m "CP-li3: Delete node module"
```

---

## Task 11: Remove /nodes API Endpoints

Delete the REST API endpoints for node management.

**Files:**
- Modify: `src/api.rs` - Remove all `/nodes/*` routes

**Step 1: Remove node endpoints**

Delete these route handlers:
- `POST /nodes`
- `GET /nodes`
- `GET /nodes/{id}`
- `DELETE /nodes/{id}`
- `POST /nodes/{from}/wire/{to}`
- `DELETE /nodes/{from}/wire/{to}`

**Step 2: Update router in lib.rs**

Remove node routes from the Axum router.

**Step 3: Run tests**

```bash
cargo test
```

**Step 4: Commit**

```bash
git add src/api.rs src/lib.rs && git commit -m "CP-li3: Remove /nodes API endpoints"
```

---

## Task 12: Update MqttService

Update the MqttService to use DocumentStore.

**Files:**
- Modify: `src/mqtt/mod.rs` - Change from NodeRegistry to DocumentStore

**Step 1: Update MqttService struct and constructor**

Replace `node_registry: Arc<NodeRegistry>` with `document_store: Arc<DocumentStore>`.

**Step 2: Update handler initialization**

Pass DocumentStore to EditsHandler and CommandsHandler.

**Step 3: Run tests**

```bash
cargo test
```

**Step 4: Commit**

```bash
git add src/mqtt/mod.rs && git commit -m "CP-li3: Update MqttService to use DocumentStore"
```

---

## Task 13: Integration Test - Sync Between Directories

Test that the sync tool can sync edits between two copies.

**Files:**
- Create test script or manual test

**Step 1: Start mosquitto**

```bash
systemctl status mosquitto
```

**Step 2: Start store**

```bash
cargo run --bin commonplace-store -- --database ./test.redb --fs-root fs-root.json --mqtt-broker localhost:1883
```

**Step 3: Create a test document**

Use MQTT to create a document and mount it:
1. Publish create-document command
2. Edit fs-root to mount UUID at path
3. Edit the document

**Step 4: Start sync in directory A**

```bash
cargo run --bin commonplace-sync -- --path ./dir-a --mqtt-broker localhost:1883
```

**Step 5: Start sync in directory B**

```bash
cargo run --bin commonplace-sync -- --path ./dir-b --mqtt-broker localhost:1883
```

**Step 6: Edit file in A, verify it appears in B**

```bash
echo "test content" >> ./dir-a/test.txt
sleep 2
cat ./dir-b/test.txt
```

**Step 7: Commit if tests pass**

```bash
git add -A && git commit -m "CP-li3: Integration test passing"
```

---

## Task 14: Clean Up Unused Dependencies

Remove any crates that are no longer needed.

**Files:**
- Modify: `Cargo.toml`

**Step 1: Check for unused deps**

```bash
cargo build 2>&1 | grep "unused"
```

**Step 2: Remove unused dependencies from Cargo.toml**

**Step 3: Run tests**

```bash
cargo test
```

**Step 4: Commit**

```bash
git add Cargo.toml Cargo.lock && git commit -m "CP-li3: Remove unused dependencies"
```
