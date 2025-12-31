# Directory-Attached Process Management

**Issue:** CP-4xd
**Date:** 2025-12-31

## Overview

Extend `.processes.json` to support directory-attached processes alongside the existing file-attached processes. Directory-attached processes operate on the directory containing the `.processes.json` file, rather than a specific file within it. This is the primary paradigm for sync-sandbox workflows.

## Configuration Format

**File:** `.processes.json` in any directory within the document tree

```json
{
  "processes": {
    "counter": {
      "command": "python counter.py",
      "owns": "counter.json",
      "cwd": "/home/user/project"
    },
    "sandbox": {
      "command": "commonplace-sync --sandbox --exec ./run.sh",
      "cwd": "/home/user/sandbox-tools"
    }
  }
}
```

### Process Types

- **File-attached** (`owns` present): Process claims a specific file. `COMMONPLACE_PATH` includes the filename.
- **Directory-attached** (`owns` absent): Process operates on the directory. `COMMONPLACE_PATH` is just the directory path.

### Rules

- `owns` is optional (previously required)
- Multiple processes allowed per `.processes.json`
- File-attached and directory-attached can mix in the same file
- `command` and `cwd` remain required

## Environment Variables

Conductor sets these for all managed processes:

| Variable | Value | Source |
|----------|-------|--------|
| `COMMONPLACE_PATH` | Document tree path | Directory of `.processes.json`, plus `owns` filename if file-attached |
| `COMMONPLACE_MQTT` | Broker address | Orchestrator config `mqtt_broker` |
| `COMMONPLACE_SERVER` | HTTP server URL | See resolution order below |

### Server URL Resolution

1. Parse `--port` from `processes.http.args` in orchestrator config → `http://localhost:{port}`
2. Fall back to `http_server` field in orchestrator config
3. Fall back to `http://localhost:3000`

### Examples

File-attached (`"owns": "counter.json"` in `examples/.processes.json`):
```
COMMONPLACE_PATH=examples/counter.json
COMMONPLACE_MQTT=localhost:1883
COMMONPLACE_SERVER=http://localhost:3000
```

Directory-attached (no `owns` in `examples/.processes.json`):
```
COMMONPLACE_PATH=examples
COMMONPLACE_MQTT=localhost:1883
COMMONPLACE_SERVER=http://localhost:3000
```

## Implementation Changes

### Conductor

1. Make `owns` field optional in process config parsing
2. Add server URL resolution (parse orchestrator config with fallback chain)
3. Set `COMMONPLACE_SERVER` env var for all managed processes
4. Update path logic: when `owns` is absent, `COMMONPLACE_PATH` is directory only

No changes to process lifecycle, conflict detection, or discovery mechanism.

### Sync

1. Add `COMMONPLACE_PATH` env var support as default for `--node` argument
2. Existing `COMMONPLACE_SERVER` env var support already works

## Usage

Typical sync-sandbox invocation by conductor:

```json
{
  "processes": {
    "my-sandbox": {
      "command": "commonplace-sync --sandbox --exec ./run.sh",
      "cwd": "/home/user/sandbox-tools"
    }
  }
}
```

Conductor launches with:
```
COMMONPLACE_PATH=examples
COMMONPLACE_MQTT=localhost:1883
COMMONPLACE_SERVER=http://localhost:3000
```

Sync reads `COMMONPLACE_PATH` and `COMMONPLACE_SERVER` from environment, creates temp sandbox directory, syncs content, runs command.
