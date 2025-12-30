//! Integration tests for MQTT path resolution.
//!
//! These tests verify that file paths (like "terminal/screen.txt") are correctly
//! resolved to document UUIDs using the fs-root schema.

use commonplace_doc::document::resolve_path_to_uuid;

/// Test resolving paths with explicit node_ids
#[test]
fn test_resolve_explicit_node_id() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "config.json": { "type": "doc", "node_id": "config-uuid-123" }
            }
        }
    }"#;

    assert_eq!(
        resolve_path_to_uuid(fs_root, "config.json", "fs-root"),
        Some("config-uuid-123".to_string())
    );
}

/// Test resolving paths in nested directories
#[test]
fn test_resolve_nested_path() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "documents": {
                    "type": "dir",
                    "entries": {
                        "notes": {
                            "type": "dir",
                            "entries": {
                                "todo.txt": { "type": "doc", "node_id": "deep-nested-uuid" }
                            }
                        }
                    }
                }
            }
        }
    }"#;

    assert_eq!(
        resolve_path_to_uuid(fs_root, "documents/notes/todo.txt", "fs-root"),
        Some("deep-nested-uuid".to_string())
    );
}

/// Test that paths to directories return None (not documents)
#[test]
fn test_resolve_directory_returns_none() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "folder": {
                    "type": "dir",
                    "entries": {
                        "file.txt": { "type": "doc", "node_id": "file-uuid" }
                    }
                }
            }
        }
    }"#;

    // Path to directory should return None
    assert_eq!(resolve_path_to_uuid(fs_root, "folder", "fs-root"), None);
}

/// Test that nonexistent paths return None
#[test]
fn test_resolve_nonexistent_path() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "exists.txt": { "type": "doc", "node_id": "exists-uuid" }
            }
        }
    }"#;

    assert_eq!(
        resolve_path_to_uuid(fs_root, "doesnt-exist.txt", "fs-root"),
        None
    );
}

/// Test that partial paths return None
#[test]
fn test_resolve_partial_path() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "notes": {
                    "type": "dir",
                    "entries": {
                        "todo.txt": { "type": "doc", "node_id": "todo-uuid" }
                    }
                }
            }
        }
    }"#;

    // Path missing final component
    assert_eq!(
        resolve_path_to_uuid(fs_root, "notes/nonexistent.txt", "fs-root"),
        None
    );
}

/// Test resolution with invalid JSON returns None
#[test]
fn test_resolve_invalid_json() {
    let invalid = "not valid json";
    assert_eq!(resolve_path_to_uuid(invalid, "any.txt", "fs-root"), None);
}

/// Test resolution with empty root returns None
#[test]
fn test_resolve_empty_root() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {}
        }
    }"#;

    assert_eq!(resolve_path_to_uuid(fs_root, "any.txt", "fs-root"), None);
}

/// Test resolution with no root key
#[test]
fn test_resolve_missing_root() {
    let fs_root = r#"{ "version": 1 }"#;
    assert_eq!(resolve_path_to_uuid(fs_root, "any.txt", "fs-root"), None);
}

/// Test resolution with multiple files
#[test]
fn test_resolve_multiple_files() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "file1.txt": { "type": "doc", "node_id": "uuid-1" },
                "file2.txt": { "type": "doc", "node_id": "uuid-2" },
                "file3.json": { "type": "doc", "node_id": "uuid-3" }
            }
        }
    }"#;

    assert_eq!(
        resolve_path_to_uuid(fs_root, "file1.txt", "fs-root"),
        Some("uuid-1".to_string())
    );
    assert_eq!(
        resolve_path_to_uuid(fs_root, "file2.txt", "fs-root"),
        Some("uuid-2".to_string())
    );
    assert_eq!(
        resolve_path_to_uuid(fs_root, "file3.json", "fs-root"),
        Some("uuid-3".to_string())
    );
}

/// Test path with leading/trailing slashes
#[test]
fn test_resolve_path_normalization() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "notes": {
                    "type": "dir",
                    "entries": {
                        "todo.txt": { "type": "doc", "node_id": "todo-uuid" }
                    }
                }
            }
        }
    }"#;

    // Should handle paths with leading slashes
    assert_eq!(
        resolve_path_to_uuid(fs_root, "/notes/todo.txt", "fs-root"),
        Some("todo-uuid".to_string())
    );

    // Should handle paths with trailing slashes in directories (still fails for file)
    assert_eq!(resolve_path_to_uuid(fs_root, "notes/", "fs-root"), None);
}

/// Test resolution with node-backed directory (directory has node_id but no entries)
#[test]
fn test_resolve_stops_at_node_backed_dir() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "subdir": {
                    "type": "dir",
                    "node_id": "subdir-doc-uuid"
                }
            }
        }
    }"#;

    // Cannot resolve path through node-backed directory (would need to fetch that document)
    assert_eq!(
        resolve_path_to_uuid(fs_root, "subdir/file.txt", "fs-root"),
        None
    );

    // Path pointing to the directory itself still returns None (it's a dir not a doc)
    assert_eq!(resolve_path_to_uuid(fs_root, "subdir", "fs-root"), None);
}

/// Test that content_type field doesn't affect resolution
#[test]
fn test_resolve_ignores_content_type() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "data.json": {
                    "type": "doc",
                    "node_id": "data-uuid",
                    "content_type": "application/json"
                }
            }
        }
    }"#;

    assert_eq!(
        resolve_path_to_uuid(fs_root, "data.json", "fs-root"),
        Some("data-uuid".to_string())
    );
}

/// Test resolution with special characters in filenames
#[test]
fn test_resolve_special_characters() {
    let fs_root = r#"{
        "version": 1,
        "root": {
            "type": "dir",
            "entries": {
                "file with spaces.txt": { "type": "doc", "node_id": "spaces-uuid" },
                "file-with-dashes.txt": { "type": "doc", "node_id": "dashes-uuid" },
                "file_with_underscores.txt": { "type": "doc", "node_id": "underscores-uuid" }
            }
        }
    }"#;

    assert_eq!(
        resolve_path_to_uuid(fs_root, "file with spaces.txt", "fs-root"),
        Some("spaces-uuid".to_string())
    );
    assert_eq!(
        resolve_path_to_uuid(fs_root, "file-with-dashes.txt", "fs-root"),
        Some("dashes-uuid".to_string())
    );
    assert_eq!(
        resolve_path_to_uuid(fs_root, "file_with_underscores.txt", "fs-root"),
        Some("underscores-uuid".to_string())
    );
}
