//! The client proxy.
//!
//! On a client, lymnal runs a small local HTTP server that the app (and the
//! gate) talk to, and forwards every call to the remote trove — with limbo in
//! front of it.
//!
//!   reads  (`/v1/download`)  are cached in limbo and served from there next time.
//!   writes (`/v1/upload/*`)  assemble into limbo, push to the trove, and unpin
//!                            on success. If the trove is unreachable the file
//!                            stays *held*, and a background pusher keeps trying
//!                            until it lands — so "save and you're done" holds
//!                            even through a connection lapse.
//!   everything else          is forwarded straight through with the stored
//!                            bearer token, so the app never holds a token and
//!                            never talks to the remote directly.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::{
    body::{Body, Bytes},
    extract::{Path as AxPath, Request, State},
    http::{header, StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::{any, post, put},
    Json, Router,
};
use serde_json::{json, Value};

use crate::limbo::{Limbo, StoreErr};

/// An upload being assembled locally before it's pushed to the trove.
struct Pending {
    path: String,
    mtime: i64,
    buf: Vec<u8>,
}

pub struct Proxy {
    /// host:port of the remote trove on the tailnet.
    remote: String,
    /// The bearer token this device was approved with.
    token: String,
    limbo: Limbo,
    /// Uploads mid-assembly, keyed by the id we handed the app.
    pending: Mutex<HashMap<String, Pending>>,
    /// Paths currently held (unsynced), with the mtime to push them under.
    held: Mutex<HashMap<String, i64>>,
    /// For ordinary calls (a list, a stat): fail the connect fast and cap the
    /// whole call, so a slow or vanished trove can't hang the request forever
    /// and exhaust the blocking pool — the cause of the app sitting on "READING…".
    quick: ureq::Agent,
    /// For long transfers (downloads, the event stream, pushes): fail the connect
    /// fast but put no cap on the body, which may legitimately run for a while.
    stream: ureq::Agent,
}

impl Proxy {
    pub fn new(remote: String, token: String, limbo: Limbo) -> Proxy {
        let quick = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(5))
            .timeout(Duration::from_secs(30))
            .build();
        let stream = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(5))
            .build();
        Proxy {
            remote,
            token,
            limbo,
            pending: Mutex::new(HashMap::new()),
            held: Mutex::new(HashMap::new()),
            quick,
            stream,
        }
    }

    fn auth(&self) -> String {
        format!("Bearer {}", self.token)
    }

    fn url(&self, path_and_query: &str) -> String {
        format!("http://{}{}", self.remote, path_and_query)
    }

    /// Retry every held file: push it to the trove, and unpin on success. Called
    /// on a timer and whenever the app asks to reconcile. Returns how many are
    /// still held afterwards.
    pub fn retry_held(self: &Arc<Self>) -> usize {
        let keys: Vec<String> = self.held.lock().unwrap().keys().cloned().collect();
        for path in keys {
            let mtime = self.held.lock().unwrap().get(&path).copied().unwrap_or_else(now);
            let Some(bytes) = self.limbo.read(&path) else {
                // The bytes are gone; drop the stale queue entry.
                self.held.lock().unwrap().remove(&path);
                continue;
            };
            if remote_upload(&self.stream, &self.remote, &self.token, &path, &bytes, mtime).is_ok() {
                self.limbo.set_held(&path, false); // now passing-through
                self.held.lock().unwrap().remove(&path);
            }
        }
        self.held.lock().unwrap().len()
    }
}

pub fn router(proxy: Arc<Proxy>) -> Router {
    Router::new()
        .route("/v1/download", any(download))
        .route("/v1/events", any(events))
        .route("/v1/upload/init", post(upload_init))
        .route("/v1/upload/:id", put(upload_chunk))
        .route("/v1/upload/:id/commit", post(upload_commit))
        .route("/v1/reconcile", post(reconcile))
        .fallback(forward)
        .with_state(proxy)
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// --- uploads → limbo → trove -------------------------------------------------

async fn upload_init(State(px): State<Arc<Proxy>>, Json(body): Json<Value>) -> Response {
    let path = body.get("path").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if path.is_empty() {
        return coded(400, "BAD_PATH", "The upload needs a path.");
    }
    let mtime = body.get("mtime").and_then(|v| v.as_i64()).unwrap_or_else(now);
    let id = format!("up_{}", ulid::Ulid::new());
    px.pending
        .lock()
        .unwrap()
        .insert(id.clone(), Pending { path, mtime, buf: Vec::new() });
    Json(json!({ "upload_id": id, "chunk_bytes": 8 * 1024 * 1024 })).into_response()
}

async fn upload_chunk(
    State(px): State<Arc<Proxy>>,
    AxPath(id): AxPath<String>,
    req: Request,
) -> Response {
    let offset = req
        .headers()
        .get(header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_range_start)
        .unwrap_or(0) as usize;
    let bytes = match axum::body::to_bytes(req.into_body(), usize::MAX).await {
        Ok(b) => b,
        Err(_) => return coded(400, "IO_ERROR", "The chunk couldn't be read."),
    };
    let mut pending = px.pending.lock().unwrap();
    let Some(p) = pending.get_mut(&id) else {
        return coded(404, "NOT_FOUND", "That upload isn't open.");
    };
    let end = offset + bytes.len();
    if p.buf.len() < end {
        p.buf.resize(end, 0);
    }
    p.buf[offset..end].copy_from_slice(&bytes);
    Json(json!({ "received_bytes": p.buf.len(), "complete": false })).into_response()
}

async fn upload_commit(State(px): State<Arc<Proxy>>, AxPath(id): AxPath<String>) -> Response {
    let Some(p) = px.pending.lock().unwrap().remove(&id) else {
        return coded(404, "NOT_FOUND", "That upload isn't open.");
    };
    // Hold the whole file in limbo first — it's the only copy until it lands.
    match px.limbo.store(&p.path, &p.buf, true) {
        Ok(()) => {}
        Err(StoreErr::NoRoomHeldBlocks) => {
            return coded(
                507,
                "LIMBO_FULL",
                "Unsynced changes can't be dropped, and free space is low. Save them somewhere local, restore the lymnal bond, then retry the sync.",
            );
        }
        Err(StoreErr::Io(_)) => return coded(500, "IO_ERROR", "The edit couldn't be saved locally."),
    }
    px.held.lock().unwrap().insert(p.path.clone(), p.mtime);

    // Try to push it right now.
    let agent = px.stream.clone();
    let remote = px.remote.clone();
    let token = px.token.clone();
    let path = p.path.clone();
    let buf = p.buf.clone();
    let mtime = p.mtime;
    let pushed = tokio::task::spawn_blocking(move || {
        remote_upload(&agent, &remote, &token, &path, &buf, mtime)
    })
    .await;

    match pushed {
        Ok(Ok(resp)) => {
            px.limbo.set_held(&p.path, false); // synced → passing-through
            px.held.lock().unwrap().remove(&p.path);
            Json(resp).into_response()
        }
        // The trove refused it (full, denied, …): don't queue it, drop the limbo
        // copy, and surface the coded error so the save doesn't look done.
        Ok(Err(PushErr::Rejected(parts))) => {
            px.limbo.drop(&p.path);
            px.held.lock().unwrap().remove(&p.path);
            parts.into_response()
        }
        // Couldn't reach the trove: it stays held, the pusher keeps trying, and
        // the save still reads as done so the user isn't left hanging.
        _ => Json(json!({ "path": p.path, "held": true })).into_response(),
    }
}

/// `/v1/reconcile` — the refresh control. Push anything stranded in limbo now.
async fn reconcile(State(px): State<Arc<Proxy>>) -> Response {
    let still_held = px.retry_held();
    Json(json!({ "held": still_held })).into_response()
}

/// Why a push to the trove failed.
enum PushErr {
    /// The trove couldn't be reached — keep the file held and retry.
    Unreachable,
    /// The trove answered with a refusal (full, denied, …) — don't queue it,
    /// surface the coded error to whoever's waiting.
    Rejected(Parts),
}

fn push_map(e: ureq::Error) -> PushErr {
    match e {
        ureq::Error::Transport(_) => PushErr::Unreachable,
        ureq::Error::Status(_, _) => PushErr::Rejected(ureq_err_parts(e)),
    }
}

/// Push a whole file to the trove with the upload protocol (init, chunks,
/// commit). Blocking; call inside spawn_blocking. A transport failure is
/// `Unreachable` (retryable); an HTTP refusal is `Rejected` (surface it).
fn remote_upload(
    agent: &ureq::Agent,
    remote: &str,
    token: &str,
    path: &str,
    bytes: &[u8],
    mtime: i64,
) -> Result<Value, PushErr> {
    let auth = format!("Bearer {token}");
    let base = format!("http://{remote}");
    let init: Value = agent
        .post(&format!("{base}/v1/upload/init"))
        .set("Authorization", &auth)
        .send_json(json!({ "path": path, "size_bytes": bytes.len(), "mtime": mtime }))
        .map_err(push_map)?
        .into_json()
        .map_err(|_| PushErr::Unreachable)?;
    let id = init
        .get("upload_id")
        .and_then(|v| v.as_str())
        .ok_or(PushErr::Unreachable)?;
    let chunk = init
        .get("chunk_bytes")
        .and_then(|v| v.as_u64())
        .unwrap_or(8 * 1024 * 1024) as usize;

    let total = bytes.len();
    let mut offset = 0usize;
    while offset < total {
        let end = (offset + chunk).min(total);
        let range = format!("bytes {offset}-{}/{total}", end - 1);
        agent
            .put(&format!("{base}/v1/upload/{id}"))
            .set("Authorization", &auth)
            .set("Content-Range", &range)
            .send_bytes(&bytes[offset..end])
            .map_err(push_map)?;
        offset = end;
    }
    agent
        .post(&format!("{base}/v1/upload/{id}/commit"))
        .set("Authorization", &auth)
        .send_json(json!({}))
        .map_err(push_map)?
        .into_json()
        .map_err(|_| PushErr::Unreachable)
}

// --- reads & pass-through ----------------------------------------------------

/// A trove-relative path from a `?path=` query, percent-decoded loosely.
fn path_param(uri: &Uri) -> Option<String> {
    let q = uri.query()?;
    for pair in q.split('&') {
        if let Some(v) = pair.strip_prefix("path=") {
            return Some(percent_decode(v));
        }
    }
    None
}

fn percent_decode(s: &str) -> String {
    let bytes = s.replace('+', " ");
    let mut out = Vec::new();
    let mut it = bytes.bytes();
    while let Some(b) = it.next() {
        if b == b'%' {
            if let (Some(h), Some(l)) = (it.next(), it.next()) {
                if let (Some(h), Some(l)) = ((h as char).to_digit(16), (l as char).to_digit(16)) {
                    out.push((h * 16 + l) as u8);
                    continue;
                }
            }
        } else {
            out.push(b);
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Forward any request to the remote trove verbatim, injecting the bearer token.
async fn forward(State(px): State<Arc<Proxy>>, req: Request) -> Response {
    let method = req.method().clone();
    let uri = req.uri().clone();
    let content_type = header_str(&req, header::CONTENT_TYPE);
    let content_range = header_str(&req, header::CONTENT_RANGE);
    let body = match axum::body::to_bytes(req.into_body(), usize::MAX).await {
        Ok(b) => b,
        Err(_) => return coded(400, "IO_ERROR", "The request body couldn't be read."),
    };
    let url = px.url(uri.path_and_query().map(|pq| pq.as_str()).unwrap_or("/"));
    let auth = px.auth();
    let agent = px.quick.clone();

    let sent = tokio::task::spawn_blocking(move || {
        let mut r = agent.request(method.as_str(), &url).set("Authorization", &auth);
        if let Some(ct) = &content_type {
            r = r.set("Content-Type", ct);
        }
        if let Some(cr) = &content_range {
            r = r.set("Content-Range", cr);
        }
        let resp = if body.is_empty() { r.call() } else { r.send_bytes(&body) };
        ureq_to_parts(resp)
    })
    .await;

    match sent {
        Ok(parts) => parts.into_response(),
        Err(_) => unreachable(),
    }
}

async fn download(State(px): State<Arc<Proxy>>, req: Request) -> Response {
    let uri = req.uri().clone();
    let range_from = req
        .headers()
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_range_start);

    let Some(key) = path_param(&uri) else {
        return coded(400, "BAD_PATH", "The download needs a path.");
    };

    if let Some(bytes) = px.limbo.read(&key) {
        return ranged(bytes, range_from);
    }

    // Fetch the whole file from the trove, forwarding the original query verbatim
    // (so a path with spaces or other characters survives). Range is a header, so
    // it isn't here — limbo always caches the complete copy.
    let url = px.url(uri.path_and_query().map(|pq| pq.as_str()).unwrap_or("/v1/download"));
    let auth = px.auth();
    let agent = px.stream.clone();
    let fetched = tokio::task::spawn_blocking(move || -> Result<Vec<u8>, Parts> {
        match agent.get(&url).set("Authorization", &auth).call() {
            Ok(r) => {
                let mut buf = Vec::new();
                std::io::Read::read_to_end(&mut r.into_reader(), &mut buf).map_err(|_| io_parts())?;
                Ok(buf)
            }
            Err(e) => Err(ureq_err_parts(e)),
        }
    })
    .await;

    match fetched {
        Ok(Ok(bytes)) => {
            let _ = px.limbo.store(&key, &bytes, false); // passing-through
            ranged(bytes, range_from)
        }
        Ok(Err(parts)) => parts.into_response(),
        Err(_) => unreachable(),
    }
}

async fn events(State(px): State<Arc<Proxy>>) -> Response {
    let url = px.url("/v1/events");
    let auth = px.auth();
    let agent = px.stream.clone();
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(16);

    tokio::task::spawn_blocking(move || {
        let resp = match agent.get(&url).set("Authorization", &auth).call() {
            Ok(r) => r,
            Err(_) => return,
        };
        let mut reader = resp.into_reader();
        let mut buf = [0u8; 4096];
        loop {
            match std::io::Read::read(&mut reader, &mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if tx.blocking_send(Ok(Bytes::copy_from_slice(&buf[..n]))).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let stream = tokio_stream::wrappers::ReceiverStream::new(rx);
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .body(Body::from_stream(stream))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

// --- ureq → axum plumbing ----------------------------------------------------

fn header_str(req: &Request, name: header::HeaderName) -> Option<String> {
    req.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned)
}

struct Parts {
    status: u16,
    content_type: Option<String>,
    body: Vec<u8>,
}

impl IntoResponse for Parts {
    fn into_response(self) -> Response {
        let status = StatusCode::from_u16(self.status).unwrap_or(StatusCode::BAD_GATEWAY);
        let mut b = Response::builder().status(status);
        if let Some(ct) = self.content_type {
            b = b.header(header::CONTENT_TYPE, ct);
        }
        b.body(Body::from(self.body))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
    }
}

fn ureq_to_parts(resp: Result<ureq::Response, ureq::Error>) -> Parts {
    match resp {
        Ok(r) => {
            let status = r.status();
            let content_type = r.header("Content-Type").map(str::to_owned);
            let mut body = Vec::new();
            let _ = std::io::Read::read_to_end(&mut r.into_reader(), &mut body);
            Parts { status, content_type, body }
        }
        Err(e) => ureq_err_parts(e),
    }
}

fn ureq_err_parts(e: ureq::Error) -> Parts {
    match e {
        ureq::Error::Status(code, r) => {
            let content_type = r.header("Content-Type").map(str::to_owned);
            let mut body = Vec::new();
            let _ = std::io::Read::read_to_end(&mut r.into_reader(), &mut body);
            Parts { status: code, content_type, body }
        }
        ureq::Error::Transport(_) => Parts {
            status: 503,
            content_type: Some("application/json".into()),
            body: br#"{"code":"IO_ERROR","message":"The trove can't be reached right now."}"#.to_vec(),
        },
    }
}

fn io_parts() -> Parts {
    Parts {
        status: 502,
        content_type: Some("application/json".into()),
        body: br#"{"code":"IO_ERROR","message":"The trove sent an unreadable response."}"#.to_vec(),
    }
}

fn coded(status: u16, code: &str, message: &str) -> Response {
    Parts {
        status,
        content_type: Some("application/json".into()),
        body: json!({ "code": code, "message": message }).to_string().into_bytes(),
    }
    .into_response()
}

fn unreachable() -> Response {
    (StatusCode::INTERNAL_SERVER_ERROR, "proxy task failed").into_response()
}

/// Parse the start offset from `bytes=N-` or `bytes N-…`.
fn parse_range_start(v: &str) -> Option<u64> {
    let v = v.trim_start_matches("bytes").trim_start_matches(['=', ' ']);
    v.split(['-', ' ']).next()?.parse::<u64>().ok()
}

/// Serve `bytes`, honoring a resume offset with a 206 and Content-Range.
fn ranged(bytes: Vec<u8>, range_from: Option<u64>) -> Response {
    let total = bytes.len() as u64;
    match range_from {
        Some(from) if from > 0 && from < total => {
            let slice = bytes[(from as usize)..].to_vec();
            Response::builder()
                .status(StatusCode::PARTIAL_CONTENT)
                .header(header::CONTENT_RANGE, format!("bytes {from}-{}/{total}", total - 1))
                .header(header::CONTENT_TYPE, "application/octet-stream")
                .body(Body::from(slice))
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
        }
        _ => Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .body(Body::from(bytes))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
    }
}
