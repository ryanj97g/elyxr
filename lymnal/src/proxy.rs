//! The client proxy.
//!
//! On a client, lymnal runs a small local HTTP server that the app (and the
//! gate) talk to, and forwards every call to the remote trove — with limbo in
//! front of it. Reads (`/v1/download`) are cached in limbo and served from there
//! next time; everything else is forwarded straight through with the stored
//! bearer token, so the app never holds a token itself and never talks to the
//! remote directly.
//!
//! This is the plumbing only. Queuing an edit into limbo when the trove is
//! unreachable — held work, sync-then-unpin — is the monitor's job and lands
//! next.

use std::sync::Arc;

use axum::{
    body::{Body, Bytes},
    extract::{Request, State},
    http::{header, HeaderMap, Method, StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::any,
    Router,
};

use crate::limbo::Limbo;

pub struct Proxy {
    /// host:port of the remote trove on the tailnet.
    remote: String,
    /// The bearer token this device was approved with.
    token: String,
    limbo: Limbo,
}

impl Proxy {
    pub fn new(remote: String, token: String, limbo: Limbo) -> Proxy {
        Proxy { remote, token, limbo }
    }

    fn auth(&self) -> String {
        format!("Bearer {}", self.token)
    }

    fn url(&self, path_and_query: &str) -> String {
        format!("http://{}{}", self.remote, path_and_query)
    }
}

pub fn router(proxy: Arc<Proxy>) -> Router {
    Router::new()
        .route("/v1/download", any(download))
        .route("/v1/events", any(events))
        .fallback(forward)
        .with_state(proxy)
}

/// A trove-relative path from a `?path=` query, percent-decoded loosely (the
/// values elyxr sends are simple). Used as the limbo cache key.
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
            let h = it.next();
            let l = it.next();
            if let (Some(h), Some(l)) = (h, l) {
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

/// Forward any request to the remote trove verbatim, injecting the bearer token,
/// and hand the response back. Used for everything except download and events.
async fn forward(State(px): State<Arc<Proxy>>, req: Request) -> Response {
    let method = req.method().clone();
    let uri = req.uri().clone();
    let content_type = req
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let content_range = req
        .headers()
        .get(header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let body = match axum::body::to_bytes(req.into_body(), usize::MAX).await {
        Ok(b) => b,
        Err(_) => return (StatusCode::BAD_REQUEST, "unreadable request body").into_response(),
    };
    let url = px.url(uri.path_and_query().map(|pq| pq.as_str()).unwrap_or("/"));
    let auth = px.auth();

    let sent = tokio::task::spawn_blocking(move || {
        let mut r = ureq::request(method.as_str(), &url).set("Authorization", &auth);
        if let Some(ct) = &content_type {
            r = r.set("Content-Type", ct);
        }
        if let Some(cr) = &content_range {
            r = r.set("Content-Range", cr);
        }
        let resp = if body.is_empty() {
            r.call()
        } else {
            r.send_bytes(&body)
        };
        ureq_to_parts(resp)
    })
    .await;

    match sent {
        Ok(parts) => parts.into_response(),
        Err(_) => unreachable(),
    }
}

/// `/v1/download` — serve from limbo when cached, otherwise fetch the whole file
/// from the trove, cache it (passing-through), and serve. Honors a `Range:
/// bytes=N-` request by slicing, so the app's resume path keeps working.
async fn download(State(px): State<Arc<Proxy>>, req: Request) -> Response {
    let uri = req.uri().clone();
    let range_from = req
        .headers()
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_range_from);

    let Some(key) = path_param(&uri) else {
        return (StatusCode::BAD_REQUEST, "missing path").into_response();
    };

    // Cache hit.
    if let Some(bytes) = px.limbo.read(&key) {
        return ranged(bytes, range_from);
    }

    // Miss — fetch the whole file from the trove and cache it.
    let url = px.url(uri.path_and_query().map(|pq| pq.as_str()).unwrap_or("/"));
    let auth = px.auth();
    let fetched = tokio::task::spawn_blocking(move || -> Result<Vec<u8>, Parts> {
        // Fetch the whole file (no Range) so limbo holds the complete copy.
        let base = url.split('&').next().unwrap_or(&url);
        let clean = base.strip_suffix('?').unwrap_or(base).to_string();
        // Keep only path=..., dropping any range-ish extras the app added.
        let resp = ureq::get(&clean).set("Authorization", &auth).call();
        match resp {
            Ok(r) => {
                let mut buf = Vec::new();
                std::io::Read::read_to_end(&mut r.into_reader(), &mut buf)
                    .map_err(|_| io_parts())?;
                Ok(buf)
            }
            Err(e) => Err(ureq_err_parts(e)),
        }
    })
    .await;

    match fetched {
        Ok(Ok(bytes)) => {
            // Best-effort cache; serving still works if the store is refused.
            let _ = px.limbo.store(&key, &bytes, false);
            ranged(bytes, range_from)
        }
        Ok(Err(parts)) => parts.into_response(),
        Err(_) => unreachable(),
    }
}

/// `/v1/events` — forward the trove's server-sent event stream so live changes
/// reach the app. Read on a blocking thread, piped into the response body.
async fn events(State(px): State<Arc<Proxy>>) -> Response {
    let url = px.url("/v1/events");
    let auth = px.auth();
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(16);

    tokio::task::spawn_blocking(move || {
        let resp = match ureq::get(&url).set("Authorization", &auth).call() {
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
                        break; // the app disconnected
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

// --- turning a blocking ureq response into an axum response ------------------

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

/// A ureq error becomes the coded body the app already understands, so an
/// unreachable trove reads as a connection fault rather than a bare 502.
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

fn unreachable() -> Response {
    (StatusCode::INTERNAL_SERVER_ERROR, "proxy task failed").into_response()
}

/// Parse `bytes=N-` and return N.
fn parse_range_from(v: &str) -> Option<u64> {
    v.strip_prefix("bytes=")?
        .split('-')
        .next()?
        .parse::<u64>()
        .ok()
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

// Silence an unused-warning on Method when the fallback captures it via Request.
#[allow(dead_code)]
fn _uses(_m: Method, _h: HeaderMap) {}
