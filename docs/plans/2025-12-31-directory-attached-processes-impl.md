# Directory-Attached Process Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend `.processes.json` to support directory-attached processes (no `owns` field) alongside file-attached ones, and pass `COMMONPLACE_SERVER` to all discovered processes.

**Architecture:** Make `owns` field optional in `DiscoveredProcess`. When absent, `COMMONPLACE_PATH` is set to the directory path only. Add server URL resolution from orchestrator config with fallback chain.

**Tech Stack:** Rust, serde (Option fields), clap (env vars)

---

### Task 1: Make `owns` field optional in discovery.rs

**Files:**
- Modify: `src/orchestrator/discovery.rs:19-27`
- Test: `src/orchestrator/discovery.rs` (inline tests)

**Step 1: Write the failing test**

Add to the tests module in `discovery.rs`:

```rust
#[test]
fn test_parse_directory_attached_process() {
    let json = r#"{
        "processes": {
            "sandbox": {
                "command": "commonplace-sync --sandbox --exec ./run.sh",
                "cwd": "/home/user/sandbox"
            }
        }
    }"#;

    let config = ProcessesConfig::parse(json).unwrap();
    assert_eq!(config.processes.len(), 1);

    let sandbox = &config.processes["sandbox"];
    assert!(sandbox.owns.is_none());
    assert_eq!(sandbox.cwd, PathBuf::from("/home/user/sandbox"));
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test test_parse_directory_attached_process -- --nocapture`
Expected: FAIL - serde requires `owns` field

**Step 3: Make `owns` optional**

Change the `DiscoveredProcess` struct:

```rust
/// A process discovered from a `.processes.json` file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredProcess {
    /// Command to run (either a string or array of strings)
    pub command: CommandSpec,
    /// Relative path within same directory that this process owns (file-attached).
    /// If absent, process is directory-attached.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owns: Option<String>,
    /// Required absolute path on host for working directory
    pub cwd: PathBuf,
}
```

**Step 4: Run test to verify it passes**

Run: `cargo test test_parse_directory_attached_process -- --nocapture`
Expected: PASS

**Step 5: Update existing tests that reference `owns`**

Update `test_add_process` in `discovered_manager.rs` tests:

```rust
let config = DiscoveredProcess {
    command: CommandSpec::Simple("python test.py".to_string()),
    owns: Some("test.json".to_string()),
    cwd: PathBuf::from("/tmp"),
};
```

**Step 6: Run all discovery tests**

Run: `cargo test discovery -- --nocapture`
Expected: PASS

**Step 7: Commit**

```bash
git add src/orchestrator/discovery.rs src/orchestrator/discovered_manager.rs
git commit -m "feat(discovery): make owns field optional for directory-attached processes"
```

---

### Task 2: Add test for mixed file/directory processes

**Files:**
- Test: `src/orchestrator/discovery.rs` (inline tests)

**Step 1: Write the test**

Add to tests module in `discovery.rs`:

```rust
#[test]
fn test_mixed_file_and_directory_attached() {
    let json = r#"{
        "processes": {
            "counter": {
                "command": "python counter.py",
                "owns": "counter.json",
                "cwd": "/app/counter"
            },
            "sandbox": {
                "command": "commonplace-sync --sandbox --exec ./run.sh",
                "cwd": "/app/sandbox"
            }
        }
    }"#;

    let config = ProcessesConfig::parse(json).unwrap();
    assert_eq!(config.processes.len(), 2);

    let counter = &config.processes["counter"];
    assert_eq!(counter.owns, Some("counter.json".to_string()));

    let sandbox = &config.processes["sandbox"];
    assert!(sandbox.owns.is_none());
}
```

**Step 2: Run test**

Run: `cargo test test_mixed_file_and_directory_attached -- --nocapture`
Expected: PASS (already works with Task 1 changes)

**Step 3: Commit**

```bash
git add src/orchestrator/discovery.rs
git commit -m "test(discovery): add test for mixed file/directory-attached processes"
```

---

### Task 3: Update document_path logic in DiscoveredProcessManager

**Files:**
- Modify: `src/orchestrator/discovered_manager.rs:78-95`

**Step 1: Write the failing test**

Add to tests in `discovered_manager.rs`:

```rust
#[test]
fn test_add_directory_attached_process() {
    let mut manager = DiscoveredProcessManager::new("localhost:1883".to_string());

    let config = DiscoveredProcess {
        command: CommandSpec::Simple("sync --sandbox".to_string()),
        owns: None,
        cwd: PathBuf::from("/tmp"),
    };

    // For directory-attached, document_path is just the directory
    manager.add_process("sandbox".to_string(), "examples".to_string(), config);

    assert_eq!(manager.processes().len(), 1);
    let process = manager.processes().get("sandbox").unwrap();
    assert_eq!(process.document_path, "examples");
}
```

**Step 2: Run test to verify it passes**

Run: `cargo test test_add_directory_attached_process -- --nocapture`
Expected: PASS (add_process already takes document_path as parameter)

The caller (not yet written) will compute the correct path. No changes needed to add_process.

**Step 3: Commit**

```bash
git add src/orchestrator/discovered_manager.rs
git commit -m "test(discovery): add test for directory-attached process in manager"
```

---

### Task 4: Add COMMONPLACE_SERVER to DiscoveredProcessManager

**Files:**
- Modify: `src/orchestrator/discovered_manager.rs:43-66` (struct and new)
- Modify: `src/orchestrator/discovered_manager.rs:126-149` (spawn_process)

**Step 1: Write the failing test**

Add to tests in `discovered_manager.rs`:

```rust
#[tokio::test]
async fn test_spawn_sets_server_env() {
    let mut manager = DiscoveredProcessManager::new(
        "localhost:1883".to_string(),
        "http://localhost:3000".to_string(),
    );

    assert_eq!(manager.server_url(), "http://localhost:3000");
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test test_spawn_sets_server_env -- --nocapture`
Expected: FAIL - new() doesn't accept server_url parameter

**Step 3: Add server_url field to DiscoveredProcessManager**

Update the struct and constructor:

```rust
/// Manager for processes discovered from `.processes.json` files.
pub struct DiscoveredProcessManager {
    /// MQTT broker address
    mqtt_broker: String,
    /// HTTP server URL
    server_url: String,
    /// Currently managed processes
    processes: HashMap<String, ManagedDiscoveredProcess>,
    /// Initial backoff in milliseconds
    initial_backoff_ms: u64,
    /// Maximum backoff in milliseconds
    max_backoff_ms: u64,
    /// Time in seconds after which to reset failure count
    reset_after_secs: u64,
}

impl DiscoveredProcessManager {
    /// Create a new discovered process manager.
    pub fn new(mqtt_broker: String, server_url: String) -> Self {
        Self {
            mqtt_broker,
            server_url,
            processes: HashMap::new(),
            initial_backoff_ms: 500,
            max_backoff_ms: 10_000,
            reset_after_secs: 30,
        }
    }

    /// Get the HTTP server URL.
    pub fn server_url(&self) -> &str {
        &self.server_url
    }
```

**Step 4: Update spawn_process to set COMMONPLACE_SERVER**

In spawn_process, after setting COMMONPLACE_MQTT:

```rust
// Set environment variables
cmd.env("COMMONPLACE_PATH", document_path);
cmd.env("COMMONPLACE_MQTT", &mqtt_broker);
cmd.env("COMMONPLACE_SERVER", &self.server_url);
```

**Step 5: Update existing tests that call new()**

Update `test_discovered_process_manager_new`:

```rust
#[test]
fn test_discovered_process_manager_new() {
    let manager = DiscoveredProcessManager::new(
        "localhost:1883".to_string(),
        "http://localhost:3000".to_string(),
    );
    assert_eq!(manager.mqtt_broker(), "localhost:1883");
    assert_eq!(manager.server_url(), "http://localhost:3000");
    assert!(manager.processes().is_empty());
}
```

And `test_add_process`:

```rust
#[test]
fn test_add_process() {
    let mut manager = DiscoveredProcessManager::new(
        "localhost:1883".to_string(),
        "http://localhost:3000".to_string(),
    );
    // ... rest unchanged
```

And `test_add_directory_attached_process`:

```rust
#[test]
fn test_add_directory_attached_process() {
    let mut manager = DiscoveredProcessManager::new(
        "localhost:1883".to_string(),
        "http://localhost:3000".to_string(),
    );
    // ... rest unchanged
```

**Step 6: Run all tests**

Run: `cargo test discovered_manager -- --nocapture`
Expected: PASS

**Step 7: Commit**

```bash
git add src/orchestrator/discovered_manager.rs
git commit -m "feat(discovery): add COMMONPLACE_SERVER env var to spawned processes"
```

---

### Task 5: Add server URL resolution to OrchestratorConfig

**Files:**
- Modify: `src/orchestrator/config.rs`

**Step 1: Write the failing test**

Add to tests in `config.rs`:

```rust
#[test]
fn test_resolve_server_url_from_http_args() {
    let json = r#"{
        "processes": {
            "http": {
                "command": "commonplace-http",
                "args": ["--port", "8080"]
            }
        }
    }"#;
    let config: OrchestratorConfig = serde_json::from_str(json).unwrap();
    assert_eq!(config.resolve_server_url(), "http://localhost:8080");
}

#[test]
fn test_resolve_server_url_from_explicit_field() {
    let json = r#"{
        "http_server": "http://example.com:3000",
        "processes": {}
    }"#;
    let config: OrchestratorConfig = serde_json::from_str(json).unwrap();
    assert_eq!(config.resolve_server_url(), "http://example.com:3000");
}

#[test]
fn test_resolve_server_url_default() {
    let json = r#"{ "processes": {} }"#;
    let config: OrchestratorConfig = serde_json::from_str(json).unwrap();
    assert_eq!(config.resolve_server_url(), "http://localhost:3000");
}
```

**Step 2: Run tests to verify they fail**

Run: `cargo test resolve_server_url -- --nocapture`
Expected: FAIL - method doesn't exist

**Step 3: Add http_server field and resolve_server_url method**

Add to `OrchestratorConfig`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OrchestratorConfig {
    #[serde(default = "default_mqtt_broker")]
    pub mqtt_broker: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub http_server: Option<String>,
    pub processes: HashMap<String, ProcessConfig>,
}
```

Add the method:

```rust
impl OrchestratorConfig {
    // ... existing methods ...

    /// Resolve the HTTP server URL with fallback chain:
    /// 1. Parse --port from http process args
    /// 2. Use http_server config field
    /// 3. Default to http://localhost:3000
    pub fn resolve_server_url(&self) -> String {
        // Try to parse port from http process args
        if let Some(http_config) = self.processes.get("http") {
            let args = &http_config.args;
            for (i, arg) in args.iter().enumerate() {
                if arg == "--port" || arg == "-p" {
                    if let Some(port) = args.get(i + 1) {
                        return format!("http://localhost:{}", port);
                    }
                }
            }
        }

        // Fall back to explicit http_server field
        if let Some(ref url) = self.http_server {
            return url.clone();
        }

        // Default
        "http://localhost:3000".to_string()
    }
}
```

**Step 4: Run tests**

Run: `cargo test resolve_server_url -- --nocapture`
Expected: PASS

**Step 5: Commit**

```bash
git add src/orchestrator/config.rs
git commit -m "feat(config): add server URL resolution with fallback chain"
```

---

### Task 6: Add COMMONPLACE_PATH env var support to sync.rs

**Files:**
- Modify: `src/bin/sync.rs:46-48`

**Step 1: Write integration test concept**

This is best tested manually since sync.rs is a binary. The change is straightforward.

**Step 2: Update --node arg to also read COMMONPLACE_PATH**

Change the `node` argument:

```rust
/// Node ID to sync with (reads from COMMONPLACE_NODE or COMMONPLACE_PATH env vars; optional if --fork-from is provided)
#[arg(short, long, env = "COMMONPLACE_NODE")]
node: Option<String>,
```

After the Args struct, add logic to check COMMONPLACE_PATH as fallback:

In main(), after `let args = Args::parse();`, add:

```rust
// COMMONPLACE_PATH is an alias for --node (for conductor compatibility)
let node = args.node.clone().or_else(|| std::env::var("COMMONPLACE_PATH").ok());
```

Then use `node` instead of `args.node` in the subsequent logic.

**Step 3: Update the node resolution logic**

Find the match statement around line 170 that handles node/fork_from and update it to use the new `node` variable.

**Step 4: Run cargo clippy**

Run: `cargo clippy --bin commonplace-sync`
Expected: No errors

**Step 5: Manual test**

```bash
COMMONPLACE_PATH=test-node cargo run --bin commonplace-sync -- --directory /tmp/test --sandbox --exec echo
# Should use test-node as the node ID
```

**Step 6: Commit**

```bash
git add src/bin/sync.rs
git commit -m "feat(sync): add COMMONPLACE_PATH env var as alias for --node"
```

---

### Task 7: Update examples/.processes.json with directory-attached example

**Files:**
- Modify: `examples/.processes.json`

**Step 1: Update the example file**

```json
{
  "processes": {
    "counter": {
      "command": "uv run python counter_example.py",
      "owns": "counter.json",
      "cwd": "/home/jes/commonplace/examples/python-client"
    },
    "sandbox-example": {
      "command": ["commonplace-sync", "--sandbox", "--exec", "echo", "hello from sandbox"],
      "cwd": "/home/jes/commonplace/examples"
    }
  }
}
```

**Step 2: Commit**

```bash
git add examples/.processes.json
git commit -m "docs: add directory-attached process example to .processes.json"
```

---

### Task 8: Run full test suite and clippy

**Step 1: Run clippy**

Run: `cargo clippy --all-targets`
Expected: No warnings

**Step 2: Run all tests**

Run: `cargo test`
Expected: All pass

**Step 3: Final commit if any fixes needed**

---

### Task 9: Update the bead with implementation notes

**Step 1: Update bead CP-4xd**

```bash
bd update CP-4xd --status in_progress
bd comment CP-4xd "Implementation complete. Changes:
- Made owns field optional in DiscoveredProcess
- Added COMMONPLACE_SERVER env var to spawned processes
- Added resolve_server_url() to OrchestratorConfig with fallback chain
- Added COMMONPLACE_PATH env var support in sync.rs as alias for --node"
```
