//! Sync state management for file synchronization.
//!
//! This module contains the `SyncState` struct that tracks synchronization state
//! between file watchers and SSE tasks, including echo detection and write barriers.

use crate::sync::state_file::SyncStateFile;
use std::path::PathBuf;
use tracing::warn;

/// Pending write from server - used for barrier-based echo detection.
///
/// When the server sends an edit, we write it to the local file. The file watcher
/// will see this change and try to upload it back. The pending write barrier prevents
/// this "echo" by tracking what we just wrote.
#[derive(Debug, Clone)]
pub struct PendingWrite {
    /// Unique token for this write operation
    pub write_id: u64,
    /// Content being written
    pub content: String,
    /// CID of the commit being written
    pub cid: Option<String>,
    /// When this write started (for timeout detection)
    pub started_at: std::time::Instant,
}

/// Shared state between file watcher and SSE tasks.
///
/// This struct is protected by `Arc<RwLock<SyncState>>` and coordinates between:
/// - The upload task (watches local file, pushes to server)
/// - The SSE task (receives server edits, writes to local file)
///
/// Key mechanisms:
/// - **Echo detection**: Prevents re-uploading content we just received from server
/// - **Write barrier**: Tracks pending server writes to handle concurrent edits
/// - **State file**: Persists sync state for offline change detection
#[derive(Debug)]
pub struct SyncState {
    /// CID of the commit we last wrote to the local file
    pub last_written_cid: Option<String>,
    /// Content we last wrote to the local file (for echo detection)
    pub last_written_content: String,
    /// Monotonic counter for write operations
    pub current_write_id: u64,
    /// Currently pending server write (barrier is "up" when Some)
    pub pending_write: Option<PendingWrite>,
    /// Flag indicating a server edit was skipped while barrier was up.
    /// upload_task should refresh HEAD after clearing barrier if this is true.
    pub needs_head_refresh: bool,
    /// Persistent state file for offline change detection (file mode only)
    pub state_file: Option<SyncStateFile>,
    /// Path to save the state file
    pub state_file_path: Option<PathBuf>,
}

impl SyncState {
    /// Create a new SyncState with default values.
    pub fn new() -> Self {
        Self {
            last_written_cid: None,
            last_written_content: String::new(),
            current_write_id: 0,
            pending_write: None,
            needs_head_refresh: false,
            state_file: None,
            state_file_path: None,
        }
    }

    /// Create a SyncState initialized from a persisted state file.
    ///
    /// This is used when resuming sync to detect offline changes.
    pub fn with_state_file(state_file: SyncStateFile, state_file_path: PathBuf) -> Self {
        Self {
            last_written_cid: state_file.last_synced_cid.clone(),
            last_written_content: String::new(),
            current_write_id: 0,
            pending_write: None,
            needs_head_refresh: false,
            state_file: Some(state_file),
            state_file_path: Some(state_file_path),
        }
    }

    /// Update state file after successful sync and save to disk.
    ///
    /// Called after a successful upload or download to record the new state.
    pub async fn mark_synced(&mut self, cid: &str, content_hash: &str, relative_path: &str) {
        if let Some(ref mut state_file) = self.state_file {
            state_file.mark_synced(cid.to_string());
            state_file.update_file(relative_path, content_hash.to_string());

            // Save to disk
            if let Some(ref path) = self.state_file_path {
                if let Err(e) = state_file.save(path).await {
                    warn!("Failed to save state file: {}", e);
                }
            }
        }
    }
}

impl Default for SyncState {
    fn default() -> Self {
        Self::new()
    }
}
