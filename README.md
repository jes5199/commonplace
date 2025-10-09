# Commonplace Doc Server

A Rust server for managing Yjs documents with REST and Server-Sent Events (SSE) APIs.

## Features

- **REST API** for document CRUD operations
- **SSE** for real-time document updates
- Built with [Axum](https://github.com/tokio-rs/axum) web framework
- [Yjs](https://docs.yjs.dev/) document management using the [yrs](https://github.com/y-crdt/y-crdt) crate

## Getting Started

### Prerequisites

- Rust 1.70 or later
- Cargo

### Running the Server

```bash
cargo run
```

The server will start on `http://localhost:3000`.

### Development

```bash
# Build the project
cargo build

# Run tests
cargo test

# Run with logging
RUST_LOG=debug cargo run

# Format code
cargo fmt

# Run linter
cargo clippy
```

## API Endpoints

### REST API

- `GET /health` - Health check endpoint
- `POST /api/documents` - Create a new document
- `GET /api/documents/:id` - Get document state
- `PUT /api/documents/:id` - Apply updates to a document
- `DELETE /api/documents/:id` - Delete a document
- `GET /api/documents` - List all documents

### SSE

- `GET /sse/documents/:id` - Subscribe to document updates

## Architecture

The server is organized into three main modules:

- `api.rs` - REST API endpoints for document management
- `document.rs` - Document storage and Yjs integration
- `sse.rs` - Server-Sent Events for real-time updates
- `main.rs` - Server initialization and routing

Documents are stored in-memory using a `DocumentStore` that manages Yjs `Doc` instances.
