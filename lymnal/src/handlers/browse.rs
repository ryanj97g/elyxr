//! Browsing: list, stat, search (§03, §04).

use std::time::{Duration, Instant};

use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::error::{ApiError, ErrCode};
use crate::model::{child_count, entry_for, is_hidden, mime_for, mtime_secs, Entry};
use crate::state::Shared;

use super::{decode_cursor, encode_cursor, require_auth};

#[derive(Deserialize)]
pub(super) struct ListQuery {
    path: Option<String>,
    sort: Option<String>,
    order: Option<String>,
    limit: Option<u32>,
    cursor: Option<String>,
}

/// `GET /v1/list` — one folder, sorted by lymnal, paged with an opaque cursor.
pub(super) async fn list(
    State(s): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<ListQuery>,
) -> Result<Json<Value>, ApiError> {
    require_auth(&s, &headers)?;
    let raw = q.path.unwrap_or_default();
    let resolved = s.trove.resolve(&raw)?;
    let meta = std::fs::metadata(&resolved.abs).map_err(|e| ApiError::from_io(&e, &raw))?;
    if !meta.is_dir() {
        return Err(ApiError::bad_path(&raw));
    }

    // Read the whole folder, then sort — sorting is lymnal's job so it costs
    // the app the same for ten entries or twenty thousand.
    let mut entries: Vec<Entry> = Vec::new();
    let rd = std::fs::read_dir(&resolved.abs).map_err(|e| ApiError::from_io(&e, &raw))?;
    for de in rd.flatten() {
        let name = de.file_name().to_string_lossy().into_owned();
        if is_hidden(&name) {
            continue;
        }
        let m = match de.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        let mut e = entry_for(name, &m);
        if e.kind == "dir" {
            e.child_count = Some(child_count(&de.path()));
        } else if e.mime.is_some_and(|mt| mt.starts_with("audio/")) {
            // Read title/artist/album straight from the file so the app can sort
            // by them and the player can label the track. Read fresh each listing
            // — no side cache (see model::audio_tags).
            let (title, artist, album) = crate::model::audio_tags(&de.path());
            e.title = title;
            e.artist = artist;
            e.album = album;
        }
        entries.push(e);
    }

    sort_entries(&mut entries, q.sort.as_deref(), q.order.as_deref());

    let total = entries.len();
    let (default_limit, max_limit) = s.list_limits();
    let limit = q
        .limit
        .unwrap_or(default_limit)
        .min(max_limit)
        .max(1) as usize;
    let offset = decode_cursor(&q.cursor).min(total);
    let page: Vec<&Entry> = entries.iter().skip(offset).take(limit).collect();
    let next = offset + page.len();
    let next_cursor = if next < total {
        Some(encode_cursor(next))
    } else {
        None
    };

    Ok(Json(json!({
        "path": resolved.rel,
        "entries": page,
        "next_cursor": next_cursor,
        "used_bytes": s.usage.used(),
        "warnings": s.usage.warnings(),
    })))
}

/// Folders sort before files at equal keys, always; within each group the
/// requested key and order apply, with name as a stable tiebreak.
fn sort_entries(entries: &mut [Entry], sort: Option<&str>, order: Option<&str>) {
    let key = sort.unwrap_or("name");
    let desc = matches!(order, Some("desc"));
    entries.sort_by(|a, b| {
        // Directories first.
        let dir_first = (a.kind != "dir").cmp(&(b.kind != "dir"));
        if dir_first != std::cmp::Ordering::Equal {
            return dir_first;
        }
        let primary = match key {
            "size" => a.size_bytes.cmp(&b.size_bytes),
            "mtime" => a.mtime.cmp(&b.mtime),
            // Tagged files sort alphabetically; untagged (and non-audio) fall to
            // the end, then the name tiebreak below keeps them in a stable order.
            "artist" => tag_key(&a.artist).cmp(&tag_key(&b.artist)),
            "album" => tag_key(&a.album).cmp(&tag_key(&b.album)),
            _ => name_cmp(&a.name, &b.name),
        };
        let primary = if desc { primary.reverse() } else { primary };
        // Deterministic tiebreak keeps paging free of repeats and gaps.
        primary.then_with(|| name_cmp(&a.name, &b.name))
    });
}

/// Sort key for an audio tag: `is_none` first so tagged files come before
/// untagged ones, then a case-folded copy so the order is alphabetical.
fn tag_key(t: &Option<String>) -> (bool, String) {
    (t.is_none(), t.as_deref().unwrap_or("").to_lowercase())
}

fn name_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    a.to_lowercase().cmp(&b.to_lowercase()).then(a.cmp(b))
}

#[derive(Deserialize)]
pub(super) struct StatQuery {
    path: String,
}

/// `GET /v1/stat` — one entry's metadata plus a caching etag. The etag is a
/// cheap, stable tag over size+mtime (not a content hash), so stat never reads
/// a multi-gigabyte file; download compares against the same tag.
pub(super) async fn stat(
    State(s): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<StatQuery>,
) -> Result<Json<Value>, ApiError> {
    require_auth(&s, &headers)?;
    let resolved = s.trove.resolve(&q.path)?;
    let meta = std::fs::metadata(&resolved.abs).map_err(|e| ApiError::from_io(&e, &q.path))?;
    let name = resolved
        .abs
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| s.trove_name());
    let kind = if meta.is_dir() { "dir" } else { "file" };
    Ok(Json(json!({
        "path": resolved.rel,
        "name": name,
        "kind": kind,
        "size_bytes": if meta.is_dir() { 0 } else { meta.len() },
        "mtime": mtime_secs(&meta),
        "mime": if meta.is_dir() { None } else { mime_for(&name) },
        "etag": etag(&meta),
    })))
}

/// A stable weak etag: BLAKE3 of "size:mtime". Enough for If-None-Match / 304.
pub(crate) fn etag(meta: &std::fs::Metadata) -> String {
    let seed = format!("{}:{}", meta.len(), mtime_secs(meta));
    format!("b3:{}", blake3::hash(seed.as_bytes()).to_hex())
}

#[derive(Deserialize)]
pub(super) struct SearchQuery {
    q: String,
    path: Option<String>,
    limit: Option<u32>,
}

/// `GET /v1/search` — recursive filename substring match below `path`. The
/// walk stops at the limit (truncated, reason "limit") or 3 s (reason
/// "deadline"), and never presents a partial list as complete.
pub(super) async fn search(
    State(s): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<SearchQuery>,
) -> Result<Json<Value>, ApiError> {
    require_auth(&s, &headers)?;
    let needle = q.q.trim().to_lowercase();
    if needle.len() < 2 {
        return Err(ApiError::new(
            ErrCode::BadPath,
            "Type at least two characters to search.",
        ));
    }
    let base_raw = q.path.unwrap_or_default();
    let base = s.trove.resolve(&base_raw)?;
    let limit = q.limit.unwrap_or(200).min(1000) as usize;
    let deadline = Instant::now() + Duration::from_secs(3);

    let mut results: Vec<Value> = Vec::new();
    let mut reason: Option<&'static str> = None;
    let mut stack = vec![base.abs.clone()];

    'walk: while let Some(dir) = stack.pop() {
        if Instant::now() >= deadline {
            reason = Some("deadline");
            break;
        }
        let rd = match std::fs::read_dir(&dir) {
            Ok(rd) => rd,
            Err(_) => continue,
        };
        for de in rd.flatten() {
            let name = de.file_name().to_string_lossy().into_owned();
            if is_hidden(&name) {
                continue;
            }
            let meta = match de.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            if meta.is_dir() && !meta.is_symlink() {
                stack.push(de.path());
            }
            if name.to_lowercase().contains(&needle) {
                let rel = rel_of(&s, &de.path());
                results.push(json!({
                    "path": rel,
                    "kind": if meta.is_dir() { "dir" } else { "file" },
                    "size_bytes": if meta.is_dir() { 0 } else { meta.len() },
                    "mtime": mtime_secs(&meta),
                }));
                if results.len() >= limit {
                    reason = Some("limit");
                    break 'walk;
                }
            }
        }
    }

    Ok(Json(json!({
        "results": results,
        "truncated": reason.is_some(),
        "reason": reason,
    })))
}

/// Trove-relative path (with `/` separators) of an absolute path inside it.
fn rel_of(s: &Shared, abs: &std::path::Path) -> String {
    abs.strip_prefix(s.trove.root())
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default()
}
