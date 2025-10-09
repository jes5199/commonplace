use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

#[derive(Clone, Debug)]
pub enum ContentType {
    Json,
    Xml,
    Text,
}

impl ContentType {
    pub fn from_mime(mime: &str) -> Option<Self> {
        match mime {
            "application/json" => Some(ContentType::Json),
            "application/xml" | "text/xml" => Some(ContentType::Xml),
            "text/plain" => Some(ContentType::Text),
            _ => None,
        }
    }

    pub fn to_mime(&self) -> &'static str {
        match self {
            ContentType::Json => "application/json",
            ContentType::Xml => "application/xml",
            ContentType::Text => "text/plain",
        }
    }

    pub fn default_content(&self) -> String {
        match self {
            ContentType::Json => "{}".to_string(),
            ContentType::Xml => r#"<?xml version="1.0" encoding="UTF-8"?><root/>"#.to_string(),
            ContentType::Text => String::new(),
        }
    }
}

#[derive(Clone)]
pub struct Document {
    pub content: String,
    pub content_type: ContentType,
}

pub struct DocumentStore {
    documents: Arc<RwLock<HashMap<String, Document>>>,
}

impl DocumentStore {
    pub fn new() -> Self {
        Self {
            documents: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub async fn create_document(&self, content_type: ContentType) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        let doc = Document {
            content: content_type.default_content(),
            content_type,
        };

        let mut documents = self.documents.write().await;
        documents.insert(id.clone(), doc);

        id
    }

    pub async fn get_document(&self, id: &str) -> Option<Document> {
        let documents = self.documents.read().await;
        documents.get(id).cloned()
    }

    pub async fn delete_document(&self, id: &str) -> bool {
        let mut documents = self.documents.write().await;
        documents.remove(id).is_some()
    }
}
