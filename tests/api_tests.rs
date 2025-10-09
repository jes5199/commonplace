use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use tower::util::ServiceExt;

// Helper to create test app
fn create_app() -> axum::Router {
    commonplace_doc::create_router()
}

// Helper to get response body as string
async fn body_to_string(body: Body) -> String {
    let bytes = body.collect().await.unwrap().to_bytes();
    String::from_utf8(bytes.to_vec()).unwrap()
}

#[tokio::test]
async fn test_health_check() {
    let app = create_app();

    let response = app
        .oneshot(
            Request::builder()
                .uri("/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = body_to_string(response.into_body()).await;
    assert_eq!(body, "OK");
}

#[tokio::test]
async fn test_create_json_document() {
    let app = create_app();

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/docs")
                .header("content-type", "application/json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = body_to_string(response.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert!(json["id"].is_string());
}

#[tokio::test]
async fn test_create_xml_document() {
    let app = create_app();

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/docs")
                .header("content-type", "application/xml")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = body_to_string(response.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert!(json["id"].is_string());
}

#[tokio::test]
async fn test_create_text_document() {
    let app = create_app();

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/docs")
                .header("content-type", "text/plain")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = body_to_string(response.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert!(json["id"].is_string());
}

#[tokio::test]
async fn test_create_unsupported_content_type() {
    let app = create_app();

    let response = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/docs")
                .header("content-type", "application/pdf")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
}

#[tokio::test]
async fn test_get_json_document() {
    let app = create_app();

    // First create a document
    let create_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/docs")
                .header("content-type", "application/json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let create_body = body_to_string(create_response.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&create_body).unwrap();
    let doc_id = json["id"].as_str().unwrap();

    // Now get the document
    let get_response = app
        .oneshot(
            Request::builder()
                .uri(format!("/docs/{}", doc_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(get_response.status(), StatusCode::OK);
    assert_eq!(
        get_response.headers().get("content-type").unwrap(),
        "application/json"
    );
    let body = body_to_string(get_response.into_body()).await;
    assert_eq!(body, "{}");
}

#[tokio::test]
async fn test_get_xml_document() {
    let app = create_app();

    // First create a document
    let create_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/docs")
                .header("content-type", "application/xml")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let create_body = body_to_string(create_response.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&create_body).unwrap();
    let doc_id = json["id"].as_str().unwrap();

    // Now get the document
    let get_response = app
        .oneshot(
            Request::builder()
                .uri(format!("/docs/{}", doc_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(get_response.status(), StatusCode::OK);
    assert_eq!(
        get_response.headers().get("content-type").unwrap(),
        "application/xml"
    );
    let body = body_to_string(get_response.into_body()).await;
    assert_eq!(body, r#"<?xml version="1.0" encoding="UTF-8"?><root/>"#);
}

#[tokio::test]
async fn test_get_text_document() {
    let app = create_app();

    // First create a document
    let create_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/docs")
                .header("content-type", "text/plain")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let create_body = body_to_string(create_response.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&create_body).unwrap();
    let doc_id = json["id"].as_str().unwrap();

    // Now get the document
    let get_response = app
        .oneshot(
            Request::builder()
                .uri(format!("/docs/{}", doc_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(get_response.status(), StatusCode::OK);
    assert_eq!(
        get_response.headers().get("content-type").unwrap(),
        "text/plain"
    );
    let body = body_to_string(get_response.into_body()).await;
    assert_eq!(body, "");
}

#[tokio::test]
async fn test_get_nonexistent_document() {
    let app = create_app();

    let response = app
        .oneshot(
            Request::builder()
                .uri("/docs/nonexistent-id")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_delete_document() {
    let app = create_app();

    // First create a document
    let create_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/docs")
                .header("content-type", "application/json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let create_body = body_to_string(create_response.into_body()).await;
    let json: serde_json::Value = serde_json::from_str(&create_body).unwrap();
    let doc_id = json["id"].as_str().unwrap().to_string();

    // Delete the document
    let delete_response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/docs/{}", doc_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(delete_response.status(), StatusCode::NO_CONTENT);

    // Verify it's gone
    let get_response = app
        .oneshot(
            Request::builder()
                .uri(format!("/docs/{}", doc_id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(get_response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_delete_nonexistent_document() {
    let app = create_app();

    let response = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/docs/nonexistent-id")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}
