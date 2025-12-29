# Deprecate Node Abstraction - Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove the "node" abstraction entirely. Documents are just documents.

**Architecture:** Documents are stored by UUID (like inodes). Paths in fs-root map to UUIDs. MQTT handles all transport. HTTP gateway is stateless.

**Tech Stack:** Rust, MQTT, Yjs

---

## What Gets Deleted

### Directories
- `src/node/` - DocumentNode, Node trait, NodeRegistry, subscriptions, connection_node, all of it
- `src/router/` - RouterManager, wiring schema, error types

### Endpoints
- `POST /nodes` - Create node
- `GET /nodes` - List nodes
- `GET /nodes/{id}` - Get node info
- `DELETE /nodes/{id}` - Delete node
- `POST /nodes/{from}/wire/{to}` - Wire nodes
- `DELETE /nodes/{from}/wire/{to}` - Unwire nodes

### CLI Args
- `--routers` from store binary

---

## What Gets Enhanced

### `src/document.rs` - DocumentStore

Current: Simple HashMap with UUID keys, creates documents with generated UUIDs.

Keep as-is but ensure it has:
- `create_document(content_type) -> UUID` - Creates document, returns UUID
- `get_document(uuid) -> Option<Document>` - Get by UUID
- `apply_yjs_update(uuid, update)` - Apply Yjs update

The DocumentStore is only used by the **store binary**. HTTP binary is stateless.

---

## Data Model

### Documents (like inodes)
- Identified by UUID
- Contain: content string, content_type, Yjs doc
- Exist independently of paths

### fs-root (like directory)
- JSON document mapping paths to UUIDs
- Example:
```json
{
  "notes": {
    "todo.txt": {"_uuid": "abc-123"},
    "ideas.md": {"_uuid": "def-456"}
  }
}
```

### Path Resolution
```
Edit arrives for "notes/todo.txt"
  → Parse fs-root JSON
  → Find notes.todo.txt._uuid = "abc-123"
  → Get/apply to document with that UUID
  → If path not found → error (no auto-create)
```

---

## MQTT Changes

### New Command: create-document

**Topic:** `$store/commands/create-document`

**Request:**
```json
{
  "req": "r-001",
  "content_type": "text/plain"
}
```

**Response (success):**
```json
{
  "req": "r-001",
  "uuid": "abc-123-def-456"
}
```

**Response (error):**
```json
{
  "req": "r-001",
  "error": "Invalid content type"
}
```

Client subscribes to `$store/responses` before sending command.

### Edits Handler Changes

- Remove NodeRegistry dependency
- Use DocumentStore directly
- Look up UUID from fs-root, then apply to document by UUID
- Error if path not in fs-root

### Commands Handler Changes

- Remove NodeRegistry dependency
- Remove "red port" event dispatching
- Add create-document command handler

---

## SSE Changes

### Current
HTTP binary has NodeRegistry, SSE subscribes to local DocumentNode broadcast channels.

### New
HTTP binary is stateless. SSE subscribes to MQTT topics.

**Flow:**
```
Client: GET /sse/path/notes/todo.txt
  → HTTP gateway subscribes to MQTT topic "notes/todo.txt/edits"
  → Each MQTT message forwarded to SSE stream
  → On client disconnect, unsubscribe from MQTT
```

No local document storage in HTTP binary.

---

## Files to Modify

### Delete entirely
- `src/node/mod.rs`
- `src/node/document_node.rs`
- `src/node/connection_node.rs`
- `src/node/registry.rs`
- `src/node/subscription.rs`
- `src/node/types.rs`
- `src/router/mod.rs`
- `src/router/manager.rs`
- `src/router/schema.rs`
- `src/router/error.rs`

### Heavy modifications
- `src/lib.rs` - Remove node/router exports, update router setup
- `src/api.rs` - Remove all /nodes endpoints
- `src/sse.rs` - Change to MQTT subscription model
- `src/mqtt/edits.rs` - Use DocumentStore instead of NodeRegistry
- `src/mqtt/commands.rs` - Remove NodeRegistry, add create-document
- `src/bin/store.rs` - Use DocumentStore, remove router init
- `src/bin/http.rs` - Ensure fully stateless
- `src/fs/reconciler.rs` - Use DocumentStore instead of NodeRegistry
- `src/cli.rs` - Remove --routers arg

### Light modifications
- `src/mqtt/mod.rs` - Update exports
- `Cargo.toml` - May have unused deps to remove

---

## Testing Strategy

1. Unit tests for DocumentStore path→UUID resolution
2. Integration test: create document via MQTT, mount at path, edit via MQTT
3. SSE test: subscribe to path, receive edits via MQTT forwarding
4. Error case: edit to unmounted path returns error
