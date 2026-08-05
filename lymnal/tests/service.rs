//! End-to-end tests through the HTTP router (§04 contract, §11 behaviour).
//!
//! Each test drives the real router with `tower::ServiceExt::oneshot`, so no
//! socket is bound. State is built from the public API against a temp trove.

use axum::body::Body;
use axum::http::{header, Method, Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

use lymnal::config::{Config, Download, Limits, ListCfg, Role, TokenCfg, TroveCfg, Upload};
use lymnal::devices::DeviceStore;
use lymnal::limits::Usage;
use lymnal::state::AppState;
use lymnal::trove::Trove;
use lymnal::upload::UploadManager;

const TOKEN: &str = "lym_testtoken";

struct Harness {
    _dir: tempfile::TempDir,
    trove_root: std::path::PathBuf,
    state: lymnal::Shared,
}

fn harness() -> Harness {
    harness_with_limits(Limits::default())
}

fn harness_with_limits(limits: Limits) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let trove_root = dir.path().join("trove");
    std::fs::create_dir_all(&trove_root).unwrap();
    let data_dir = dir.path().join("data");
    std::fs::create_dir_all(&data_dir).unwrap();

    let cfg = Config {
        bind: "127.0.0.1:0".into(),
        data_dir: data_dir.clone(),
        log_level: "error".into(),
        trove: TroveCfg {
            name: "elyxr".into(),
            path: trove_root.clone(),
            follow_symlinks: false,
        },
        tokens: vec![TokenCfg {
            label: "probookrjg".into(),
            hash: lymnal::auth::hash_token(TOKEN),
            role: Role::Owner,
            max_bytes: 150_000_000_000,
        }],
        limits: limits.clone(),
        download: Download::default(),
        upload: Upload::default(),
        list: ListCfg::default(),
        client: Default::default(),
    };
    let trove = Trove::open(&trove_root, false).unwrap();
    let usage = Usage::open(&data_dir, limits, trove.root().to_path_buf()).unwrap();
    let uploads = UploadManager::new(&data_dir, cfg.upload.chunk_bytes, cfg.upload.stale_after_hrs);
    let devices = DeviceStore::open(&data_dir).unwrap();
    let state = AppState::new(cfg, trove, usage, uploads, devices);
    Harness {
        _dir: dir,
        trove_root,
        state,
    }
}

impl Harness {
    fn router(&self) -> axum::Router {
        lymnal::handlers::router(self.state.clone())
    }

    async fn send(
        &self,
        method: Method,
        uri: &str,
        auth: bool,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut req = Request::builder().method(method).uri(uri);
        if auth {
            req = req.header(header::AUTHORIZATION, format!("Bearer {TOKEN}"));
        }
        let req = match body {
            Some(b) => req
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(b.to_string()))
                .unwrap(),
            None => req.body(Body::empty()).unwrap(),
        };
        let resp = self.router().oneshot(req).await.unwrap();
        let status = resp.status();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        let val: Value = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap_or(Value::Null)
        };
        (status, val)
    }

    fn write_file(&self, rel: &str, bytes: &[u8]) {
        let p = self.trove_root.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, bytes).unwrap();
    }
}

// --------------------------------------------------------- pairing/admin ---

impl Harness {
    async fn admin(
        &self,
        method: Method,
        uri: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let token = self.state.admin_token.clone();
        let mut req = Request::builder()
            .method(method)
            .uri(uri)
            .header("x-admin-token", token);
        let req = match body {
            Some(b) => req
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(b.to_string()))
                .unwrap(),
            None => req.body(Body::empty()).unwrap(),
        };
        let resp = self.router().oneshot(req).await.unwrap();
        let status = resp.status();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        let val: Value = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap_or(Value::Null)
        };
        (status, val)
    }
}

#[tokio::test]
async fn pairing_approval_mints_a_working_token() {
    let h = harness();
    // Admin opens pairing.
    let (st, _) = h
        .admin(Method::POST, "/v1/admin/pairing", Some(json!({ "open": true })))
        .await;
    assert_eq!(st, StatusCode::OK);

    // A device requests access; the pair call blocks until approval.
    let router = h.router();
    let pair = tokio::spawn(async move {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/v1/pair")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({ "device": "laptop", "client": "elyxr/1.0.0" }).to_string(),
            ))
            .unwrap();
        let resp = router.oneshot(req).await.unwrap();
        let status = resp.status();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        (status, serde_json::from_slice::<Value>(&bytes).unwrap())
    });

    // Wait for it to show up as pending, then approve.
    let mut phrase = String::new();
    for _ in 0..50 {
        let (_, body) = h.admin(Method::GET, "/v1/admin/pending", None).await;
        let pending = body["pending"].as_array().unwrap();
        if !pending.is_empty() {
            phrase = pending[0]["phrase"].as_str().unwrap().to_string();
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(!phrase.is_empty(), "the request should be pending");
    // The phrase must be the deterministic one both sides derive.
    assert_eq!(phrase, "violet anchor cedar juniper");

    let (st, _) = h
        .admin(Method::POST, "/v1/admin/approve", Some(json!({ "device": "laptop" })))
        .await;
    assert_eq!(st, StatusCode::OK);

    let (status, body) = pair.await.unwrap();
    assert_eq!(status, StatusCode::OK);
    let token = body["token"].as_str().unwrap().to_string();
    assert_eq!(body["role"], "owner");

    // The minted token works.
    let req = Request::builder()
        .method(Method::GET)
        .uri("/v1/list")
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let resp = h.router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn pairing_denied_is_reported() {
    let h = harness();
    h.admin(Method::POST, "/v1/admin/pairing", Some(json!({ "open": true }))).await;
    let router = h.router();
    let pair = tokio::spawn(async move {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/v1/pair")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(json!({ "device": "laptop", "client": "elyxr/1.0.0" }).to_string()))
            .unwrap();
        router.oneshot(req).await.unwrap().status()
    });
    for _ in 0..50 {
        let (_, body) = h.admin(Method::GET, "/v1/admin/pending", None).await;
        if !body["pending"].as_array().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    h.admin(Method::POST, "/v1/admin/deny", Some(json!({ "device": "laptop" }))).await;
    assert_eq!(pair.await.unwrap(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn admin_needs_the_local_token() {
    let h = harness();
    // Without the header, the admin surface is refused.
    let (status, body) = h.send(Method::GET, "/v1/admin/devices", false, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["code"], "PERMISSION_DENIED");
}

#[tokio::test]
async fn editing_limits_persists_and_takes_effect() {
    let h = harness();
    let (st, body) = h
        .admin(Method::POST, "/v1/admin/limits", Some(json!({ "max_bytes": 1000 })))
        .await;
    assert_eq!(st, StatusCode::OK);
    assert_eq!(body["max_bytes"], 1000);
    // Health now reports the new ceiling.
    let (_, health) = h.send(Method::GET, "/v1/health", false, None).await;
    assert_eq!(health["max_bytes"], 1000);
}

// ------------------------------------------------------------------ auth ---

#[tokio::test]
async fn health_needs_no_auth() {
    let h = harness();
    let (status, body) = h.send(Method::GET, "/v1/health", false, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["trove"], "elyxr");
    assert_eq!(body["max_bytes"], 150_000_000_000u64);
}

#[tokio::test]
async fn protected_endpoints_refuse_without_token() {
    let h = harness();
    let (status, body) = h.send(Method::GET, "/v1/list", false, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "BAD_TOKEN");
    // The one shape: message and request_id are always present.
    assert!(body["message"].is_string());
    assert!(body["request_id"].is_string());
}

#[tokio::test]
async fn revoking_a_token_takes_effect_next_request() {
    let h = harness();
    let (ok, _) = h.send(Method::GET, "/v1/list", true, None).await;
    assert_eq!(ok, StatusCode::OK);
    // Revoke: empty the live token set.
    h.state.set_tokens(vec![]);
    let (status, body) = h.send(Method::GET, "/v1/list", true, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["code"], "BAD_TOKEN");
}

// --------------------------------------------------------------- browse ---

#[tokio::test]
async fn list_sorts_folders_first_and_pages_without_gaps() {
    let h = harness();
    // 20,000 files plus a couple of folders.
    for i in 0..20_000 {
        h.write_file(&format!("big/f{i:05}.txt"), b"x");
    }
    std::fs::create_dir_all(h.trove_root.join("big/zdir")).unwrap();
    std::fs::create_dir_all(h.trove_root.join("big/adir")).unwrap();

    let mut seen: Vec<String> = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let uri = match &cursor {
            Some(c) => format!("/v1/list?path=big&limit=500&cursor={c}"),
            None => "/v1/list?path=big&limit=500".to_string(),
        };
        let (status, body) = h.send(Method::GET, &uri, true, None).await;
        assert_eq!(status, StatusCode::OK);
        for e in body["entries"].as_array().unwrap() {
            seen.push(e["name"].as_str().unwrap().to_string());
        }
        match body["next_cursor"].as_str() {
            Some(c) => cursor = Some(c.to_string()),
            None => break,
        }
    }
    assert_eq!(seen.len(), 20_002, "no repeats or gaps");
    let mut deduped = seen.clone();
    deduped.sort();
    deduped.dedup();
    assert_eq!(deduped.len(), 20_002, "no repeats");
    // Folders first: adir, zdir lead.
    assert_eq!(seen[0], "adir");
    assert_eq!(seen[1], "zdir");
}

#[tokio::test]
async fn refused_paths_return_coded_errors() {
    let h = harness();
    for bad in ["../etc/passwd", "..%2fetc%2fpasswd", "~/.ssh/id_rsa"] {
        let uri = format!("/v1/stat?path={}", urlencoding(bad));
        let (status, body) = h.send(Method::GET, &uri, true, None).await;
        assert!(
            status == StatusCode::FORBIDDEN || status == StatusCode::BAD_REQUEST,
            "{bad} -> {status}"
        );
        assert!(body["code"].is_string());
    }
}

// -------------------------------------------------------------- resolve ---

#[tokio::test]
async fn resolve_reports_loose_and_zip_modes() {
    let h = harness();
    for i in 0..5 {
        h.write_file(&format!("few/f{i}.bin"), b"12345");
    }
    let (_s, body) = h
        .send(Method::POST, "/v1/resolve", true, Some(json!({ "paths": ["few"] })))
        .await;
    assert_eq!(body["mode"], "loose");
    assert_eq!(body["file_count"], 5);

    for i in 0..40 {
        h.write_file(&format!("many/f{i}.bin"), b"12345");
    }
    let (_s, body) = h
        .send(Method::POST, "/v1/resolve", true, Some(json!({ "paths": ["many"] })))
        .await;
    assert_eq!(body["mode"], "zip");
    assert_eq!(body["file_count"], 40);
}

#[tokio::test]
async fn resolve_keeps_newest_of_same_name_and_reports_skip() {
    let h = harness();
    h.write_file("a/cover.jpg", b"old");
    h.write_file("b/cover.jpg", b"new");
    // Make a/cover.jpg older.
    set_mtime(&h.trove_root.join("a/cover.jpg"), 1_000_000_000);
    set_mtime(&h.trove_root.join("b/cover.jpg"), 2_000_000_000);

    let (_s, body) = h
        .send(
            Method::POST,
            "/v1/resolve",
            true,
            Some(json!({ "paths": ["a", "b"] })),
        )
        .await;
    assert_eq!(body["file_count"], 1, "newer kept, older skipped");
    let collisions = body["collisions"].as_array().unwrap();
    assert_eq!(collisions.len(), 1);
    assert_eq!(collisions[0]["name"], "cover.jpg");
    assert_eq!(collisions[0]["kept"], "b/cover.jpg");
    assert_eq!(collisions[0]["skipped"][0], "a/cover.jpg");
}

// --------------------------------------------------------------- upload ---

#[tokio::test]
async fn upload_resume_and_commit_matches_checksum() {
    let h = harness();
    let data: Vec<u8> = (0..20_000u32).map(|i| (i % 251) as u8).collect();
    let checksum = format!("b3:{}", blake3::hash(&data).to_hex());

    let (status, init) = h
        .send(
            Method::POST,
            "/v1/upload/init",
            true,
            Some(json!({
                "path": "photos/2026/roll.cr3",
                "size_bytes": data.len(),
                "checksum": checksum,
                "mtime": 1_754_001_111i64,
            })),
        )
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let id = init["upload_id"].as_str().unwrap().to_string();
    assert_eq!(init["target_exists"], false);

    // Send the first half only, then "restart": GET status to see what's missing.
    let half = data.len() / 2;
    put_chunk(&h, &id, 0, &data[..half]).await;
    let (_s, st) = h.send(Method::GET, &format!("/v1/upload/{id}"), true, None).await;
    assert_eq!(st["received_bytes"], half as u64);
    let missing = st["missing"].as_array().unwrap();
    assert_eq!(missing[0][0], half as u64);
    assert_eq!(missing[0][1], data.len() as u64);

    // Send the rest and commit.
    put_chunk(&h, &id, half as u64, &data[half..]).await;
    let (status, commit) = h
        .send(
            Method::POST,
            &format!("/v1/upload/{id}/commit"),
            true,
            Some(json!({})),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(commit["identical"], false);
    assert_eq!(commit["size_bytes"], data.len() as u64);
    assert_eq!(std::fs::read(h.trove_root.join("photos/2026/roll.cr3")).unwrap(), data);
    // Usage rose by the file size.
    assert_eq!(commit["used_bytes"], data.len() as u64);
}

#[tokio::test]
async fn upload_over_limit_refused_at_init_with_no_staging() {
    let mut limits = Limits::default();
    limits.max_bytes = 1000; // tiny trove
    let h = harness_with_limits(limits);
    let (status, body) = h
        .send(
            Method::POST,
            "/v1/upload/init",
            true,
            Some(json!({ "path": "big.bin", "size_bytes": 5000 })),
        )
        .await;
    assert_eq!(status, StatusCode::INSUFFICIENT_STORAGE);
    assert_eq!(body["code"], "TROVE_FULL");
    assert!(body["message"].as_str().unwrap().contains("won't fit"));
    // No staging file created.
    let staging = h._dir.path().join("data/staging");
    let count = std::fs::read_dir(staging).map(|r| r.count()).unwrap_or(0);
    assert_eq!(count, 0);
}

// --------------------------------------------------------------- delete ---

#[tokio::test]
async fn delete_folder_frees_and_drops_total() {
    let h = harness();
    for i in 0..12 {
        h.write_file(&format!("scratch/f{i}.bin"), &vec![7u8; 1000]);
    }
    // Prime the running total.
    h.state.usage.recount().unwrap();
    let before = h.state.usage.used();
    assert_eq!(before, 12_000);

    let (status, body) = h
        .send(
            Method::POST,
            "/v1/delete",
            true,
            Some(json!({ "paths": ["scratch"] })),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["freed_bytes"], 12_000);
    assert_eq!(body["used_bytes"], 0);
    assert_eq!(body["deleted"][0]["kind"], "dir");
    assert_eq!(body["deleted"][0]["file_count"], 12);
    assert!(!h.trove_root.join("scratch").exists());
}

// ---------------------------------------------------------------- mkdir ---

#[tokio::test]
async fn mkdir_creates_then_is_idempotent() {
    let h = harness();
    let (status, body) = h
        .send(Method::POST, "/v1/mkdir", true, Some(json!({ "path": "photos/2026" })))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["created"][0], "photos/2026");
    assert!(h.trove_root.join("photos/2026").is_dir());

    let (status, body) = h
        .send(Method::POST, "/v1/mkdir", true, Some(json!({ "path": "photos/2026" })))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["created"].as_array().unwrap().len(), 0);
}

// ----------------------------------------------------------------- move ---

#[tokio::test]
async fn move_defaults_to_fail_on_conflict() {
    let h = harness();
    h.write_file("a.txt", b"one");
    h.write_file("b.txt", b"two");
    let (status, body) = h
        .send(
            Method::POST,
            "/v1/move",
            true,
            Some(json!({ "from": "a.txt", "to": "b.txt" })),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(body["code"], "TARGET_EXISTS");

    // suffix keeps both.
    let (status, body) = h
        .send(
            Method::POST,
            "/v1/move",
            true,
            Some(json!({ "from": "a.txt", "to": "b.txt", "on_conflict": "suffix" })),
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["to"], "b (1).txt");
    assert!(h.trove_root.join("b (1).txt").exists());
}

// --------------------------------------------------------------- events ---

#[tokio::test]
async fn watcher_announces_a_file_added_on_the_server() {
    let h = harness();
    let watcher = lymnal::events::watch_trove(
        h.state.trove.root().to_path_buf(),
        h.state.events.clone(),
    );
    // Some sandboxes lack inotify; skip cleanly if the watcher can't start.
    let Ok(_w) = watcher else { return };
    let mut rx = h.state.events.subscribe();

    // Give the watcher a moment to arm, then create a file directly.
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    h.write_file("dropped.txt", b"hi");

    let got = tokio::time::timeout(std::time::Duration::from_secs(3), async {
        loop {
            if let Ok(ev) = rx.recv().await {
                if ev.event == "change"
                    && ev.data["path"].as_str() == Some("dropped.txt")
                {
                    return true;
                }
            }
        }
    })
    .await
    .unwrap_or(false);
    assert!(got, "a change event should arrive for a file added on the server");
}

// --------------------------------------------------------------- helpers ---

async fn put_chunk(h: &Harness, id: &str, offset: u64, bytes: &[u8]) {
    let end = offset + bytes.len() as u64 - 1;
    let total = 20_000; // large enough for these tests
    let req = Request::builder()
        .method(Method::PUT)
        .uri(format!("/v1/upload/{id}"))
        .header(header::AUTHORIZATION, format!("Bearer {TOKEN}"))
        .header(header::CONTENT_RANGE, format!("bytes {offset}-{end}/{total}"))
        .body(Body::from(bytes.to_vec()))
        .unwrap();
    let resp = h.router().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

fn set_mtime(path: &std::path::Path, secs: i64) {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    let times = [
        libc::timespec { tv_sec: secs as libc::time_t, tv_nsec: 0 },
        libc::timespec { tv_sec: secs as libc::time_t, tv_nsec: 0 },
    ];
    unsafe {
        libc::utimensat(libc::AT_FDCWD, c.as_ptr(), times.as_ptr(), 0);
    }
}

/// Minimal percent-encoding for query values in test URIs.
fn urlencoding(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}
