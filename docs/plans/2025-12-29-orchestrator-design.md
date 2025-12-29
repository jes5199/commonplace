# Orchestrator Binary Design

**Issue:** CP-okn
**Date:** 2025-12-29

## Overview

The orchestrator (`commonplace-orchestrator`) is a process supervisor that starts and manages commonplace child processes. It reads configuration from a JSON file, starts processes in dependency order, and restarts them on failure with exponential backoff.

The MQTT broker (mosquitto) is assumed to be running externally via systemd.

## Configuration

**File:** `commonplace.json` (default, override with `--config`)

```json
{
  "mqtt_broker": "localhost:1883",
  "processes": {
    "store": {
      "command": "commonplace-store",
      "args": ["--database", "./data.redb", "--fs-root", "fs-root.json"],
      "restart": { "policy": "always", "backoff_ms": 500, "max_backoff_ms": 10000 }
    },
    "http": {
      "command": "commonplace-http",
      "args": ["--port", "3000"],
      "restart": { "policy": "always", "backoff_ms": 500, "max_backoff_ms": 10000 },
      "depends_on": ["store"]
    }
  }
}
```

### Config Fields

| Field | Description |
|-------|-------------|
| `mqtt_broker` | Broker address, passed to child processes automatically |
| `processes` | Map of process name → config |
| `command` | Executable name or path |
| `args` | Arguments to pass |
| `restart.policy` | `always`, `on_failure`, or `never` |
| `restart.backoff_ms` | Initial restart delay |
| `restart.max_backoff_ms` | Maximum restart delay |
| `depends_on` | List of processes that must start first |

## Process Lifecycle

### Startup Sequence

1. Load config file
2. Check MQTT broker is reachable at `mqtt_broker` address
3. Build dependency graph from `depends_on` fields
4. Start processes in topological order (store before http)
5. Wait for each process to be "ready" before starting dependents

### Restart Behavior

- When a process exits, check `restart.policy`
- If `always` or `on_failure` (and it failed): wait `backoff_ms`, then restart
- Double the backoff on each consecutive failure, cap at `max_backoff_ms`
- Reset backoff to initial value after process runs successfully for 30 seconds

### Shutdown Sequence

- On SIGTERM/SIGINT: send SIGTERM to all children in reverse dependency order
- Wait up to 5 seconds for graceful shutdown
- Send SIGKILL to any remaining processes
- Exit with 0 if clean, non-zero if forced kill was needed

## CLI Interface

```bash
# Start with default config (./commonplace.json)
commonplace-orchestrator

# Specify config file
commonplace-orchestrator --config /etc/commonplace/config.json

# Override mqtt broker
commonplace-orchestrator --mqtt-broker localhost:1884

# Override specific process args (appended to config args)
commonplace-orchestrator --store-args "--fs-root custom.json"
commonplace-orchestrator --http-args "--port 8080"

# Don't start a specific process
commonplace-orchestrator --disable http

# Run single process only (bypass dependencies)
commonplace-orchestrator --only store
```

## Logging

- Child stdout/stderr is captured and prefixed with process name
- Example: `[store] INFO: Starting commonplace-store`
- Orchestrator logs its own events: `[orchestrator] Starting process 'http'`

## Implementation

**File:** `src/bin/orchestrator.rs`

**Key types:**
- `OrchestratorConfig` - Parsed JSON config
- `ProcessConfig` - Per-process configuration
- `RestartPolicy` - Restart behavior settings
- `ProcessManager` - Runtime state and child handles
- `ManagedProcess` - Individual process state

**Dependencies:** None new (uses tokio::process, serde_json, clap)
