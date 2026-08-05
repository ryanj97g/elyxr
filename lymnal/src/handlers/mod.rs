//! HTTP handlers: one function per endpoint (§04), grouped by section.
//!
//! Auth is explicit rather than middleware: every protected handler calls
//! [`require_auth`] first, and only health and pair skip it. `code` errors flow
//! out as the one §09 shape via [`ApiError`]'s IntoResponse.

mod admin;
mod browse;
mod mutate;
mod stream;
mod transfer;

use std::time::Duration;

use axum::extract::{DefaultBodyLimit, State};
use axum::http::HeaderMap;
use axum::routing::{get, post, put};
use axum::{Json, Router};
use base64::Engine;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::auth::Identity;
use crate::config::Role;
use crate::error::{ApiError, ErrCode};
use crate::pairing::{phrase_for, Decision};
use crate::state::Shared;

/// Assemble the full v1 router. Chunk uploads carry raw 8 MiB bodies, so the
/// default body limit is raised well past a single chunk.
pub fn router(state: Shared) -> Router {
    Router::new()
        .route("/v1/health", get(health))
        .route("/v1/pair", post(pair))
        .route("/v1/list", get(browse::list))
        .route("/v1/stat", get(browse::stat))
        .route("/v1/search", get(browse::search))
        .route("/v1/resolve", post(transfer::resolve))
        .route("/v1/download", get(transfer::download))
        .route("/v1/zip", post(transfer::zip))
        .route("/v1/upload/init", post(transfer::upload_init))
        .route(
            "/v1/upload/:id",
            put(transfer::upload_chunk)
                .get(transfer::upload_status)
                .delete(transfer::upload_delete),
        )
        .route("/v1/upload/:id/commit", post(transfer::upload_commit))
        .route("/v1/move", post(mutate::move_entry))
        .route("/v1/delete", post(mutate::delete))
        .route("/v1/mkdir", post(mutate::mkdir))
        .route("/v1/events", get(stream::events))
        // Server-mode admin surface (§08, §09), reached by the local admin
        // token — never exposed to ordinary clients.
        .route("/v1/admin/status", get(admin::status))
        .route("/v1/admin/pairing", post(admin::set_pairing))
        .route("/v1/admin/pending", get(admin::pending))
        .route("/v1/admin/approve", post(admin::approve))
        .route("/v1/admin/deny", post(admin::deny))
        .route("/v1/admin/devices", get(admin::devices))
        .route("/v1/admin/revoke", post(admin::revoke))
        .route("/v1/admin/space", get(admin::space))
        .route("/v1/admin/limits", post(admin::set_limits))
        .route("/v1/admin/recount", post(admin::recount))
        .route("/v1/admin/problems", get(admin::problems))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            record_problems,
        ))
        .layer(DefaultBodyLimit::max(32 * 1024 * 1024))
        .with_state(state)
}

/// Middleware that keeps the last twenty non-2xx responses for server mode's
/// recent-problems view, reading the coded body without consuming it.
async fn record_problems(
    State(s): State<Shared>,
    req: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let method = req.method().to_string();
    let path = req.uri().path().to_string();
    let resp = next.run(req).await;
    let status = resp.status();
    if status.is_client_error() || status.is_server_error() {
        // Admin/auth noise aside, capture the coded body for the problem line.
        let (parts, body) = resp.into_parts();
        let bytes = axum::body::to_bytes(body, 64 * 1024).await.unwrap_or_default();
        let parsed: Option<serde_json::Value> = serde_json::from_slice(&bytes).ok();
        s.record_problem(crate::state::ProblemLine {
            ts: now_secs(),
            method,
            path,
            status: status.as_u16(),
            code: parsed
                .as_ref()
                .and_then(|v| v.get("code").and_then(|c| c.as_str()).map(String::from)),
            message: parsed
                .as_ref()
                .and_then(|v| v.get("message").and_then(|c| c.as_str()).map(String::from)),
            request_id: parsed
                .as_ref()
                .and_then(|v| v.get("request_id").and_then(|c| c.as_str()).map(String::from)),
        });
        return axum::response::Response::from_parts(parts, axum::body::Body::from(bytes));
    }
    resp
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// The bearer token from an Authorization header, if present.
pub(crate) fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers.get(axum::http::header::AUTHORIZATION)?.to_str().ok()
}

/// Authenticate or fail with the coded auth error.
pub(crate) fn require_auth(state: &Shared, headers: &HeaderMap) -> Result<Identity, ApiError> {
    state.authenticate(bearer(headers))
}

/// Encode a paging offset into an opaque base64 cursor. Clients must not parse
/// it (§04); it is only ever handed back verbatim.
pub(crate) fn encode_cursor(offset: usize) -> String {
    base64::engine::general_purpose::STANDARD.encode(json!({ "after": offset }).to_string())
}

/// Decode a cursor back to an offset. A malformed cursor is treated as the
/// start of the listing rather than an error.
pub(crate) fn decode_cursor(cursor: &Option<String>) -> usize {
    let Some(c) = cursor else { return 0 };
    base64::engine::general_purpose::STANDARD
        .decode(c)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v.get("after").and_then(|a| a.as_u64()))
        .map(|n| n as usize)
        .unwrap_or(0)
}

// ---- §04 health & §08 pair: the two endpoints with no auth ----

async fn health(State(s): State<Shared>) -> Json<Value> {
    Json(json!({
        "version": s.version,
        "uptime_s": s.uptime_s(),
        "trove": s.trove_name(),
        "used_bytes": s.usage.used(),
        "max_bytes": s.usage.limits().max_bytes,
        "drive_free_bytes": s.usage.drive_free(),
        "pairing_open": s.pairing.is_open(),
    }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PairReq {
    device: String,
    client: String,
}

/// Pair a new device. Registers the request (both devices show the same
/// derived phrase) and blocks until a person at the server approves or denies,
/// or 120s pass. Refused with PAIRING_CLOSED when pairing is off.
async fn pair(State(s): State<Shared>, Json(req): Json<PairReq>) -> Result<Json<Value>, ApiError> {
    if !s.pairing.is_open() {
        return Err(ApiError::new(
            ErrCode::PairingClosed,
            "This server isn't accepting new devices right now. Open pairing in elyxr's server settings.",
        ));
    }
    let phrase = phrase_for(&req.device, &req.client);
    let rx = s.pairing.register(req.device.clone(), req.client.clone(), phrase);
    match tokio::time::timeout(Duration::from_secs(120), rx).await {
        Ok(Ok(Decision::Approve {
            token,
            role,
            max_bytes,
        })) => Ok(Json(json!({
            "token": token,
            "label": req.device,
            "role": role_str(role),
            "max_bytes": max_bytes,
        }))),
        Ok(Ok(Decision::Deny)) => Err(ApiError::new(
            ErrCode::PairingDenied,
            "The request was declined at the server.",
        )),
        // Sender dropped (server restarted, request forgotten) or timed out.
        Ok(Err(_)) | Err(_) => {
            s.pairing.forget(&req.device);
            Err(ApiError::new(
                ErrCode::PairingTimeout,
                "No one approved this device in time. Ask again when someone is at the server.",
            ))
        }
    }
}

fn role_str(role: Role) -> &'static str {
    match role {
        Role::Owner => "owner",
        Role::Guest => "guest",
    }
}
