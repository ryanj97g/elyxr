//! Changing things: move/rename, delete, mkdir (§04, §06).

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::error::{ApiError, ErrCode};
use crate::model::{child_count, entry_for};
use crate::state::Shared;

use super::require_auth;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct MoveReq {
    from: String,
    to: String,
    #[serde(default)]
    on_conflict: Option<String>, // "fail" (default) | "replace" | "suffix"
}

/// `POST /v1/move` — rename and move are the same call; same filesystem, so it
/// is a rename, never a copy.
pub(super) async fn move_entry(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<MoveReq>,
) -> Result<Json<Value>, ApiError> {
    require_auth(&s, &headers)?;
    let from = s.trove.resolve(&req.from)?;
    let mut to = s.trove.resolve_new(&req.to)?;
    let policy = req.on_conflict.as_deref().unwrap_or("fail");

    let mut replaced = false;
    if to.abs.exists() {
        match policy {
            "replace" => {
                remove_any(&to.abs).map_err(|e| ApiError::from_io(&e, &to.rel))?;
                replaced = true;
            }
            "suffix" => {
                to = suffixed(&s, &to.rel)?;
            }
            _ => return Err(ApiError::target_exists(&to.rel)),
        }
    }

    if let Some(parent) = to.abs.parent() {
        std::fs::create_dir_all(parent).map_err(|e| ApiError::from_io(&e, &to.rel))?;
    }
    std::fs::rename(&from.abs, &to.abs).map_err(|e| ApiError::from_io(&e, &req.from))?;

    // Announce as a removal at the old path and a creation at the new one.
    s.events.change("removed", &from.rel, None);
    s.events.change("created", &to.rel, fresh_entry(&to.abs));

    Ok(Json(json!({
        "from": from.rel,
        "to": to.rel,
        "replaced": replaced,
    })))
}

/// Find `name (1).ext`, `name (2).ext`, … that does not yet exist.
fn suffixed(s: &Shared, rel: &str) -> Result<crate::trove::Resolved, ApiError> {
    let (stem, ext) = split_ext(rel);
    for n in 1..10_000 {
        let candidate = match &ext {
            Some(e) => format!("{stem} ({n}).{e}"),
            None => format!("{stem} ({n})"),
        };
        let r = s.trove.resolve_new(&candidate)?;
        if !r.abs.exists() {
            return Ok(r);
        }
    }
    Err(ApiError::new(
        ErrCode::TargetExists,
        "Too many files with this name already exist.",
    ))
}

/// Split a trove-relative path into (path-without-final-extension, extension).
fn split_ext(rel: &str) -> (String, Option<String>) {
    match rel.rsplit_once('.') {
        // Only treat a dot in the final component as an extension.
        Some((stem, ext)) if !ext.contains('/') && !stem.ends_with('/') && !stem.is_empty() => {
            (stem.to_string(), Some(ext.to_string()))
        }
        _ => (rel.to_string(), None),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct DeleteReq {
    paths: Vec<String>,
}

/// `POST /v1/delete` — permanent. Folders go with their contents. Partial
/// success is normal: each path succeeds or lands in `failed` with its code
/// and message.
pub(super) async fn delete(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<DeleteReq>,
) -> Result<Json<Value>, ApiError> {
    require_auth(&s, &headers)?;

    let mut deleted = Vec::new();
    let mut failed = Vec::new();
    let mut freed: u64 = 0;

    for raw in &req.paths {
        match delete_one(&s, raw) {
            Ok(rec) => {
                freed += rec.size;
                s.events.change("removed", &rec.rel, None);
                let mut entry = json!({ "path": rec.rel, "kind": rec.kind, "size_bytes": rec.size });
                if rec.kind == "dir" {
                    entry
                        .as_object_mut()
                        .unwrap()
                        .insert("file_count".into(), json!(rec.file_count));
                }
                deleted.push(entry);
            }
            Err(e) => failed.push(json!({
                "path": raw,
                "code": e.code.as_str(),
                "message": e.message,
            })),
        }
    }

    let used = s.usage.adjust(-(freed as i64));
    Ok(Json(json!({
        "deleted": deleted,
        "failed": failed,
        "freed_bytes": freed,
        "used_bytes": used,
    })))
}

struct DeletedRec {
    rel: String,
    kind: &'static str,
    size: u64,
    file_count: u64,
}

fn delete_one(s: &Shared, raw: &str) -> Result<DeletedRec, ApiError> {
    let r = s.trove.resolve(raw)?;
    let meta = std::fs::symlink_metadata(&r.abs).map_err(|e| ApiError::from_io(&e, raw))?;
    if meta.is_dir() {
        let (size, count) = dir_size_and_count(&r.abs);
        std::fs::remove_dir_all(&r.abs).map_err(|e| ApiError::from_io(&e, raw))?;
        Ok(DeletedRec {
            rel: r.rel,
            kind: "dir",
            size,
            file_count: count,
        })
    } else {
        let size = meta.len();
        std::fs::remove_file(&r.abs).map_err(|e| ApiError::from_io(&e, raw))?;
        Ok(DeletedRec {
            rel: r.rel,
            kind: "file",
            size,
            file_count: 0,
        })
    }
}

fn dir_size_and_count(root: &std::path::Path) -> (u64, u64) {
    let mut size = 0u64;
    let mut count = 0u64;
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let rd = match std::fs::read_dir(&dir) {
            Ok(rd) => rd,
            Err(_) => continue,
        };
        for de in rd.flatten() {
            let m = match de.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            if m.is_dir() && !m.is_symlink() {
                stack.push(de.path());
            } else if m.is_file() {
                size += m.len();
                count += 1;
            }
        }
    }
    (size, count)
}

fn remove_any(path: &std::path::Path) -> std::io::Result<()> {
    let meta = std::fs::symlink_metadata(path)?;
    if meta.is_dir() {
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_file(path)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct MkdirReq {
    path: String,
}

/// `POST /v1/mkdir` — parents created as needed. New folder → 201; an existing
/// folder → 200 with `created: []`.
pub(super) async fn mkdir(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<MkdirReq>,
) -> Result<axum::response::Response, ApiError> {
    require_auth(&s, &headers)?;
    let r = s.trove.resolve_new(&req.path)?;
    if r.abs.exists() {
        if r.abs.is_dir() {
            return Ok((StatusCode::OK, Json(json!({ "path": r.rel, "created": [] }))).into_response());
        }
        return Err(ApiError::target_exists(&r.rel));
    }
    std::fs::create_dir_all(&r.abs).map_err(|e| ApiError::from_io(&e, &req.path))?;
    s.events.change("created", &r.rel, fresh_entry(&r.abs));
    Ok((
        StatusCode::CREATED,
        Json(json!({ "path": r.rel, "created": [r.rel] })),
    )
        .into_response())
}

/// Build a fresh entry JSON for an event payload.
fn fresh_entry(abs: &std::path::Path) -> Option<Value> {
    let meta = std::fs::symlink_metadata(abs).ok()?;
    let name = abs.file_name()?.to_string_lossy().into_owned();
    let mut entry = entry_for(name, &meta);
    if entry.kind == "dir" {
        entry.child_count = Some(child_count(abs));
    }
    serde_json::to_value(entry).ok()
}
