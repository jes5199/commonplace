//! Filesystem reconciler: watches the fs-root document and creates documents for entries.

use super::error::FsError;
use super::schema::{Entry, FsSchema};
use crate::document::{ContentType, DocumentStore};
use std::collections::HashSet;
use std::sync::Arc;
use tokio::sync::RwLock;

/// Manages the filesystem abstraction layer.
///
/// Parses the fs-root document JSON and ensures documents exist for each
/// entry declared in the filesystem schema.
pub struct FilesystemReconciler {
    /// The fs-root document ID
    fs_root_id: String,
    /// Reference to document store
    document_store: Arc<DocumentStore>,
    /// Last successfully parsed schema (kept on parse errors)
    last_valid_schema: RwLock<Option<FsSchema>>,
    /// Set of document IDs we've already created
    known_documents: RwLock<HashSet<String>>,
    /// Last valid schemas for node-backed directories (document_id -> schema)
    last_valid_node_schemas: RwLock<std::collections::HashMap<String, FsSchema>>,
}

impl FilesystemReconciler {
    /// Create a new FilesystemReconciler.
    pub fn new(fs_root_id: String, document_store: Arc<DocumentStore>) -> Self {
        Self {
            fs_root_id,
            document_store,
            last_valid_schema: RwLock::new(None),
            known_documents: RwLock::new(HashSet::new()),
            last_valid_node_schemas: RwLock::new(std::collections::HashMap::new()),
        }
    }

    /// Reconcile current state: parse JSON, collect entries, create missing documents.
    /// Note: Uses cycle detection to prevent infinite recursion on cyclic node-backed dirs.
    pub async fn reconcile(&self, content: &str) -> Result<(), FsError> {
        // 1. Parse JSON
        let schema: FsSchema =
            serde_json::from_str(content).map_err(|e| FsError::ParseError(e.to_string()))?;

        // 2. Validate version
        if schema.version != 1 {
            return Err(FsError::UnsupportedVersion(schema.version));
        }

        // 3. Validate root is a directory (if present)
        if let Some(ref root) = schema.root {
            if !matches!(root, Entry::Dir(_)) {
                return Err(FsError::SchemaError("root must be a directory".to_string()));
            }
        }

        // 4. Collect all entries from schema (with cycle detection)
        let mut ignored_dirs = HashSet::new();
        let mut recursion_stack = HashSet::new();
        let entries = if let Some(ref root) = schema.root {
            self.collect_entries_with_dirs(root, "", &mut ignored_dirs, &mut recursion_stack)
                .await?
        } else {
            vec![]
        };

        // 5. For each entry, ensure document exists
        let mut known = self.known_documents.write().await;
        for (path, doc_id, content_type) in entries {
            // Check if document exists in store (not just known_documents)
            // This handles the case where a document was deleted externally
            let doc_exists = self.document_store.get_document(&doc_id).await.is_some();

            if !doc_exists {
                self.document_store
                    .get_or_create_with_id(&doc_id, content_type)
                    .await;

                tracing::info!("Reconciler created document: {} -> {}", path, doc_id);
            }

            // Track in known_documents regardless
            known.insert(doc_id.clone());
        }

        // 6. Update last valid schema
        *self.last_valid_schema.write().await = Some(schema);

        Ok(())
    }

    /// Walk the entry tree, collecting entries and tracking document-backed directory IDs.
    /// Uses recursion_stack to detect cycles (same document in current path), while
    /// doc_backed_dirs collects all unique document-backed dirs for tracking.
    async fn collect_entries_with_dirs(
        &self,
        entry: &Entry,
        current_path: &str,
        doc_backed_dirs: &mut HashSet<String>,
        recursion_stack: &mut HashSet<String>,
    ) -> Result<Vec<(String, String, ContentType)>, FsError> {
        let mut results = vec![];

        match entry {
            Entry::Doc(doc) => {
                let doc_id = doc
                    .node_id
                    .clone()
                    .unwrap_or_else(|| self.derive_doc_id(current_path));
                let content_type = doc
                    .content_type
                    .as_deref()
                    .and_then(ContentType::from_mime)
                    .unwrap_or(ContentType::Json);
                results.push((current_path.to_string(), doc_id, content_type));
            }
            Entry::Dir(dir) => {
                // Spec: document-backed and inline forms are mutually exclusive
                if dir.node_id.is_some() && dir.entries.is_some() {
                    return Err(FsError::SchemaError(format!(
                        "Directory at '{}' has both node_id and entries (mutually exclusive)",
                        if current_path.is_empty() {
                            "/"
                        } else {
                            current_path
                        }
                    )));
                }

                // Handle document-backed directory
                if let Some(ref doc_id) = dir.node_id {
                    let content_type = dir
                        .content_type
                        .as_deref()
                        .and_then(ContentType::from_mime)
                        .unwrap_or(ContentType::Json);

                    // First, ensure the document exists
                    results.push((
                        current_path.to_string(),
                        doc_id.clone(),
                        content_type.clone(),
                    ));

                    // Track this as a document-backed directory
                    doc_backed_dirs.insert(doc_id.clone());

                    // Check for cycles - only skip if this document is in current recursion path
                    // (same document at different paths is allowed - multi-mount)
                    if recursion_stack.contains(doc_id) {
                        tracing::warn!(
                            "Cycle detected: document-backed dir {} in current path, skipping",
                            doc_id
                        );
                    } else {
                        // Add to recursion stack before descending
                        recursion_stack.insert(doc_id.clone());

                        // Try to recursively process its content
                        if let Some(child_entries) = self
                            .collect_doc_backed_dir_entries_with_dirs(
                                doc_id,
                                current_path,
                                doc_backed_dirs,
                                recursion_stack,
                            )
                            .await
                        {
                            results.extend(child_entries);
                        }

                        // Remove from recursion stack after returning
                        recursion_stack.remove(doc_id);
                    }
                }

                // Handle inline entries
                if let Some(ref entries) = dir.entries {
                    for (name, child) in entries {
                        // Validate name
                        Entry::validate_name(name)?;

                        let child_path = if current_path.is_empty() {
                            name.clone()
                        } else {
                            format!("{}/{}", current_path, name)
                        };
                        results.extend(
                            Box::pin(self.collect_entries_with_dirs(
                                child,
                                &child_path,
                                doc_backed_dirs,
                                recursion_stack,
                            ))
                            .await?,
                        );
                    }
                }
            }
        }

        Ok(results)
    }

    /// Try to fetch and parse a document-backed directory's content.
    async fn collect_doc_backed_dir_entries_with_dirs(
        &self,
        doc_id: &str,
        base_path: &str,
        doc_backed_dirs: &mut HashSet<String>,
        recursion_stack: &mut HashSet<String>,
    ) -> Option<Vec<(String, String, ContentType)>> {
        // Try to get existing document - not an error if it doesn't exist yet
        let doc = self.document_store.get_document(doc_id).await?;

        let content = doc.content;

        // Empty content is not an error (document just hasn't been populated)
        if content.is_empty() || content == "{}" {
            return None;
        }

        // Try to parse as filesystem schema - fall back to cached on error
        let schema: FsSchema = match serde_json::from_str(&content) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(
                    "Failed to parse document-backed dir {} at {}: {}",
                    doc_id,
                    base_path,
                    e
                );
                // Try to use cached schema for this document
                let cache = self.last_valid_node_schemas.read().await;
                if let Some(cached) = cache.get(doc_id) {
                    cached.clone()
                } else {
                    return None;
                }
            }
        };

        // Validate version - fall back to cached on unsupported version
        if schema.version != 1 {
            tracing::warn!(
                "Unsupported version {} in document-backed dir {} at {}",
                schema.version,
                doc_id,
                base_path
            );
            // Try to use cached schema for this document
            let cache = self.last_valid_node_schemas.read().await;
            if let Some(cached) = cache.get(doc_id) {
                // Use cached schema instead
                return self
                    .collect_from_valid_doc_schema(
                        cached,
                        base_path,
                        doc_backed_dirs,
                        recursion_stack,
                    )
                    .await;
            }
            return None;
        }

        // Validate root is a directory - fall back to cached on invalid root
        if let Some(ref root) = schema.root {
            if !matches!(root, Entry::Dir(_)) {
                tracing::warn!(
                    "Invalid root (not a directory) in document-backed dir {} at {}",
                    doc_id,
                    base_path
                );
                // Try to use cached schema for this document
                let cache = self.last_valid_node_schemas.read().await;
                if let Some(cached) = cache.get(doc_id) {
                    return self
                        .collect_from_valid_doc_schema(
                            cached,
                            base_path,
                            doc_backed_dirs,
                            recursion_stack,
                        )
                        .await;
                }
                return None;
            }
        }

        // Cache this valid schema
        {
            let mut cache = self.last_valid_node_schemas.write().await;
            cache.insert(doc_id.to_string(), schema.clone());
        }

        // Recursively collect from the nested root
        self.collect_from_valid_doc_schema(&schema, base_path, doc_backed_dirs, recursion_stack)
            .await
    }

    /// Collect entries from a validated document schema.
    async fn collect_from_valid_doc_schema(
        &self,
        schema: &FsSchema,
        base_path: &str,
        doc_backed_dirs: &mut HashSet<String>,
        recursion_stack: &mut HashSet<String>,
    ) -> Option<Vec<(String, String, ContentType)>> {
        if let Some(ref root) = schema.root {
            match Box::pin(self.collect_entries_with_dirs(
                root,
                base_path,
                doc_backed_dirs,
                recursion_stack,
            ))
            .await
            {
                Ok(entries) => Some(entries),
                Err(e) => {
                    tracing::warn!("Error collecting entries at {}: {}", base_path, e);
                    None
                }
            }
        } else {
            Some(vec![])
        }
    }

    /// Derive document ID from path: `<fs-root-id>:<path>`.
    fn derive_doc_id(&self, path: &str) -> String {
        if path.is_empty() {
            // Root entry without explicit doc_id - use fs-root itself
            self.fs_root_id.clone()
        } else {
            format!("{}:{}", self.fs_root_id, path)
        }
    }

    /// Get the fs-root document ID.
    pub fn fs_root_id(&self) -> &str {
        &self.fs_root_id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_derive_doc_id() {
        let store = Arc::new(DocumentStore::new());
        let reconciler = FilesystemReconciler::new("my-fs".to_string(), store);

        assert_eq!(
            reconciler.derive_doc_id("notes/ideas.txt"),
            "my-fs:notes/ideas.txt"
        );
        assert_eq!(reconciler.derive_doc_id("file.txt"), "my-fs:file.txt");
        assert_eq!(reconciler.derive_doc_id(""), "my-fs");
    }
}
