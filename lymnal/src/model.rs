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
    // Audio tags, filled by the listing for audio files (see tags.rs). Omitted
    // from the JSON when absent, so non-audio entries stay lean.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    // Track length in whole seconds, and the release year. What the song and
    // album views sort by; neither is a tag the grouping itself needs.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_s: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub year: Option<u32>,
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
            title: None,
            artist: None,
            album: None,
            duration_s: None,
            year: None,
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
            // Filled in by the listing for audio files; see handlers/browse.rs.
            title: None,
            artist: None,
            album: None,
            duration_s: None,
            year: None,
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

/// What a listing reads off an audio file: the three tags the song, album, and
/// artist views group by, plus the two figures they offer to sort on.
#[derive(Debug, Clone, Default)]
pub struct AudioTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub duration_s: Option<u64>,
    pub year: Option<u32>,
}

/// Tags read straight from an audio file. No cache, on purpose: a listing
/// re-reads, and the few milliseconds to re-parse a header is the cost of never
/// keeping a private store of the user's files. lymbo is the one rolling place
/// transient data is allowed to live; this is not that. Any failure —
/// unreadable, no tags, a container lofty can't parse — is a quiet default, so a
/// listing never fails over one bad file.
pub fn audio_tags(path: &Path) -> AudioTags {
    use lofty::prelude::*;
    let Ok(file) = lofty::read_from_path(path) else {
        return AudioTags::default();
    };
    // Length comes off the decoded properties, not a tag, so it survives a file
    // that carries no tag block at all — which is exactly the file whose name is
    // all the song view would otherwise have to show.
    let secs = file.properties().duration().as_secs();
    let duration_s = (secs > 0).then_some(secs);
    // A file can carry more than one tag block; prefer the one that matches the
    // container, else take whatever it has.
    let Some(tag) = file.primary_tag().or_else(|| file.first_tag()) else {
        return AudioTags {
            duration_s,
            ..AudioTags::default()
        };
    };
    let clean = |o: Option<std::borrow::Cow<str>>| {
        o.map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
    };
    AudioTags {
        title: clean(tag.title()),
        artist: clean(tag.artist()),
        album: clean(tag.album()),
        duration_s,
        year: tag.year(),
    }
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
