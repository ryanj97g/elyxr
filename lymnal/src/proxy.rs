//! The client proxy.
//!
//! On a client, lymnal runs a small local HTTP server that the app (and the
//! gate) talk to, and forwards every call to the remote trove — with lymbo in
//! front of it.
//!
//!   reads  (`/v1/download`)  stream straight from the trove and are NOT kept —
//!                            lymbo is a write-back buffer, never a read cache.
//!                            The one exception: a file with an unsynced local
//!                            write is served from lymbo until it's pushed, since
//!                            its local bytes are the freshest.
//!   writes (`/v1/upload/*`)  assemble into lymbo, push to the trove, and are
//!                            evicted from lymbo the moment they land. If the
//!                            trove is unreachable the file stays *held*, and a
//!                            background pusher keeps trying until it lands — so
//!                            "save and you're done" holds even through a lapse.
//!   everything else          is forwarded straight through with the stored
//!                            bearer token, so the app never holds a token and
//!                            never talks to the remote directly.

use std::collections::HashMap;
use std::path::PathBuf;
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
use tokio::sync::Notify;

use crate::lymbo::{Lymbo, StoreErr};

/// An upload being assembled locally before it's pushed to the trove.
struct Pending {
    path: String,
    mtime: i64,
    size: usize,
    buf: Vec<u8>,
}

pub struct Proxy {
    /// host:port of the remote trove on the tailnet.
    remote: String,
    /// The bearer token this device was approved with.
    token: String,
    lymbo: Lymbo,
    /// Uploads mid-assembly, keyed by the id we handed the app.
    pending: Mutex<HashMap<String, Pending>>,
    /// Paths currently held (unsynced), with the mtime to push them under. This
    /// is the outbound push queue; it's persisted so a restart mid-batch never
    /// strands a held file (the bytes live in lymbo on disk).
    held: Mutex<HashMap<String, i64>>,
    /// Where the held queue is persisted, inside the lymbo dir.
    held_state: PathBuf,
    /// Wakes the background pusher the instant a commit lands, so a file doesn't
    /// wait for the next timer tick to start heading for the trove.
    pusher: Notify,
    /// Held only while a push drain is running. The background loop and a manual
    /// reconcile both drain the queue; this makes sure only one does at a time, so
    /// they can't double-push a file or run two sweeps at once.
    drain_lock: Mutex<()>,
    /// For ordinary calls (a list, a stat): fail the connect fast and cap the
    /// whole call, so a slow or vanished trove can't hang the request forever
    /// and exhaust the blocking pool — the cause of the app sitting on "READING…".
    quick: ureq::Agent,
    /// For long transfers (downloads, the event stream, pushes): fail the connect
    /// fast but put no cap on the body, which may legitimately run for a while.
    stream: ureq::Agent,
}

impl Proxy {
    pub fn new(remote: String, token: String, lymbo: Lymbo) -> Proxy {
        let quick = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(5))
            .timeout(Duration::from_secs(30))
            .build();
        let stream = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(5))
            .build();
        // The held queue survives a restart: reload whatever hadn't finished
        // pushing last time. The bytes are still in lymbo on disk.
        let held_state = lymbo.aux_path("held.json");
        let held = load_held(&held_state);
        Proxy {
            remote,
            token,
            lymbo,
            pending: Mutex::new(HashMap::new()),
            held: Mutex::new(held),
            held_state,
            pusher: Notify::new(),
            drain_lock: Mutex::new(()),
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

    /// Wake the background pusher now (a commit just added work).
    fn kick_pusher(&self) {
        self.pusher.notify_one();
    }

    /// Block until the pusher is kicked (used by the background drain loop).
    pub async fn wait_for_kick(&self) {
        self.pusher.notified().await;
    }

    /// Write the held queue to disk (best effort). Called whenever it changes so
    /// a restart resumes exactly where it left off. The write happens while the
    /// queue lock is held, so two commits finishing together can't write the file
    /// out of order and leave a stale entry behind.
    fn persist_held(&self) {
        let map = self.held.lock().unwrap();
        if let Some(parent) = self.held_state.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(bytes) = serde_json::to_vec(&*map) {
            let _ = std::fs::write(&self.held_state, bytes);
        }
    }

    /// How many files are still waiting to reach the trove. The updater reads this
    /// so a restart never fires while lymbo still holds unsynced work.
    pub fn held_count(&self) -> usize {
        self.held.lock().unwrap().len()
    }

    /// Retry every held file: push it to the trove, and unpin on success. A file
    /// that can't be pushed (trove unreachable or refusing) stays held and is
    /// tried again — it is never dropped, so nothing is lost. Called on a timer,
    /// on a commit, and whenever the app asks to reconcile. Returns how many are
    /// still held afterwards.
    pub fn retry_held(self: &Arc<Self>) -> usize {
        // Single-flight: if a drain is already running (the background loop and a
        // manual reconcile can both call this), don't start a second one — just
        // report the current backlog. The running drain covers the same work.
        let _drain = match self.drain_lock.try_lock() {
            Ok(g) => g,
            Err(_) => return self.held.lock().unwrap().len(),
        };
        // Oldest first, so the file that has waited longest goes first.
        let keys: Vec<String> = self.lymbo.held_keys();
        // Fall back to the queue's own order if lymbo has forgotten its in-memory
        // index (e.g. right after a restart) — the persisted queue is the truth.
        let keys = if keys.is_empty() {
            self.held.lock().unwrap().keys().cloned().collect()
        } else {
            keys
        };
        let mut changed = false;
        for path in keys {
            // Only push things the queue still wants pushed.
            let Some(mtime) = self.held.lock().unwrap().get(&path).copied() else {
                continue;
            };
            let Some(bytes) = self.lymbo.read(&path) else {
                // The bytes are genuinely gone; drop the stale queue entry.
                self.held.lock().unwrap().remove(&path);
                changed = true;
                continue;
            };
            if remote_upload(&self.stream, &self.remote, &self.token, &path, &bytes, mtime).is_ok() {
                // Unpin only if the same version is still the one queued. If the
                // file was re-uploaded while this push was in flight (a newer
                // mtime), leave it held so the newer bytes get pushed next round —
                // don't mark it synced on the strength of the older push.
                let mut h = self.held.lock().unwrap();
                if h.get(&path).copied() == Some(mtime) {
                    h.remove(&path);
                    drop(h);
                    // Synced — evict it from lymbo right now. It has served its one
                    // purpose (holding the change until it reached the trove); it
                    // is NOT kept around as a read cache.
                    self.lymbo.drop(&path);
                    changed = true;
                }
            }
        }
        if changed {
            self.persist_held();
        }
        self.held.lock().unwrap().len()
    }
}

/// Load the persisted held queue, or an empty one if there's nothing (or it's
/// unreadable — the timer will rebuild it as work lands).
fn load_held(path: &std::path::Path) -> HashMap<String, i64> {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub fn router(proxy: Arc<Proxy>) -> Router {
    Router::new()
        .route("/v1/download", any(download))
        .route("/v1/events", any(events))
        .route("/v1/upload/init", post(upload_init))
        .route(
            "/v1/upload/:id",
            put(upload_chunk).get(upload_status).delete(upload_discard),
        )
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

// --- uploads → lymbo → trove -------------------------------------------------

async fn upload_init(State(px): State<Arc<Proxy>>, Json(body): Json<Value>) -> Response {
    let path = body.get("path").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if path.is_empty() {
        return coded(400, "BAD_PATH", "The upload needs a path.");
    }
    let mtime = body.get("mtime").and_then(|v| v.as_i64()).unwrap_or_else(now);
    let size = body
        .get("size_bytes")
        .and_then(|v| v.as_u64())
        .unwrap_or(0) as usize;
    let id = format!("up_{}", ulid::Ulid::new());
    px.pending.lock().unwrap().insert(
        id.clone(),
        Pending { path, mtime, size, buf: Vec::new() },
    );
    Json(json!({ "upload_id": id, "chunk_bytes": 8 * 1024 * 1024 })).into_response()
}

/// Progress for an in-flight upload, so a retry can resume rather than restart.
/// The app writes chunks in order, so what's buffered is what's contiguously
/// received. An unknown id (already committed, or never opened here) reports
/// nothing received and nothing missing, so the app moves on to commit — which
/// is idempotent and won't error on it.
async fn upload_status(State(px): State<Arc<Proxy>>, AxPath(id): AxPath<String>) -> Response {
    let pending = px.pending.lock().unwrap();
    match pending.get(&id) {
        Some(p) => {
            let received = p.buf.len() as u64;
            let size = p.size as u64;
            let missing = if size > received {
                json!([[received, size]])
            } else {
                json!([])
            };
            Json(json!({
                "received_bytes": received,
                "size_bytes": size,
                "missing": missing,
                "expires_at": 0,
            }))
            .into_response()
        }
        None => Json(json!({
            "received_bytes": 0,
            "size_bytes": 0,
            "missing": [],
            "expires_at": 0,
        }))
        .into_response(),
    }
}

/// Abandon an in-flight upload, freeing its buffer. Idempotent — an unknown id is
/// already gone, which is the desired end state, so it still reports success.
async fn upload_discard(State(px): State<Arc<Proxy>>, AxPath(id): AxPath<String>) -> Response {
    px.pending.lock().unwrap().remove(&id);
    Json(json!({ "ok": true })).into_response()
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
        // Unknown id: the upload was already committed here (a retried commit whose
        // first response the app didn't get), so the file is already safe in lymbo.
        // Don't fail it — a false error here is exactly what stranded uploads
        // before, reporting failures for files that had actually landed.
        return Json(json!({ "held": true })).into_response();
    };
    // Land the whole file in lymbo, held — it's the only copy until it reaches the
    // trove. This is a local disk write, so commit returns fast and can't time the
    // app out while a large file crosses the network.
    match px.lymbo.store(&p.path, &p.buf, true) {
        Ok(()) => {}
        Err(StoreErr::NoRoomHeldBlocks) => {
            return coded(
                507,
                "LYMBO_FULL",
                "Unsynced changes can't be dropped, and free space is low. Save them somewhere local, restore the lymnal bond, then retry the sync.",
            );
        }
        Err(StoreErr::Io(_)) => return coded(500, "IO_ERROR", "The edit couldn't be saved locally."),
    }
    px.held.lock().unwrap().insert(p.path.clone(), p.mtime);
    px.persist_held();

    // Hand it to the background pusher and return now. The file is safe in lymbo,
    // so from the app's side the save is done; the pusher lands it on the trove and
    // unpins it, retrying through any lapse. Pushing here inline (as it once did)
    // is what made a big file's commit outrun the app's timeout, so it retried,
    // hit an already-consumed upload, and reported a failure for a file that had
    // in fact landed. It no longer waits.
    px.kick_pusher();
    Json(json!({ "path": p.path, "held": true })).into_response()
}

/// `/v1/reconcile` — the refresh control. Push anything stranded in lymbo now.
/// The drain is blocking, so it runs on a blocking thread rather than stalling an
/// async worker; the single-flight lock means it won't collide with the timer's
/// drain — whichever holds the lock does the work, the other reports the backlog.
async fn reconcile(State(px): State<Arc<Proxy>>) -> Response {
    let still_held = tokio::task::spawn_blocking(move || px.retry_held())
        .await
        .unwrap_or(0);
    Json(json!({ "held": still_held })).into_response()
}

/// Why a push to the trove failed. Either way the file stays held and is tried
/// again — a push failure never drops it — so the two cases only differ in
/// intent, not handling; the pusher checks success and moves on.
enum PushErr {
    /// The trove couldn't be reached.
    Unreachable,
    /// The trove answered with a refusal (full, denied, …).
    Rejected,
}

fn push_map(e: ureq::Error) -> PushErr {
    match e {
        ureq::Error::Transport(_) => PushErr::Unreachable,
        ureq::Error::Status(_, _) => PushErr::Rejected,
    }
}

/// Push a whole file to the trove with the upload protocol (init, chunks,
/// commit). Blocking; call inside spawn_blocking. Any failure leaves the file
/// held for a later retry.
fn remote_upload(
    agent: &ureq::Agent,
    remote: &str,
    token: &str,
    path: &str,
    bytes: &[u8],
    mtime: i64,
) -> Result<(), PushErr> {
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
        .map_err(push_map)?;
    Ok(())
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

    // The ONLY thing lymbo serves is a locally-HELD write — a file changed here
    // that hasn't been pushed to the trove yet, so its local bytes are the
    // freshest. Everything else streams from the trove and is never retained:
    // lymbo is a write-back buffer, not a read cache. (Keeping read files hot for
    // faster replay would be a cache we never designed — that's not elyxr.)
    if px.held.lock().unwrap().contains_key(&key) {
        if let Some(bytes) = px.lymbo.read(&key) {
            return ranged(bytes, range_from);
        }
    }

    // Fetch the whole file from the trove, forwarding the original query verbatim
    // (so a path with spaces or other characters survives).
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
        // Serve it straight through — NOT stored. lymbo keeps only unsynced
        // writes, never plain reads.
        Ok(Ok(bytes)) => ranged(bytes, range_from),
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
