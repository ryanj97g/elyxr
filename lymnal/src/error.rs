//! One enum, one shape, one status mapping (§09).
//!
//! Every failure leaves lymnal as the same JSON body — never a bare status
//! with an empty body:
//!
//! ```json
//! { "code": "TROVE_FULL", "message": "...", "detail": {...},
//!   "hint": "...", "request_id": "01J8Z3K7QW" }
//! ```
//!
//! `code` is what clients branch on. `message` is written for a person and
//! shown word for word. `hint` names the fix in the interface, not the config
//! file. `request_id` matches the server log line.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

/// The closed set of error codes. The HTTP status and the errno an
/// elyxr-trove client would hand to other programs both live here, so the
/// three columns of the §09 table can never drift apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrCode {
    BadToken,
    TokenRevoked,
    PathEscapesTrove,
    BadPath,
    NotFound,
    TargetExists,
    NotEmpty,
    IncompleteUpload,
    ChecksumMismatch,
    UploadExpired,
    TroveFull,
    DriveFull,
    PermissionDenied,
    IoError,
    PairingClosed,
    PairingDenied,
    PairingTimeout,
}

impl ErrCode {
    pub fn as_str(self) -> &'static str {
        use ErrCode::*;
        match self {
            BadToken => "BAD_TOKEN",
            TokenRevoked => "TOKEN_REVOKED",
            PathEscapesTrove => "PATH_ESCAPES_TROVE",
            BadPath => "BAD_PATH",
            NotFound => "NOT_FOUND",
            TargetExists => "TARGET_EXISTS",
            NotEmpty => "NOT_EMPTY",
            IncompleteUpload => "INCOMPLETE_UPLOAD",
            ChecksumMismatch => "CHECKSUM_MISMATCH",
            UploadExpired => "UPLOAD_EXPIRED",
            TroveFull => "TROVE_FULL",
            DriveFull => "DRIVE_FULL",
            PermissionDenied => "PERMISSION_DENIED",
            IoError => "IO_ERROR",
            PairingClosed => "PAIRING_CLOSED",
            PairingDenied => "PAIRING_DENIED",
            PairingTimeout => "PAIRING_TIMEOUT",
        }
    }

    pub fn http(self) -> StatusCode {
        use ErrCode::*;
        match self {
            BadToken | TokenRevoked => StatusCode::UNAUTHORIZED,
            PathEscapesTrove | PermissionDenied | PairingClosed | PairingDenied => {
                StatusCode::FORBIDDEN
            }
            BadPath => StatusCode::BAD_REQUEST,
            NotFound => StatusCode::NOT_FOUND,
            TargetExists | NotEmpty | IncompleteUpload => StatusCode::CONFLICT,
            ChecksumMismatch => StatusCode::UNPROCESSABLE_ENTITY,
            UploadExpired => StatusCode::GONE,
            TroveFull | DriveFull => StatusCode::INSUFFICIENT_STORAGE,
            IoError => StatusCode::INTERNAL_SERVER_ERROR,
            PairingTimeout => StatusCode::REQUEST_TIMEOUT,
        }
    }

    /// The numbered filesystem failure elyxr-trove hands to other programs,
    /// which cannot be given a sentence. `None` for the pairing codes, which
    /// never reach the folder layer.
    pub fn errno(self) -> Option<i32> {
        use ErrCode::*;
        // Linux errno values.
        Some(match self {
            BadToken | TokenRevoked | PermissionDenied => 13, // EACCES
            PathEscapesTrove => 1,                            // EPERM
            BadPath => 22,                                    // EINVAL
            NotFound => 2,                                    // ENOENT
            TargetExists => 17,                               // EEXIST
            NotEmpty => 39,                                   // ENOTEMPTY
            IncompleteUpload | ChecksumMismatch | UploadExpired | IoError => 5, // EIO
            TroveFull | DriveFull => 28,                      // ENOSPC
            PairingClosed | PairingDenied | PairingTimeout => return None,
        })
    }
}

/// A failure carrying everything the §09 body needs. Construct with the
/// helpers below so the human `message` is never forgotten.
#[derive(Debug, Clone)]
pub struct ApiError {
    pub code: ErrCode,
    pub message: String,
    pub detail: Option<serde_json::Value>,
    pub hint: Option<String>,
    pub request_id: String,
}

impl ApiError {
    pub fn new(code: ErrCode, message: impl Into<String>) -> Self {
        ApiError {
            code,
            message: message.into(),
            detail: None,
            hint: None,
            request_id: ulid::Ulid::new().to_string(),
        }
    }

    pub fn with_detail(mut self, detail: serde_json::Value) -> Self {
        self.detail = Some(detail);
        self
    }

    pub fn with_hint(mut self, hint: impl Into<String>) -> Self {
        self.hint = Some(hint.into());
        self
    }

    /// Attach a caller-known request id so the body matches the log line.
    pub fn with_request_id(mut self, id: impl Into<String>) -> Self {
        self.request_id = id.into();
        self
    }

    // --- constructors for the common cases, each with plain wording ---

    pub fn bad_path(path: &str) -> Self {
        ApiError::new(
            ErrCode::BadPath,
            format!("\"{path}\" is not a path Elyxr can use."),
        )
    }

    pub fn path_escapes(path: &str) -> Self {
        ApiError::new(
            ErrCode::PathEscapesTrove,
            format!("\"{path}\" points outside your Elyxr folder, so it can't be reached."),
        )
    }

    pub fn not_found(path: &str) -> Self {
        ApiError::new(
            ErrCode::NotFound,
            format!("There's nothing at \"{path}\" in your Elyxr folder."),
        )
    }

    pub fn target_exists(path: &str) -> Self {
        ApiError::new(
            ErrCode::TargetExists,
            format!("\"{path}\" already exists."),
        )
    }

    pub fn not_empty(path: &str) -> Self {
        ApiError::new(
            ErrCode::NotEmpty,
            format!("\"{path}\" still has things in it."),
        )
    }

    pub fn io(message: impl Into<String>) -> Self {
        ApiError::new(ErrCode::IoError, message)
    }

    /// Map a std::io::Error against a known path to the closest coded error.
    pub fn from_io(err: &std::io::Error, path: &str) -> Self {
        use std::io::ErrorKind::*;
        match err.kind() {
            NotFound => ApiError::not_found(path),
            PermissionDenied => ApiError::new(
                ErrCode::PermissionDenied,
                format!("Elyxr isn't allowed to touch \"{path}\"."),
            ),
            AlreadyExists => ApiError::target_exists(path),
            _ => ApiError::io(format!("Something went wrong reaching \"{path}\": {err}")),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut body = json!({
            "code": self.code.as_str(),
            "message": self.message,
            "request_id": self.request_id,
        });
        let obj = body.as_object_mut().unwrap();
        if let Some(detail) = self.detail {
            obj.insert("detail".into(), detail);
        }
        if let Some(hint) = self.hint {
            obj.insert("hint".into(), json!(hint));
        }
        (self.code.http(), Json(body)).into_response()
    }
}

pub type ApiResult<T> = Result<T, ApiError>;
