//! Shared response types and the metadata helpers behind list, stat, and the
//! event stream. `kind` is "file" or "dir"; sizes are bytes; times are Unix
//! seconds; a directory's `size_bytes` is 0 and carries a `child_count`.

use std::path::Path;

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct Entry {
    pub name: String,
    pub kind: &'static str, // "file" | "dir"
    pub size_bytes: u64,
    pub mtime: i64,
    pub mime: Option<&'static str>,
    pub child_count: Option<u64>,
}

/// Build an entry for a directory child. Hidden entries (leading ".") are the
/// caller's to skip; this does not filter.
pub fn entry_for(name: String, meta: &std::fs::Metadata) -> Entry {
    let mtime = mtime_secs(meta);
    if meta.is_dir() {
        let child_count = None; // filled by the caller when it lists the dir
        Entry {
            mime: None,
            kind: "dir",
            size_bytes: 0,
            mtime,
            child_count,
            name,
        }
    } else {
        let mime = mime_for(&name);
        Entry {
            name,
            kind: "file",
            size_bytes: meta.len(),
            mtime,
            mime,
            child_count: None,
        }
    }
}

/// Count the immediate, non-hidden children of a directory. Used to fill a
/// folder entry's `child_count` without walking the whole tree.
pub fn child_count(dir: &Path) -> u64 {
    match std::fs::read_dir(dir) {
        Ok(rd) => rd
            .flatten()
            .filter(|e| !is_hidden(&e.file_name().to_string_lossy()))
            .count() as u64,
        Err(_) => 0,
    }
}

pub fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

pub fn mtime_secs(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// A small, deterministic extension → MIME map. Covers what preview needs
/// (images, PDF, video) plus the common document and audio types in the trove.
pub fn mime_for(name: &str) -> Option<&'static str> {
    let ext = name.rsplit('.').next()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "tif" | "tiff" => "image/tiff",
        "bmp" => "image/bmp",
        "svg" => "image/svg+xml",
        "cr3" | "cr2" | "raw" | "arw" | "nef" | "dng" => "image/x-raw",
        "pdf" => "application/pdf",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        "avi" => "video/x-msvideo",
        "mp3" => "audio/mpeg",
        "flac" => "audio/flac",
        "wav" => "audio/wav",
        "m4a" => "audio/mp4",
        "m3u" | "m3u8" => "audio/x-mpegurl",
        "txt" | "md" => "text/plain",
        "html" | "htm" => "text/html",
        "json" => "application/json",
        "zip" => "application/zip",
        "csv" => "text/csv",
        _ => return None,
    })
}
