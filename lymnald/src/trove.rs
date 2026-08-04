//! Path resolution + escape guard — the security boundary (§02, §11).
//!
//! Every path in a request is trove-relative, uses `/` separators with no
//! leading slash, and `""` is the root. A path is normalised, rejected if it
//! carries `..` or a null byte, joined to the root, then resolved and
//! re-checked to confirm it is still inside. Symlinks leading out are refused.
//!
//! The refusal list in §11 is not optional — every entry there is covered by
//! a test at the bottom of this file.

use std::path::{Component, Path, PathBuf};

use unicode_normalization::UnicodeNormalization;

use crate::error::ApiError;

/// The trove: one folder, resolved to a canonical absolute path once at
/// startup so every later check is canonical-against-canonical.
#[derive(Debug, Clone)]
pub struct Trove {
    root: PathBuf,
    follow_symlinks: bool,
}

/// Longest trove-relative path we entertain, in bytes, before even looking at
/// components. Guards the "5000 character" case cheaply.
const MAX_PATH_BYTES: usize = 4096;
/// Longest single path component, in bytes. The filesystem limit is 255;
/// the "300 character name" case is refused here.
const MAX_COMPONENT_BYTES: usize = 255;

impl Trove {
    /// Open (creating if missing) the trove folder and canonicalise it.
    /// A path that is a file, or is not writable, is the caller's to report —
    /// this only fails when the folder truly cannot be reached.
    pub fn open(root: impl AsRef<Path>, follow_symlinks: bool) -> std::io::Result<Trove> {
        let root = root.as_ref();
        if !root.exists() {
            std::fs::create_dir_all(root)?;
        }
        let root = root.canonicalize()?;
        Ok(Trove {
            root,
            follow_symlinks,
        })
    }

    /// For tests and callers that have already validated the root.
    pub fn with_root(root: PathBuf, follow_symlinks: bool) -> Trove {
        Trove {
            root,
            follow_symlinks,
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Validate and normalise a trove-relative path WITHOUT touching the
    /// filesystem. Returns the cleaned relative path (components joined by
    /// `/`, `""` for the root). This is the pure-string half of the guard:
    /// it rejects `..`, null bytes, backslashes, unicode dot-leaders, absolute
    /// and home paths, and over-long paths/components.
    pub fn normalise(&self, raw: &str) -> Result<String, ApiError> {
        if raw.len() > MAX_PATH_BYTES {
            return Err(ApiError::bad_path(&truncate(raw)));
        }
        if raw.contains('\0') {
            return Err(ApiError::bad_path("<path with a null byte>"));
        }
        // Backslashes are never a separator here and are a common escape trick.
        if raw.contains('\\') {
            return Err(ApiError::bad_path(raw));
        }
        // `..` in the raw string, OR in an NFKC-folded copy — the latter
        // catches unicode look-alikes (U+2025 TWO DOT LEADER folds to "..").
        if raw.contains("..") {
            return Err(ApiError::path_escapes(raw));
        }
        let folded: String = raw.nfkc().collect();
        if folded.contains("..") {
            return Err(ApiError::path_escapes(raw));
        }
        // No leading slash (absolute) and no home expansion.
        if raw.starts_with('/') {
            return Err(ApiError::bad_path(raw));
        }
        if raw.starts_with('~') {
            return Err(ApiError::bad_path(raw));
        }

        let mut parts: Vec<&str> = Vec::new();
        for seg in raw.split('/') {
            if seg.is_empty() || seg == "." {
                // Collapse "//", trailing "/", and "." — so "a/b/" and "a/b"
                // are the same path, and "" is the root.
                continue;
            }
            if seg == ".." {
                // Belt-and-suspenders; the substring check above already caught it.
                return Err(ApiError::path_escapes(raw));
            }
            if seg.len() > MAX_COMPONENT_BYTES {
                return Err(ApiError::bad_path(raw));
            }
            parts.push(seg);
        }
        Ok(parts.join("/"))
    }

    /// Resolve a trove-relative path to an absolute path inside the trove,
    /// confirming — after following any symlinks — that it is still inside.
    /// Use for paths that must already exist (read, stat, delete, move source).
    pub fn resolve(&self, raw: &str) -> Result<Resolved, ApiError> {
        let rel = self.normalise(raw)?;
        let joined = self.join(&rel);
        let canonical = self.canonical_within(&joined, raw)?;
        Ok(Resolved { rel, abs: canonical })
    }

    /// Resolve a path whose leaf may not exist yet (upload target, mkdir,
    /// move destination). The parent chain is checked for escape; the leaf is
    /// taken literally. Symlinks in the existing prefix that lead out are
    /// refused exactly as in [`resolve`].
    pub fn resolve_new(&self, raw: &str) -> Result<Resolved, ApiError> {
        let rel = self.normalise(raw)?;
        let joined = self.join(&rel);
        // Canonicalise the longest existing ancestor and confirm it is inside;
        // the non-existent tail cannot contain a symlink.
        let existing = longest_existing(&joined);
        let canonical_existing = existing
            .canonicalize()
            .map_err(|e| ApiError::from_io(&e, raw))?;
        if !self.contains(&canonical_existing) {
            return Err(ApiError::path_escapes(raw));
        }
        // Rebuild the absolute target from the canonical existing prefix plus
        // the still-virtual tail. When the whole path already exists the tail
        // is empty — join("") would append a trailing separator and make a
        // file path read as ENOTDIR, so use the canonical path as-is.
        let tail = joined.strip_prefix(&existing).unwrap_or(&joined);
        let abs = if tail.as_os_str().is_empty() {
            canonical_existing
        } else {
            canonical_existing.join(tail)
        };
        Ok(Resolved { rel, abs })
    }

    fn join(&self, rel: &str) -> PathBuf {
        if rel.is_empty() {
            self.root.clone()
        } else {
            self.root.join(rel)
        }
    }

    fn canonical_within(&self, path: &Path, raw: &str) -> Result<PathBuf, ApiError> {
        let canonical = if self.follow_symlinks {
            path.canonicalize().map_err(|e| ApiError::from_io(&e, raw))?
        } else {
            // Reject if any component is a symlink leading out. canonicalize
            // follows every link; comparing the result to the root catches an
            // out-of-trove target whether the link is the leaf or mid-path.
            let c = path.canonicalize().map_err(|e| ApiError::from_io(&e, raw))?;
            // With follow_symlinks off we still allow links that stay inside,
            // but a link whose real target sits outside the trove is refused.
            c
        };
        if !self.contains(&canonical) {
            return Err(ApiError::path_escapes(raw));
        }
        Ok(canonical)
    }

    fn contains(&self, canonical: &Path) -> bool {
        canonical == self.root || canonical.starts_with(&self.root)
    }
}

/// A resolved path: the cleaned trove-relative string (for responses) and the
/// absolute on-disk path (for filesystem calls).
#[derive(Debug, Clone)]
pub struct Resolved {
    pub rel: String,
    pub abs: PathBuf,
}

fn truncate(s: &str) -> String {
    s.chars().take(64).collect::<String>() + "…"
}

/// The longest existing ancestor of `path` (including `path` itself). Falls
/// back to the filesystem root, which always exists.
fn longest_existing(path: &Path) -> PathBuf {
    let mut cur = path.to_path_buf();
    loop {
        if cur.exists() {
            return cur;
        }
        match cur.parent() {
            Some(p) => cur = p.to_path_buf(),
            None => return cur,
        }
    }
}

/// True when `p`, interpreted literally, has no `.`/`..`/root/prefix
/// components that could escape. Used only in tests as a sanity aid.
#[allow(dead_code)]
fn is_plain_relative(p: &Path) -> bool {
    p.components()
        .all(|c| matches!(c, Component::Normal(_)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn trove() -> (tempfile::TempDir, Trove) {
        let dir = tempfile::tempdir().unwrap();
        let t = Trove::open(dir.path(), false).unwrap();
        (dir, t)
    }

    // ---- §11 refusal list: every entry must be refused ----

    #[test]
    fn refuses_the_dot_dot_family() {
        let (_d, t) = trove();
        for p in [
            "../etc/passwd",
            "a/../../etc/passwd",
            "/etc/passwd",
            "a/./../../etc/passwd",
            "..%2fetc%2fpasswd",
            "a//../../etc",
            "....//etc",
            "a\\..\\..\\etc",
            "~/.ssh/id_rsa",
            "a/b/../../../",
        ] {
            assert!(t.normalise(p).is_err(), "should refuse {p:?}");
        }
    }

    #[test]
    fn refuses_null_byte() {
        let (_d, t) = trove();
        assert!(t.normalise("notes\u{0000}.txt").is_err());
    }

    #[test]
    fn refuses_unicode_dot_leader_lookalike() {
        let (_d, t) = trove();
        // U+2025 TWO DOT LEADER ×2 — NFKC folds to "....".
        assert!(t.normalise("\u{2025}\u{2025}/etc").is_err());
    }

    #[test]
    fn refuses_overlong_path() {
        let (_d, t) = trove();
        let p = "a/".repeat(2500) + "b"; // ~5000 chars
        assert!(t.normalise(&p).is_err());
    }

    #[test]
    fn refuses_overlong_component() {
        let (_d, t) = trove();
        let name = "x".repeat(300);
        assert!(t.normalise(&name).is_err());
    }

    #[test]
    fn refuses_symlink_pointing_at_etc() {
        let (dir, t) = trove();
        let link = dir.path().join("escape");
        std::os::unix::fs::symlink("/etc", &link).unwrap();
        assert!(t.resolve("escape").is_err());
        assert!(t.resolve("escape/passwd").is_err());
    }

    #[test]
    fn refuses_symlink_pointing_at_parent() {
        let (dir, t) = trove();
        let parent = dir.path().parent().unwrap();
        let link = dir.path().join("up");
        std::os::unix::fs::symlink(parent, &link).unwrap();
        assert!(t.resolve("up").is_err());
    }

    // ---- required asserts ----

    #[test]
    fn empty_is_the_root() {
        let (_d, t) = trove();
        let r = t.resolve("").unwrap();
        assert_eq!(r.rel, "");
        assert_eq!(r.abs, *t.root());
    }

    #[test]
    fn trailing_slash_is_the_same_path() {
        let (dir, t) = trove();
        std::fs::create_dir_all(dir.path().join("a/b")).unwrap();
        let with = t.resolve("a/b/").unwrap();
        let without = t.resolve("a/b").unwrap();
        assert_eq!(with.rel, without.rel);
        assert_eq!(with.abs, without.abs);
        assert_eq!(with.rel, "a/b");
    }

    #[test]
    fn case_is_preserved_and_significant() {
        let (_d, t) = trove();
        let a = t.normalise("Photos/Roll.CR3").unwrap();
        assert_eq!(a, "Photos/Roll.CR3");
        assert_ne!(t.normalise("photos").unwrap(), t.normalise("Photos").unwrap());
    }

    #[test]
    fn collapses_redundant_separators() {
        let (_d, t) = trove();
        assert_eq!(t.normalise("a//b/./c").unwrap(), "a/b/c");
    }

    #[test]
    fn resolve_new_allows_missing_leaf() {
        let (_d, t) = trove();
        let r = t.resolve_new("photos/2026/roll.cr3").unwrap();
        assert!(r.abs.ends_with("photos/2026/roll.cr3"));
        assert_eq!(r.rel, "photos/2026/roll.cr3");
    }
}
