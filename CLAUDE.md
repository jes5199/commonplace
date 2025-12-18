# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Rust server for managing documents with support for multiple content types (JSON, XML, text). The server exposes a REST API and has SSE capabilities for real-time updates.

### Architecture

- **Language**: Rust (edition 2021)
- **Purpose**: Document management server with multi-format support and reactive node graph
- **Web Framework**: Axum 0.7
- **API Protocols**:
  - REST API for document CRUD operations (`/docs`)
  - Node API for reactive document graph (`/nodes`)
  - SSE (Server-Sent Events) for real-time node subscriptions

### Key Dependencies

- `axum` - Web framework
- `tokio` - Async runtime
- `tower-http` - Middleware (CORS, tracing)
- `serde` / `serde_json` - Serialization
- `uuid` - Document ID generation
- `yrs` - Yjs-compatible CRDT implementation
- `async-trait` - Async trait support
- `async-stream` - SSE stream support
- `redb` - Persistent key-value storage (enabled with `--database`)

### Code Structure

- `src/main.rs` - Server initialization and routing
- `src/api.rs` - REST API endpoints (/docs and /nodes)
- `src/document.rs` - DocumentStore with ContentType enum and in-memory storage
- `src/node/` - Node trait abstraction for reactive document processing
  - `mod.rs` - Node trait definition with blue/red port methods
  - `document_node.rs` - DocumentNode implementation (persistent)
  - `connection_node.rs` - ConnectionNode for SSE clients (transient)
  - `registry.rs` - NodeRegistry with cycle detection and lazy creation
  - `types.rs` - Edit, Event, NodeId, Port types
  - `subscription.rs` - BlueSubscription, RedSubscription, Subscription
- `src/commit.rs` / `src/store.rs` - Commit model and redb-backed storage
- `src/events.rs` - Commit broadcast for SSE change notifications
- `src/sse.rs` - Server-Sent Events for node subscriptions and document change streams

The server runs on `localhost:3000` by default.

### API Endpoints

#### REST API
- `POST /docs` - Create a blank document (Content-Type header: application/json, application/xml, or text/plain)
- `GET /docs/{uuid}` - Retrieve document content
- `DELETE /docs/{uuid}` - Delete a document
- `POST /docs/{uuid}/commit` - Persist a Yjs update and apply it to the document (requires `--database`)
- `GET /health` - Health check

#### Node API
- `POST /nodes` - Create a node (type: "document")
- `GET /nodes` - List all nodes
- `GET /nodes/{id}` - Get node info
- `DELETE /nodes/{id}` - Delete a node
- `POST /nodes/{id}/edit` - Send an edit (Yjs update) to a node
- `POST /nodes/{id}/event` - Send an event (ephemeral JSON) to a node
- `POST /nodes/{from}/wire/{to}` - Wire two nodes together
- `DELETE /nodes/{from}/wire/{to}` - Remove wiring between nodes

#### SSE
- `GET /sse/nodes/{id}` - Subscribe to real-time updates from a node (creates transient ConnectionNode)
- `GET /documents/{id}/changes` - Get commit history for a document
- `GET /documents/{id}/stream` - Stream document changes via SSE

### Blue and Red Edges

Nodes communicate via two port types:

- **Blue (edits)**: Persistent Yjs commits. Subscribe to watch changes, push to edit. Must listen before editing (need parent context).
- **Red (events)**: Ephemeral JSON. Any client can POST to any node's red port. Subscribe to watch broadcasts.

SSE connections are transient nodes with server-generated UUIDs. They subscribe to a document's blue port and have their own red port for receiving events.

See `docs/ARCHITECTURE.md` for detailed diagrams.

### Document Storage

Documents are stored in-memory with:
- UUID identifier
- Content (String)
- ContentType enum (Json, Xml, Text)

Default content by type:
- JSON: `{}`
- XML: `<?xml version="1.0" encoding="UTF-8"?><root/>`
- Text: empty string

## Development Commands

- `cargo build` - Build the project
- `cargo run` - Run the server locally
- `cargo test` - Run tests
- `cargo clippy` - Run linter
- `cargo fmt` - Format code
- `RUST_LOG=debug cargo run` - Run with debug logging

## Git Configuration

- Main branch: `main`
