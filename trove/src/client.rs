//! A small blocking lymnal client for the folder layer. FUSE callbacks are
//! synchronous, so this uses ureq rather than the app's async client. Errors
//! carry lymnal's `code` so errno.rs can turn them into a numbered failure.

use serde_json::Value;

/// A lymnal failure, reduced to what the folder layer needs: the code (for the
/// errno mapping) and the message (for the notification that goes to Elyxr).
#[derive(Debug, Clone)]
pub struct LymError {
    pub code: String,
    pub message: String,
}

impl LymError {
    fn io(msg: impl Into<String>) -> LymError {
        LymError {
            code: "IO_ERROR".into(),
            message: msg.into(),
        }
    }
}

pub type LymResult<T> = Result<T, LymError>;

pub struct Lymnal {
    base: String,
    token: String,
    chunk_bytes: u64,
}

impl Lymnal {
    pub fn new(base_url: impl Into<String>, token: impl Into<String>) -> Lymnal {
        Lymnal {
            base: base_url.into(),
            token: token.into(),
            chunk_bytes: 8 * 1024 * 1024,
        }
    }

    fn auth(&self) -> String {
        format!("Bearer {}", self.token)
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base, path)
    }

    /// List a folder; returns the raw entries array.
    pub fn list(&self, path: &str) -> LymResult<Vec<Value>> {
        let resp = ureq::get(&self.url("/v1/list"))
            .set("Authorization", &self.auth())
            .query("path", path)
            .query("limit", "2000")
            .call();
        let v = self.json(resp)?;
        Ok(v.get("entries")
            .and_then(|e| e.as_array())
            .cloned()
            .unwrap_or_default())
    }

    pub fn stat(&self, path: &str) -> LymResult<Value> {
        let resp = ureq::get(&self.url("/v1/stat"))
            .set("Authorization", &self.auth())
            .query("path", path)
            .call();
        self.json(resp)
    }

    /// Download a whole file into memory (the cache writes it to disk).
    pub fn download(&self, path: &str) -> LymResult<Vec<u8>> {
        let resp = ureq::get(&self.url("/v1/download"))
            .set("Authorization", &self.auth())
            .query("path", path)
            .call();
        match resp {
            Ok(r) => {
                let mut buf = Vec::new();
                std::io::Read::read_to_end(&mut r.into_reader(), &mut buf)
                    .map_err(|e| LymError::io(e.to_string()))?;
                Ok(buf)
            }
            Err(e) => Err(self.err(e)),
        }
    }

    /// Upload a file's bytes as the new version at `path`: init, chunks, commit.
    pub fn upload(&self, path: &str, bytes: &[u8], mtime: i64) -> LymResult<Value> {
        let init = self.json(
            ureq::post(&self.url("/v1/upload/init"))
                .set("Authorization", &self.auth())
                .send_json(serde_json::json!({
                    "path": path,
                    "size_bytes": bytes.len(),
                    "mtime": mtime,
                })),
        )?;
        let id = init
            .get("upload_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| LymError::io("upload/init gave no id"))?
            .to_string();
        let chunk = init
            .get("chunk_bytes")
            .and_then(|v| v.as_u64())
            .unwrap_or(self.chunk_bytes) as usize;

        let total = bytes.len();
        let mut offset = 0usize;
        while offset < total {
            let end = (offset + chunk).min(total);
            let range = format!("bytes {offset}-{}/{total}", end - 1);
            let resp = ureq::put(&self.url(&format!("/v1/upload/{id}")))
                .set("Authorization", &self.auth())
                .set("Content-Range", &range)
                .send_bytes(&bytes[offset..end]);
            self.json(resp)?;
            offset = end;
        }
        // Empty files still commit (init/commit with no chunks).
        self.json(
            ureq::post(&self.url(&format!("/v1/upload/{id}/commit")))
                .set("Authorization", &self.auth())
                .send_json(serde_json::json!({})),
        )
    }

    pub fn move_(&self, from: &str, to: &str, on_conflict: &str) -> LymResult<Value> {
        self.json(
            ureq::post(&self.url("/v1/move"))
                .set("Authorization", &self.auth())
                .send_json(serde_json::json!({ "from": from, "to": to, "on_conflict": on_conflict })),
        )
    }

    pub fn delete(&self, paths: &[String]) -> LymResult<Value> {
        self.json(
            ureq::post(&self.url("/v1/delete"))
                .set("Authorization", &self.auth())
                .send_json(serde_json::json!({ "paths": paths })),
        )
    }

    pub fn mkdir(&self, path: &str) -> LymResult<Value> {
        self.json(
            ureq::post(&self.url("/v1/mkdir"))
                .set("Authorization", &self.auth())
                .send_json(serde_json::json!({ "path": path })),
        )
    }

    fn json(&self, resp: Result<ureq::Response, ureq::Error>) -> LymResult<Value> {
        match resp {
            Ok(r) => r.into_json::<Value>().map_err(|e| LymError::io(e.to_string())),
            Err(e) => Err(self.err(e)),
        }
    }

    /// Reduce a ureq error to a coded LymError, reading lymnal's body when it
    /// answered with a status.
    fn err(&self, e: ureq::Error) -> LymError {
        match e {
            ureq::Error::Status(_code, resp) => {
                match resp.into_json::<Value>() {
                    Ok(v) => LymError {
                        code: v
                            .get("code")
                            .and_then(|c| c.as_str())
                            .unwrap_or("IO_ERROR")
                            .to_string(),
                        message: v
                            .get("message")
                            .and_then(|c| c.as_str())
                            .unwrap_or("Something went wrong.")
                            .to_string(),
                    },
                    Err(_) => LymError::io("unreadable error from the server"),
                }
            }
            // Transport error — the request never really landed.
            ureq::Error::Transport(t) => LymError::io(format!("can't reach the server: {t}")),
        }
    }
}
