//! The system-tray presence. Whenever lymnal is running — serving a trove on a
//! server, or keeping a client updated in the background — a small lymnal mark
//! sits in the system tray, so the service is visibly *there* even with the
//! elyxr window closed. Its menu opens the app or starts an update. On a
//! machine with no tray (a headless server, or a desktop with no
//! StatusNotifier host) registering simply fails and lymnal carries on serving.

use std::path::PathBuf;
use std::sync::LazyLock;

use ksni::blocking::TrayMethods;

/// The lymnal mark, embedded at build time so the tray never depends on an icon
/// theme being installed or the repo staying where it was. Two sizes so the tray
/// can pick a crisp one for its panel.
static ICONS: LazyLock<Vec<ksni::Icon>> = LazyLock::new(|| {
    [
        include_bytes!("../../branding/png/lymnal/lymnal-48.png").as_slice(),
        include_bytes!("../../branding/png/lymnal/lymnal-256.png").as_slice(),
    ]
    .into_iter()
    .filter_map(decode)
    .collect()
});

/// Decode a PNG into the ARGB32 pixmap the StatusNotifierItem spec wants.
fn decode(bytes: &[u8]) -> Option<ksni::Icon> {
    let img = image::load_from_memory_with_format(bytes, image::ImageFormat::Png).ok()?;
    let (width, height) = (img.width() as i32, img.height() as i32);
    let mut data = img.into_rgba8().into_vec();
    for px in data.chunks_exact_mut(4) {
        px.rotate_right(1); // RGBA -> ARGB
    }
    Some(ksni::Icon { width, height, data })
}

pub struct LymnalTray {
    /// One line of state shown in the tooltip and as the menu's header, e.g.
    /// "serving trove" or "connected to RyanG5Mini".
    pub status: String,
    /// The installed elyxr app, so "Open elyxr" can launch it. `None` on a
    /// headless install (--no-app), which just omits that menu item.
    pub app_bin: Option<PathBuf>,
    /// The elyxr repo, so "Update now" can re-run the installer. `None` if we
    /// couldn't find it, which omits that item.
    pub repo: Option<PathBuf>,
}

impl ksni::Tray for LymnalTray {
    fn id(&self) -> String {
        "com.elyxr.lymnal".into()
    }
    fn title(&self) -> String {
        "lymnal".into()
    }
    // Name first, pixmap second. GNOME's tray extension resolves the icon from
    // the theme by name (the installer puts the lymnal mark there); hosts that
    // don't, or a theme that hasn't picked it up yet, fall back to the embedded
    // pixmap. Between the two the mark shows on every desktop.
    fn icon_name(&self) -> String {
        "com.elyxr.lymnal".into()
    }
    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        ICONS.clone()
    }
    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: "lymnal".into(),
            description: self.status.clone(),
            icon_name: String::new(),
            icon_pixmap: Vec::new(),
        }
    }
    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::*;
        let app_bin = self.app_bin.clone();
        let repo = self.repo.clone();
        let mut items: Vec<ksni::MenuItem<Self>> = vec![
            StandardItem {
                label: self.status.clone(),
                enabled: false,
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
        ];
        if let Some(bin) = app_bin {
            items.push(
                StandardItem {
                    label: "Open elyxr".into(),
                    activate: Box::new(move |_| {
                        // setsid so the app outlives the tray/service; fall back
                        // to a plain launch if setsid isn't present.
                        let _ = std::process::Command::new("setsid")
                            .arg(&bin)
                            .spawn()
                            .or_else(|_| std::process::Command::new(&bin).spawn());
                    }),
                    ..Default::default()
                }
                .into(),
            );
        }
        if let Some(dir) = repo {
            items.push(
                StandardItem {
                    label: "Update now".into(),
                    activate: Box::new(move |_| {
                        let script = dir.join("elyxr.sh");
                        // Own systemd scope so restarting lymnal mid-update
                        // doesn't kill the update along with the tray.
                        let _ = std::process::Command::new("systemd-run")
                            .args(["--user", "--scope", "--quiet", "bash"])
                            .arg(&script)
                            .current_dir(&dir)
                            .spawn()
                            .or_else(|_| {
                                std::process::Command::new("bash")
                                    .arg(&script)
                                    .current_dir(&dir)
                                    .spawn()
                            });
                    }),
                    ..Default::default()
                }
                .into(),
            );
        }
        items
    }
}

/// Put a lymnal icon in the system tray. Returns a handle (so the caller can
/// update the status later) or `None` when there is no tray — headless, or a
/// desktop with no StatusNotifier host. A missing tray is never an error: the
/// service runs the same either way.
pub fn spawn(
    status: String,
    app_bin: Option<PathBuf>,
    repo: Option<PathBuf>,
) -> Option<ksni::blocking::Handle<LymnalTray>> {
    let tray = LymnalTray {
        status,
        app_bin,
        repo,
    };
    match tray.spawn() {
        Ok(handle) => Some(handle),
        Err(e) => {
            tracing::debug!(error = %e, "no system tray to show lymnal in");
            None
        }
    }
}
