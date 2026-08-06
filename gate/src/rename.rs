//! The temp-file-and-swap save pattern (§03).
//!
//! Most programs save by writing a temporary file beside yours, then swapping
//! the names. trove recognises that swap and treats the temporary file as
//! the new version — so a save in place uploads the swapped-in bytes as the new
//! version of the target. This is the main work on the client and what the
//! write tests cover.

/// True when `name` looks like an editor/app temporary file — the source side
/// of a save swap. Covers the common conventions (GNOME's goutputstream, vim
/// swap files, emacs `#file#`, `~` backups, `.tmp`, and random suffixes).
pub fn looks_like_temp(name: &str) -> bool {
    if name.ends_with('~') {
        return true; // backup/temp
    }
    if name.ends_with(".tmp") || name.ends_with(".TMP") {
        return true;
    }
    if name.starts_with(".goutputstream") {
        return true; // GNOME / GLib atomic save
    }
    if name.starts_with(".#") {
        return true; // emacs lock/temp
    }
    if name.starts_with('#') && name.ends_with('#') {
        return true; // emacs autosave
    }
    if name.starts_with('.') && (name.ends_with(".swp") || name.ends_with(".swx") || name.ends_with(".swpx")) {
        return true; // vim swap
    }
    // A hidden dotfile with a random-looking suffix, e.g. ".name.AB12cd".
    if name.starts_with('.') && has_random_suffix(name) {
        return true;
    }
    false
}

/// A rename is a save swap when the source is a temp file being moved onto a
/// real target in the same folder.
pub fn is_save_swap(from_dir: &str, from_name: &str, to_dir: &str, to_name: &str) -> bool {
    from_dir == to_dir && looks_like_temp(from_name) && !looks_like_temp(to_name)
}

/// Heuristic: a trailing `.` segment of 6+ mixed alphanumeric characters, as
/// mkstemp-style suffixes produce.
fn has_random_suffix(name: &str) -> bool {
    match name.rsplit('.').next() {
        Some(seg) => {
            seg.len() >= 6
                && seg.chars().all(|c| c.is_ascii_alphanumeric())
                && seg.chars().any(|c| c.is_ascii_digit())
                && seg.chars().any(|c| c.is_ascii_alphabetic())
        }
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_common_temp_names() {
        assert!(looks_like_temp("document.txt~"));
        assert!(looks_like_temp("draft.tmp"));
        assert!(looks_like_temp(".goutputstream-A1B2C3"));
        assert!(looks_like_temp(".#report.md"));
        assert!(looks_like_temp("#notes.txt#"));
        assert!(looks_like_temp(".report.md.swp"));
    }

    #[test]
    fn ordinary_names_are_not_temp() {
        assert!(!looks_like_temp("report.md"));
        assert!(!looks_like_temp("cover.jpg"));
        assert!(!looks_like_temp("notes.txt"));
    }

    #[test]
    fn a_swap_is_temp_over_real_in_same_dir() {
        assert!(is_save_swap("music", ".goutputstream-XY99ab", "music", "playlist.m3u"));
        // Different folders is a move, not a save swap.
        assert!(!is_save_swap("a", ".goutputstream-XY99ab", "b", "playlist.m3u"));
        // Real over real is a plain rename.
        assert!(!is_save_swap("a", "old.txt", "a", "new.txt"));
    }
}
