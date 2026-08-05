//! The server-mode admin surface (§08, §09). lymnal has no interface of its
//! own; server-mode elyxr, on the same machine, reaches these with the local
//! admin token. They are never exposed to ordinary clients on the tailnet —
//! every one requires the `X-Admin-Token` header to match.

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::config::{Limits, Role};
use crate::error::{ApiError, ErrCode};
use crate::pairing::Decision;
use crate::state::Shared;

/// Gate on the local admin token. A missing or wrong token is refused as
/// permission denied — this surface is not for tailnet clients.
fn admin(s: &Shared, headers: &HeaderMap) -> Result<(), ApiError> {
    let ok = headers
        .get("x-admin-token")
        .and_then(|v| v.to_str().ok())
        .map(|t| t == s.admin_token)
        .unwrap_or(false);
    if ok {
        Ok(())
    } else {
        Err(ApiError::new(
            ErrCode::PermissionDenied,
            "This is a server-mode control and needs the local admin token.",
        ))
    }
}

pub(super) async fn status(
    State(s): State<Shared>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    Ok(Json(json!({
        "running": true,
        "version": s.version,
        "uptime_s": s.uptime_s(),
        "bind": s.bind_addr(),
        "trove": s.trove_name(),
        "pairing_open": s.pairing.is_open(),
    })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct PairingReq {
    open: bool,
}

pub(super) async fn set_pairing(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<PairingReq>,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    if req.open {
        s.pairing.open();
    } else {
        s.pairing.close();
    }
    Ok(Json(json!({ "pairing_open": s.pairing.is_open() })))
}

pub(super) async fn pending(
    State(s): State<Shared>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    let list: Vec<Value> = s
        .pairing
        .pending()
        .into_iter()
        .map(|p| json!({ "device": p.device, "client": p.client, "phrase": p.phrase }))
        .collect();
    Ok(Json(json!({ "pending": list })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ApproveReq {
    device: String,
    #[serde(default = "default_role")]
    role: Role,
    #[serde(default)]
    max_bytes: Option<u64>,
}

fn default_role() -> Role {
    Role::Owner
}

/// Approve a pending device, setting its role and (for a guest) its limit,
/// which defaults to 10 GB (§09).
pub(super) async fn approve(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<ApproveReq>,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    let max_bytes = req.max_bytes.unwrap_or(match req.role {
        Role::Owner => s.usage.limits().max_bytes,
        Role::Guest => 10_000_000_000,
    });
    let token = s.approve_device(&req.device, req.role, max_bytes);
    if !s.pairing.resolve(
        &req.device,
        Decision::Approve {
            token,
            role: req.role,
            max_bytes,
        },
    ) {
        // No one was waiting — undo so we don't leave a device with no client.
        s.revoke_device(&req.device);
        return Err(ApiError::new(
            ErrCode::NotFound,
            "There is no pending request from that device to approve.",
        ));
    }
    Ok(Json(json!({ "device": req.device, "role": role_str(req.role), "max_bytes": max_bytes })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct DenyReq {
    device: String,
}

pub(super) async fn deny(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<DenyReq>,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    s.pairing.resolve(&req.device, Decision::Deny);
    Ok(Json(json!({ "device": req.device, "denied": true })))
}

pub(super) async fn devices(
    State(s): State<Shared>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    let list: Vec<Value> = s
        .devices
        .all()
        .into_iter()
        .map(|d| {
            json!({
                "label": d.label,
                "role": role_str(d.role),
                "max_bytes": d.max_bytes,
                "approved_at": d.approved_at,
                "last_seen": d.last_seen,
            })
        })
        .collect();
    Ok(Json(json!({ "devices": list })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct RevokeReq {
    label: String,
}

pub(super) async fn revoke(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<RevokeReq>,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    let removed = s.revoke_device(&req.label);
    Ok(Json(json!({ "label": req.label, "revoked": removed })))
}

pub(super) async fn space(
    State(s): State<Shared>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    let l = s.usage.limits();
    Ok(Json(json!({
        "used_bytes": s.usage.used(),
        "drive_free_bytes": s.usage.drive_free(),
        "max_bytes": l.max_bytes,
        "warn_at_bytes": l.warn_at_bytes,
        "warn_every": l.warn_every,
        "min_free_bytes": l.min_free_bytes,
    })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct LimitsReq {
    max_bytes: Option<u64>,
    warn_at_bytes: Option<u64>,
    warn_every: Option<u64>,
    min_free_bytes: Option<u64>,
}

/// Edit the three (and a bit) space numbers, and write them back to the config
/// so they survive a restart.
pub(super) async fn set_limits(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<LimitsReq>,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    let current = s.usage.limits();
    let next = Limits {
        max_bytes: req.max_bytes.unwrap_or(current.max_bytes),
        warn_at_bytes: req.warn_at_bytes.unwrap_or(current.warn_at_bytes),
        warn_every: req.warn_every.unwrap_or(current.warn_every),
        min_free_bytes: req.min_free_bytes.unwrap_or(current.min_free_bytes),
    };
    s.usage.set_limits(next.clone());
    // Persist to the config file, best effort.
    {
        let mut cfg = s.cfg.write().unwrap();
        cfg.limits = next.clone();
        if let Some(path) = &s.config_path {
            if let Err(e) = cfg.save(path) {
                tracing::warn!(error = %e, "could not write the config after a limits change");
            }
        }
    }
    Ok(Json(json!({
        "max_bytes": next.max_bytes,
        "warn_at_bytes": next.warn_at_bytes,
        "warn_every": next.warn_every,
        "min_free_bytes": next.min_free_bytes,
    })))
}

pub(super) async fn recount(
    State(s): State<Shared>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    admin(&s, &headers)?;
    let total = s
        .usage
        .recount()
        .map_err(|e| ApiError::io(format!("Couldn't recount the trove: {e}")))?;
    Ok(Json(json!({ "used_bytes": total })))
}

pub(super) async fn problems(
    State(s): State<Shared>,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    admin(&s, &headers)?;
    Ok((
        StatusCode::OK,
        Json(json!({ "problems": s.recent_problems() })),
    ))
}

fn role_str(role: Role) -> &'static str {
    match role {
        Role::Owner => "owner",
        Role::Guest => "guest",
    }
}
