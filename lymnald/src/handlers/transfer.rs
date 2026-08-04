//! Transfers: resolve, download, zip, and the upload lifecycle (§04, §05).

use axum::body::Body;
use axum::extract::{Path as AxPath, Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

use crate::error::{ApiError, ErrCode};
use crate::model::mime_for;
use crate::state::Shared;

use super::browse::etag;
use super::require_auth;

// ---------------------------------------------------------------- resolve ---

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ResolveReq {
    paths: Vec<String>,
}

struct FlatFile {
    rel: String,
    name: String,
    size: u64,
    mtime: i64,
}

/// `POST /v1/resolve` — flatten a selection to files, apply same-name dedup
/// (newest kept), and return the real file count, total, collisions, and the
/// download mode. Both figures are the server's, not a guess.
pub(super) async fn resolve(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<ResolveReq>,
) -> Result<Json<Value>, ApiError> {
    require_auth(&s, &headers)?;

    let mut flat: Vec<FlatFile> = Vec::new();
    for raw in &req.paths {
        let r = s.trove.resolve(raw)?;
        let meta = std::fs::symlink_metadata(&r.abs).map_err(|e| ApiError::from_io(&e, raw))?;
        if meta.is_dir() {
            walk_files(&s, &r.abs, &mut flat);
        } else if meta.is_file() {
            flat.push(FlatFile {
                name: file_name(&r.rel),
                size: meta.len(),
                mtime: crate::model::mtime_secs(&meta),
                rel: r.rel,
            });
        }
    }

    // Dedup by basename: newest mtime kept, others reported as skipped.
    use std::collections::HashMap;
    let mut by_name: HashMap<String, Vec<usize>> = HashMap::new();
    for (i, f) in flat.iter().enumerate() {
        by_name.entry(f.name.clone()).or_default().push(i);
    }
    let mut keep = vec![true; flat.len()];
    let mut collisions: Vec<Value> = Vec::new();
    for (name, idxs) in &by_name {
        if idxs.len() < 2 {
            continue;
        }
        let mut sorted = idxs.clone();
        sorted.sort_by_key(|&i| std::cmp::Reverse(flat[i].mtime));
        let kept = sorted[0];
        let mut skipped = Vec::new();
        for &i in &sorted[1..] {
            keep[i] = false;
            skipped.push(flat[i].rel.clone());
        }
        collisions.push(json!({
            "name": name,
            "kept": flat[kept].rel,
            "skipped": skipped,
        }));
    }

    let mut files: Vec<Value> = Vec::new();
    let mut total: u64 = 0;
    for (i, f) in flat.iter().enumerate() {
        if !keep[i] {
            continue;
        }
        total += f.size;
        files.push(json!({
            "path": f.rel, "name": f.name,
            "size_bytes": f.size, "mtime": f.mtime,
        }));
    }
    let file_count = files.len() as u64;
    let mode = if file_count <= s.max_loose_files() {
        "loose"
    } else {
        "zip"
    };

    Ok(Json(json!({
        "files": files,
        "file_count": file_count,
        "total_bytes": total,
        "collisions": collisions,
        "mode": mode,
    })))
}

fn walk_files(s: &Shared, root: &std::path::Path, out: &mut Vec<FlatFile>) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let rd = match std::fs::read_dir(&dir) {
            Ok(rd) => rd,
            Err(_) => continue,
        };
        for de in rd.flatten() {
            let name = de.file_name().to_string_lossy().into_owned();
            if crate::model::is_hidden(&name) {
                continue;
            }
            let meta = match de.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            if meta.is_dir() && !meta.is_symlink() {
                stack.push(de.path());
            } else if meta.is_file() {
                let rel = de
                    .path()
                    .strip_prefix(s.trove.root())
                    .map(|p| p.to_string_lossy().replace('\\', "/"))
                    .unwrap_or_default();
                out.push(FlatFile {
                    name,
                    size: meta.len(),
                    mtime: crate::model::mtime_secs(&meta),
                    rel,
                });
            }
        }
    }
}

fn file_name(rel: &str) -> String {
    rel.rsplit('/').next().unwrap_or(rel).to_string()
}

// --------------------------------------------------------------- download ---

#[derive(Deserialize)]
pub(super) struct DownloadQuery {
    path: String,
}

/// `GET /v1/download` — streamed from disk, Range and If-None-Match honoured,
/// whole files never held in memory.
pub(super) async fn download(
    State(s): State<Shared>,
    headers: HeaderMap,
    Query(q): Query<DownloadQuery>,
) -> Result<Response, ApiError> {
    require_auth(&s, &headers)?;
    let r = s.trove.resolve(&q.path)?;
    let meta = std::fs::metadata(&r.abs).map_err(|e| ApiError::from_io(&e, &q.path))?;
    if meta.is_dir() {
        return Err(ApiError::bad_path(&r.rel));
    }
    let tag = etag(&meta);
    let name = file_name(&r.rel);
    let mime = mime_for(&name).unwrap_or("application/octet-stream");
    let size = meta.len();

    // If-None-Match → 304 when unchanged.
    if let Some(inm) = header_str(&headers, header::IF_NONE_MATCH) {
        if inm.split(',').any(|t| t.trim().trim_matches('"') == tag) {
            return Ok((StatusCode::NOT_MODIFIED, base_headers(&tag, mime)).into_response());
        }
    }

    // Range, unless If-Range names a stale tag (then serve the full 200).
    let honour_range = match header_str(&headers, header::IF_RANGE) {
        Some(ir) => ir.trim().trim_matches('"') == tag,
        None => true,
    };
    let range = if honour_range {
        header_str(&headers, header::RANGE).and_then(|h| parse_range(&h, size))
    } else {
        None
    };

    let mut file = tokio::fs::File::open(&r.abs)
        .await
        .map_err(|e| ApiError::from_io(&e, &q.path))?;

    let disposition = format!(
        "attachment; filename*=UTF-8''{}",
        percent_encode(&name)
    );

    if let Some((start, end)) = range {
        let len = end - start + 1;
        file.seek(std::io::SeekFrom::Start(start))
            .await
            .map_err(|e| ApiError::io(e.to_string()))?;
        let stream = ReaderStream::new(file.take(len));
        let body = Body::from_stream(stream);
        let mut resp = Response::builder()
            .status(StatusCode::PARTIAL_CONTENT)
            .header(header::ACCEPT_RANGES, "bytes")
            .header(header::CONTENT_TYPE, mime)
            .header(header::ETAG, format!("\"{tag}\""))
            .header(header::CONTENT_LENGTH, len)
            .header(
                header::CONTENT_RANGE,
                format!("bytes {start}-{end}/{size}"),
            )
            .header(header::CONTENT_DISPOSITION, disposition)
            .body(body)
            .unwrap();
        resp.headers_mut(); // (no-op; keeps builder chain readable)
        Ok(resp)
    } else {
        let stream = ReaderStream::new(file);
        let body = Body::from_stream(stream);
        Ok(Response::builder()
            .status(StatusCode::OK)
            .header(header::ACCEPT_RANGES, "bytes")
            .header(header::CONTENT_TYPE, mime)
            .header(header::ETAG, format!("\"{tag}\""))
            .header(header::CONTENT_LENGTH, size)
            .header(header::CONTENT_DISPOSITION, disposition)
            .body(body)
            .unwrap())
    }
}

fn base_headers(tag: &str, mime: &str) -> HeaderMap {
    let mut h = HeaderMap::new();
    h.insert(header::ACCEPT_RANGES, "bytes".parse().unwrap());
    h.insert(header::ETAG, format!("\"{tag}\"").parse().unwrap());
    if let Ok(v) = mime.parse() {
        h.insert(header::CONTENT_TYPE, v);
    }
    h
}

fn header_str(headers: &HeaderMap, name: header::HeaderName) -> Option<String> {
    headers.get(name)?.to_str().ok().map(|s| s.to_string())
}

/// Parse a single-range `Range: bytes=start-end` header into inclusive
/// [start, end] within a file of `size`. Supports open-ended and suffix forms.
fn parse_range(h: &str, size: u64) -> Option<(u64, u64)> {
    if size == 0 {
        return None;
    }
    let spec = h.trim().strip_prefix("bytes=")?;
    let (a, b) = spec.split_once('-')?;
    let (start, end) = if a.is_empty() {
        // suffix: last N bytes
        let n: u64 = b.trim().parse().ok()?;
        let n = n.min(size);
        (size - n, size - 1)
    } else {
        let start: u64 = a.trim().parse().ok()?;
        let end = if b.trim().is_empty() {
            size - 1
        } else {
            b.trim().parse::<u64>().ok()?.min(size - 1)
        };
        (start, end)
    };
    if start > end || start >= size {
        return None;
    }
    Some((start, end))
}

/// Minimal RFC 3986 percent-encoding for a filename in Content-Disposition.
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

// -------------------------------------------------------------------- zip ---

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ZipReq {
    paths: Vec<String>,
    #[serde(default)]
    name: Option<String>,
}

/// `POST /v1/zip` — a streamed, store-method zip, never staged to disk. Entry
/// names keep the structure below the common parent of the selection.
pub(super) async fn zip(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<ZipReq>,
) -> Result<Response, ApiError> {
    require_auth(&s, &headers)?;

    // Collect the files and their entry names up front, so any path error is
    // reported as JSON before the zip stream starts.
    let mut flat: Vec<FlatFile> = Vec::new();
    for raw in &req.paths {
        let r = s.trove.resolve(raw)?;
        let meta = std::fs::symlink_metadata(&r.abs).map_err(|e| ApiError::from_io(&e, raw))?;
        if meta.is_dir() {
            walk_files(&s, &r.abs, &mut flat);
        } else if meta.is_file() {
            flat.push(FlatFile {
                name: file_name(&r.rel),
                size: meta.len(),
                mtime: crate::model::mtime_secs(&meta),
                rel: r.rel,
            });
        }
    }
    let parent = common_parent(&req.paths);
    let entries: Vec<(std::path::PathBuf, String)> = flat
        .iter()
        .map(|f| {
            let entry_name = strip_prefix_dir(&f.rel, &parent);
            (s.trove.root().join(&f.rel), entry_name)
        })
        .collect();

    let zip_name = req.name.unwrap_or_else(|| "download.zip".into());

    // Stream the zip through an in-memory pipe: a task writes entries into the
    // write half; the response body is the read half. Never staged to disk.
    let (reader, writer) = tokio::io::duplex(1 << 16);
    tokio::spawn(async move {
        if let Err(e) = write_zip(writer, entries).await {
            tracing::warn!(error = %e, "zip stream ended early");
        }
    });

    let body = Body::from_stream(ReaderStream::new(reader));
    Ok(Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/zip")
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename*=UTF-8''{}", percent_encode(&zip_name)),
        )
        .body(body)
        .unwrap())
}

async fn write_zip(
    writer: tokio::io::DuplexStream,
    entries: Vec<(std::path::PathBuf, String)>,
) -> anyhow::Result<()> {
    use async_zip::tokio::write::ZipFileWriter;
    use async_zip::{Compression, ZipEntryBuilder};

    use tokio_util::compat::TokioAsyncReadCompatExt;
    let mut zw = ZipFileWriter::with_tokio(writer);
    for (abs, name) in entries {
        let builder = ZipEntryBuilder::new(name.into(), Compression::Stored);
        let mut ew = zw.write_entry_stream(builder).await?;
        // async_zip's entry writer is a futures AsyncWrite; bridge the tokio
        // file into futures-land and copy without buffering the whole file.
        let mut f = tokio::fs::File::open(&abs).await?.compat();
        futures::io::copy(&mut f, &mut ew).await?;
        ew.close().await?;
    }
    zw.close().await?;
    Ok(())
}

/// The longest common ancestor directory of the selection's parent dirs. For a
/// single selected folder this is its parent, so the folder's own name appears
/// in the zip; for several selections it is the deepest dir containing all.
fn common_parent(paths: &[String]) -> Vec<String> {
    let parents: Vec<Vec<String>> = paths
        .iter()
        .map(|p| {
            let mut comps: Vec<String> = p
                .trim_matches('/')
                .split('/')
                .filter(|c| !c.is_empty())
                .map(|c| c.to_string())
                .collect();
            comps.pop(); // drop the leaf → the parent dir
            comps
        })
        .collect();
    let Some(first) = parents.first() else {
        return Vec::new();
    };
    let mut common = first.clone();
    for p in &parents[1..] {
        let n = common
            .iter()
            .zip(p.iter())
            .take_while(|(a, b)| a == b)
            .count();
        common.truncate(n);
    }
    common
}

fn strip_prefix_dir(rel: &str, parent: &[String]) -> String {
    let comps: Vec<&str> = rel.split('/').filter(|c| !c.is_empty()).collect();
    let skip = parent.len().min(comps.len());
    comps[skip..].join("/")
}

// ----------------------------------------------------------------- upload ---

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct UploadInitReq {
    path: String,
    size_bytes: u64,
    #[serde(default)]
    checksum: Option<String>,
    #[serde(default)]
    mtime: Option<i64>,
}

/// `POST /v1/upload/init` — declare the whole file so limits are checked before
/// any bytes move. Refuses here with TROVE_FULL / DRIVE_FULL / PATH_ESCAPES /
/// BAD_PATH; on success stages nothing but an empty holding file.
pub(super) async fn upload_init(
    State(s): State<Shared>,
    headers: HeaderMap,
    Json(req): Json<UploadInitReq>,
) -> Result<Response, ApiError> {
    let id = require_auth(&s, &headers)?;
    let target = s.trove.resolve_new(&req.path)?;
    s.usage
        .check_can_accept(req.size_bytes, s.effective_max(&id))?;
    let mtime = req.mtime.unwrap_or_else(now_secs);
    let (upload_id, received, target_exists, expires_at) = s.uploads.init(
        target.rel,
        target.abs,
        req.size_bytes,
        req.checksum,
        mtime,
    )?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "upload_id": upload_id,
            "chunk_bytes": s.uploads.chunk_bytes(),
            "received_bytes": received,
            "target_exists": target_exists,
            "expires_at": expires_at,
        })),
    )
        .into_response())
}

/// `PUT /v1/upload/:id` — one chunk at the offset in Content-Range.
pub(super) async fn upload_chunk(
    State(s): State<Shared>,
    headers: HeaderMap,
    AxPath(id): AxPath<String>,
    body: axum::body::Bytes,
) -> Result<Json<Value>, ApiError> {
    require_auth(&s, &headers)?;
    let offset = parse_content_range(&headers)?;
    let (received, complete) = s.uploads.chunk(&id, offset, &body)?;
    Ok(Json(json!({ "received_bytes": received, "complete": complete })))
}

/// `GET /v1/upload/:id` — progress, for resume after a restart.
pub(super) async fn upload_status(
    State(s): State<Shared>,
    headers: HeaderMap,
    AxPath(id): AxPath<String>,
) -> Result<Json<Value>, ApiError> {
    require_auth(&s, &headers)?;
    let (received, size, missing, expires_at) = s.uploads.status(&id)?;
    let missing: Vec<[u64; 2]> = missing.into_iter().map(|(a, b)| [a, b]).collect();
    Ok(Json(json!({
        "upload_id": id,
        "received_bytes": received,
        "size_bytes": size,
        "missing": missing,
        "expires_at": expires_at,
    })))
}

/// `POST /v1/upload/:id/commit` — verify the checksum, install, adjust usage.
pub(super) async fn upload_commit(
    State(s): State<Shared>,
    headers: HeaderMap,
    AxPath(id): AxPath<String>,
) -> Result<Json<Value>, ApiError> {
    require_auth(&s, &headers)?;
    let (committed, delta) = s.uploads.commit(&id)?;
    let used = if delta != 0 {
        s.usage.adjust(delta)
    } else {
        s.usage.used()
    };
    let warnings = s.usage.warnings();
    // Announce the change to watchers.
    let kind = if committed.replaced { "modified" } else { "created" };
    let entry = fresh_entry(&s, &committed.path);
    s.events.change(kind, &committed.path, entry);
    if !warnings.is_empty() {
        s.events.usage(used, &warnings);
    }
    Ok(Json(json!({
        "path": committed.path,
        "size_bytes": committed.size_bytes,
        "replaced": committed.replaced,
        "identical": committed.identical,
        "used_bytes": used,
        "warnings": warnings,
    })))
}

/// `DELETE /v1/upload/:id` — abandon and delete the staging file.
pub(super) async fn upload_delete(
    State(s): State<Shared>,
    headers: HeaderMap,
    AxPath(id): AxPath<String>,
) -> Result<StatusCode, ApiError> {
    require_auth(&s, &headers)?;
    s.uploads.discard(&id);
    Ok(StatusCode::NO_CONTENT)
}

/// Parse the byte offset out of `Content-Range: bytes start-end/total`.
fn parse_content_range(headers: &HeaderMap) -> Result<u64, ApiError> {
    let raw = header_str(headers, header::CONTENT_RANGE).ok_or_else(|| {
        ApiError::new(
            ErrCode::BadPath,
            "This chunk is missing its Content-Range header.",
        )
    })?;
    let spec = raw.trim().strip_prefix("bytes ").ok_or_else(bad_range)?;
    let (range, _total) = spec.split_once('/').ok_or_else(bad_range)?;
    let (start, _end) = range.split_once('-').ok_or_else(bad_range)?;
    start.trim().parse::<u64>().map_err(|_| bad_range())
}

fn bad_range() -> ApiError {
    ApiError::new(ErrCode::BadPath, "This chunk's Content-Range header is malformed.")
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn fresh_entry(s: &Shared, rel: &str) -> Option<Value> {
    let abs = s.trove.root().join(rel);
    let meta = std::fs::symlink_metadata(&abs).ok()?;
    let name = file_name(rel);
    let mut entry = crate::model::entry_for(name, &meta);
    if entry.kind == "dir" {
        entry.child_count = Some(crate::model::child_count(&abs));
    }
    serde_json::to_value(entry).ok()
}
