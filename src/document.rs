use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use yrs::{updates::decoder::Decode, Doc, ReadTxn, Transact};

pub struct DocumentStore {
    documents: Arc<RwLock<HashMap<String, Arc<Doc>>>>,
}

impl DocumentStore {
    pub fn new() -> Self {
        Self {
            documents: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn create_document(&self, name: Option<String>) -> String {
        let id = name.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let doc = Arc::new(Doc::new());

        let mut documents = self.documents.write().await;
        documents.insert(id.clone(), doc);

        id
    }

    pub async fn get_document(&self, id: &str) -> Option<Vec<u8>> {
        let documents = self.documents.read().await;
        documents.get(id).map(|doc| {
            let txn = doc.transact();
            txn.encode_state_as_update_v1(&yrs::StateVector::default())
        })
    }

    pub async fn apply_update(&self, id: &str, update: Vec<u8>) -> bool {
        let documents = self.documents.read().await;
        if let Some(doc) = documents.get(id) {
            let mut txn = doc.transact_mut();
            txn.apply_update(yrs::Update::decode_v1(&update).unwrap());
            true
        } else {
            false
        }
    }

    pub async fn delete_document(&self, id: &str) -> bool {
        let mut documents = self.documents.write().await;
        documents.remove(id).is_some()
    }

    pub async fn list_documents(&self) -> Vec<String> {
        let documents = self.documents.read().await;
        documents.keys().cloned().collect()
    }

    pub async fn get_doc(&self, id: &str) -> Option<Arc<Doc>> {
        let documents = self.documents.read().await;
        documents.get(id).cloned()
    }
}
