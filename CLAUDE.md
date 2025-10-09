# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a Rust server for managing Yjs documents. The server exposes a custom API over REST and Server-Sent Events (SSE).

### Architecture

- **Language**: Rust (edition 2021)
- **Purpose**: Yjs document management server
- **Web Framework**: Axum 0.7
- **API Protocols**:
  - REST API for document operations (CRUD)
  - SSE (Server-Sent Events) for real-time updates

### Key Dependencies

- `axum` - Web framework
- `tokio` - Async runtime
- `yrs` - Yjs CRDT implementation for Rust
- `tower-http` - Middleware (CORS, tracing)
- `serde` / `serde_json` - Serialization
- `uuid` - Document ID generation

### Code Structure

- `src/main.rs` - Server initialization and routing
- `src/api.rs` - REST API endpoints for document management
- `src/document.rs` - DocumentStore managing Yjs documents in-memory
- `src/sse.rs` - Server-Sent Events for real-time subscriptions

The server runs on `localhost:3000` by default.

## Development Commands

Once the Rust project is initialized, common commands will include:

- `cargo build` - Build the project
- `cargo test` - Run tests
- `cargo run` - Run the server locally
- `cargo clippy` - Run linter
- `cargo fmt` - Format code

## Git Configuration

- Main branch: `main`
