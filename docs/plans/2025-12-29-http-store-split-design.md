# HTTP/Store Split Design

## Summary

Split `commonplace-server` into two binaries:
- `commonplace-store`: Document storage, MQTT pub/sub, no HTTP
- `commonplace-http`: Stateless HTTP gateway, translates HTTP↔MQTT

## Binaries

### commonplace-store

Owns persistence and document state. Connects to MQTT.

**CLI:**
```
--database <path>       # redb persistence (required)
--mqtt-broker <url>     # MQTT broker URL (required)
--mqtt-client-id <id>   # Client ID (default: "commonplace-store")
--fs-root <id>          # Filesystem root node (required)
--router <id>           # Router documents (optional, repeatable)
```

**Responsibilities:**
- DocumentStore, NodeRegistry, CommitStore
- Subscribe to `{path}/edits` for paths in fs-root
- Respond to sync requests on `{path}/sync/+`
- Filesystem reconciler, router manager

### commonplace-http

Stateless HTTP/SSE gateway. Translates HTTP to MQTT.

**CLI:**
```
--host <addr>           # Listen address (default: 127.0.0.1)
--port <port>           # Listen port (default: 3000)
--mqtt-broker <url>     # MQTT broker URL (required)
--mqtt-client-id <id>   # Client ID (default: "commonplace-http")
```

**Request flows:**

| Endpoint | Flow |
|----------|------|
| `POST /nodes/{id}/edit` | Publish to `{path}/edits` |
| `POST /nodes/{id}/event` | Publish to `{path}/events/{type}` |
| `GET /nodes/{id}` | Sync protocol HEAD request |
| `GET /sse/nodes/{id}` | Subscribe to `{path}/edits`, stream as SSE |

## Code Organization

**Shared (library):**
- `mqtt/` module
- `commit.rs`, `store.rs` - types
- `document.rs` - ContentType

**commonplace-store only:**
- DocumentStore, NodeRegistry, CommitStore
- `fs/`, `router/`, `replay.rs`

**commonplace-http only:**
- New `http_api.rs` - HTTP→MQTT translation
- New `http_sse.rs` - MQTT→SSE bridge

## Implementation Phases

1. Create `commonplace-store` binary (remove HTTP from server.rs)
2. Create `commonplace-http` binary (new HTTP gateway)
3. Refactor shared code
4. Update CLI module with separate Args structs

## Followup

- CP-o2h: Evaluate whether NodeRegistry is still needed after split
