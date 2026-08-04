//! codes → numbered filesystem failures (§09, the third column).
//!
//! Other programs asking the operating system about the folder only understand
//! a short list of numbered failures and cannot be given a sentence. lymnal's
//! coded errors are mapped here; the human sentence goes to Elyxr as a
//! notification instead. Your text editor says "no space left on device";
//! Elyxr says it was the 150 GB limit.

/// Linux errno for a lymnal error `code`. Unknown codes fall back to EIO.
pub fn code_to_errno(code: &str) -> i32 {
    match code {
        "BAD_TOKEN" | "TOKEN_REVOKED" | "PERMISSION_DENIED" => libc::EACCES,
        "PATH_ESCAPES_TROVE" => libc::EPERM,
        "BAD_PATH" => libc::EINVAL,
        "NOT_FOUND" => libc::ENOENT,
        "TARGET_EXISTS" => libc::EEXIST,
        "NOT_EMPTY" => libc::ENOTEMPTY,
        "TROVE_FULL" | "DRIVE_FULL" => libc::ENOSPC,
        "INCOMPLETE_UPLOAD" | "CHECKSUM_MISMATCH" | "UPLOAD_EXPIRED" | "IO_ERROR" => libc::EIO,
        _ => libc::EIO,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_the_table() {
        assert_eq!(code_to_errno("NOT_FOUND"), libc::ENOENT);
        assert_eq!(code_to_errno("TROVE_FULL"), libc::ENOSPC);
        assert_eq!(code_to_errno("DRIVE_FULL"), libc::ENOSPC);
        assert_eq!(code_to_errno("PATH_ESCAPES_TROVE"), libc::EPERM);
        assert_eq!(code_to_errno("BAD_PATH"), libc::EINVAL);
        assert_eq!(code_to_errno("TARGET_EXISTS"), libc::EEXIST);
        assert_eq!(code_to_errno("NOT_EMPTY"), libc::ENOTEMPTY);
        assert_eq!(code_to_errno("BAD_TOKEN"), libc::EACCES);
        assert_eq!(code_to_errno("CHECKSUM_MISMATCH"), libc::EIO);
        // Unknown → EIO.
        assert_eq!(code_to_errno("SOMETHING_NEW"), libc::EIO);
    }
}
