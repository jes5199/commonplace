//! Directory mode synchronization helpers.
//!
//! This module contains helper functions for syncing a directory
//! with a server document, including schema traversal and UUID mapping.

use crate::fs::{Entry, FsSchema};
use crate::sync::{encode_node_id, HeadResponse};
use reqwest::Client;
use std::collections::HashMap;
use tracing::{debug, warn};

/// Recursively collect file paths from an entry, including explicit node_id if present.
/// Returns Vec<(path, explicit_node_id)> where explicit_node_id is Some if DocEntry has node_id.
pub fn collect_paths_from_entry(
    entry: &Entry,
    prefix: &str,
    paths: &mut Vec<(String, Option<String>)>,
) {
    match entry {
        Entry::Dir(dir) => {
            if let Some(ref entries) = dir.entries {
                for (name, child) in entries {
                    let child_path = if prefix.is_empty() {
                        name.clone()
                    } else {
                        format!("{}/{}", prefix, name)
                    };
                    collect_paths_from_entry(child, &child_path, paths);
                }
            }
        }
        Entry::Doc(doc) => {
            paths.push((prefix.to_string(), doc.node_id.clone()));
        }
    }
}

/// Fetch the node_id (UUID) for a file path from the server's schema.
///
/// After pushing a schema update, the server's reconciler creates documents with UUIDs.
/// This function fetches the updated schema and looks up the UUID for the given path.
/// Returns None if the path is not found or if the node_id is not set.
pub async fn fetch_node_id_from_schema(
    client: &Client,
    server: &str,
    fs_root_id: &str,
    relative_path: &str,
) -> Option<String> {
    // Build the full UUID map recursively (follows node-backed directories)
    let uuid_map = build_uuid_map_recursive(client, server, fs_root_id).await;
    uuid_map.get(relative_path).cloned()
}

/// Recursively build a map of relative paths to UUIDs by fetching all schemas.
///
/// This function follows node-backed directories and fetches their schemas
/// to build a complete map of all file paths to their UUIDs.
pub async fn build_uuid_map_recursive(
    client: &Client,
    server: &str,
    doc_id: &str,
) -> HashMap<String, String> {
    let mut uuid_map = HashMap::new();
    build_uuid_map_from_doc(client, server, doc_id, "", &mut uuid_map).await;
    uuid_map
}

/// Helper function to recursively build the UUID map from a document and its children.
#[async_recursion::async_recursion]
pub async fn build_uuid_map_from_doc(
    client: &Client,
    server: &str,
    doc_id: &str,
    path_prefix: &str,
    uuid_map: &mut HashMap<String, String>,
) {
    // Fetch the schema from this document
    let head_url = format!("{}/docs/{}/head", server, encode_node_id(doc_id));
    let resp = match client.get(&head_url).send().await {
        Ok(r) => r,
        Err(e) => {
            warn!("Failed to fetch schema for {}: {}", doc_id, e);
            return;
        }
    };

    if !resp.status().is_success() {
        warn!(
            "Failed to fetch schema: {} (status {})",
            doc_id,
            resp.status()
        );
        return;
    }

    let head: HeadResponse = match resp.json().await {
        Ok(h) => h,
        Err(e) => {
            warn!("Failed to parse schema response for {}: {}", doc_id, e);
            return;
        }
    };

    let schema: FsSchema = match serde_json::from_str(&head.content) {
        Ok(s) => s,
        Err(e) => {
            debug!("Document {} is not a schema ({}), skipping", doc_id, e);
            return;
        }
    };

    // Traverse the schema and collect UUIDs
    if let Some(ref root) = schema.root {
        collect_paths_with_node_backed_dirs(client, server, root, path_prefix, uuid_map).await;
    }
}

/// Recursively collect paths from an entry, following node-backed directories.
#[async_recursion::async_recursion]
pub async fn collect_paths_with_node_backed_dirs(
    client: &Client,
    server: &str,
    entry: &Entry,
    prefix: &str,
    uuid_map: &mut HashMap<String, String>,
) {
    match entry {
        Entry::Dir(dir) => {
            // If this is a node-backed directory (entries: null, node_id: Some),
            // fetch its schema and continue recursively
            if dir.entries.is_none() {
                if let Some(ref node_id) = dir.node_id {
                    // This is a node-backed directory - fetch its schema
                    build_uuid_map_from_doc(client, server, node_id, prefix, uuid_map).await;
                }
            } else if let Some(ref entries) = dir.entries {
                // Inline directory - traverse its entries
                for (name, child) in entries {
                    let child_path = if prefix.is_empty() {
                        name.clone()
                    } else {
                        format!("{}/{}", prefix, name)
                    };
                    collect_paths_with_node_backed_dirs(
                        client,
                        server,
                        child,
                        &child_path,
                        uuid_map,
                    )
                    .await;
                }
            }
        }
        Entry::Doc(doc) => {
            // This is a file - add it to the map if it has a node_id
            if let Some(ref node_id) = doc.node_id {
                debug!("Found UUID: {} -> {}", prefix, node_id);
                uuid_map.insert(prefix.to_string(), node_id.clone());
            }
        }
    }
}
