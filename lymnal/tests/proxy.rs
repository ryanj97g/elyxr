//! Does the client proxy actually forward a list to the trove and hand the
//! response back? (Regression cover for the "READING…" hang.)

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

use lymnal::limbo::Limbo;
use lymnal::proxy::{router, Proxy};

#[tokio::test]
async fn proxy_forwards_a_list() {
    // A stand-in trove that answers /v1/list.
    let backend = axum::Router::new().route(
        "/v1/list",
        axum::routing::get(|| async {
            axum::Json(serde_json::json!({
                "path": "",
                "entries": [{ "name": "shot.png", "kind": "file", "size_bytes": 12, "mtime": 1 }],
                "used_bytes": 12,
                "warnings": []
            }))
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, backend).await.unwrap() });

    // The proxy pointing at that stand-in.
    let dir = tempfile::tempdir().unwrap();
    let limbo = Limbo::open(dir.path()).unwrap();
    let proxy = Arc::new(Proxy::new(addr.to_string(), "tok".into(), limbo));
    let app = router(proxy);

    // A list request through the proxy comes back with the backend's entries.
    let req = Request::builder()
        .uri("/v1/list?path=")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["entries"][0]["name"], "shot.png");
}
