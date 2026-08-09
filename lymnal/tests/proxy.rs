//! Does the client proxy actually forward a list to the trove and hand the
//! response back? (Regression cover for the "READING…" hang.) And does an upload
//! commit return the moment the file is safe in lymbo, with the push to the trove
//! happening in the background? (Regression cover for big files "timing out" on
//! commit and reporting a failure for a file that in fact landed.)

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

use lymnal::lymbo::Lymbo;
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
    let lymbo = Lymbo::open(dir.path()).unwrap();
    let proxy = Arc::new(Proxy::new(addr.to_string(), "tok".into(), lymbo));
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

async fn json_body(resp: axum::response::Response) -> serde_json::Value {
    let body = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&body).unwrap()
}

#[tokio::test]
async fn commit_returns_held_then_pusher_lands_it() {
    // A stand-in trove that accepts the upload protocol and counts the commits it
    // sees, so we can tell the background push actually happened.
    let commits = Arc::new(AtomicUsize::new(0));
    let c = commits.clone();
    let backend = axum::Router::new()
        .route(
            "/v1/upload/init",
            axum::routing::post(|| async {
                axum::Json(serde_json::json!({ "upload_id": "t1", "chunk_bytes": 8 }))
            }),
        )
        .route(
            "/v1/upload/:id",
            axum::routing::put(|| async { axum::Json(serde_json::json!({ "received_bytes": 0 })) }),
        )
        .route(
            "/v1/upload/:id/commit",
            axum::routing::post(move || {
                let c = c.clone();
                async move {
                    c.fetch_add(1, Ordering::SeqCst);
                    axum::Json(serde_json::json!({ "path": "x", "replaced": false }))
                }
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, backend).await.unwrap() });

    let dir = tempfile::tempdir().unwrap();
    let lymbo = Lymbo::open(dir.path()).unwrap();
    let proxy = Arc::new(Proxy::new(addr.to_string(), "tok".into(), lymbo));
    let app = router(proxy.clone());

    // init → chunk → commit, all through the proxy.
    let init = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/upload/init")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "path": "clip.mov", "size_bytes": 4, "mtime": 1 })
                        .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let id = json_body(init).await["upload_id"].as_str().unwrap().to_string();

    let _ = app
        .clone()
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(format!("/v1/upload/{id}"))
                .header("content-range", "bytes 0-3/4")
                .body(Body::from(vec![1u8, 2, 3, 4]))
                .unwrap(),
        )
        .await
        .unwrap();

    let commit = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/v1/upload/{id}/commit"))
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(commit.status(), StatusCode::OK);
    // Commit returns "held" immediately — it did not wait on the trove push.
    let v = json_body(commit).await;
    assert_eq!(v["held"], true);
    assert_eq!(proxy.held_count(), 1, "the file is queued to push, not yet gone");

    // Now the background pusher runs (what main.rs drives on a kick/timer) and the
    // file lands on the trove, so nothing stays held.
    let p = proxy.clone();
    let still = tokio::task::spawn_blocking(move || p.retry_held())
        .await
        .unwrap();
    assert_eq!(still, 0, "pushed and unpinned");
    assert_eq!(commits.load(Ordering::SeqCst), 1, "the trove saw exactly one commit");
    assert_eq!(proxy.held_count(), 0);
}
