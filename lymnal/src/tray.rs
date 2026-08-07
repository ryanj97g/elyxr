//! The system-tray presence. Whenever lymnal is running — serving a trove on a
//! server, or keeping a client updated in the background — a small lymnal mark
//! sits in the system tray, so the service is visibly *there* even with the
//! elyxr window closed. Its menu opens the app or starts an update.
//!
//! The tray is a StatusNotifierItem over D-Bus, which is Linux-only. On any
//! other platform (and on a Linux box with no StatusNotifier host — a headless
//! server) there simply is no icon, and lymnal runs exactly the same either way.

#[cfg(target_os = "linux")]
pub use linux_tray::spawn;

#[cfg(target_os = "windows")]
pub use windows_tray::spawn;

/// No tray on platforms without a supported host — only Linux (D-Bus) and
/// Windows (Shell_NotifyIcon) have one. lymnal runs the same without it.
#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub fn spawn(
    _status: String,
    _app_bin: Option<std::path::PathBuf>,
    _repo: Option<std::path::PathBuf>,
) -> Option<()> {
    None
}

#[cfg(target_os = "linux")]
mod linux_tray {
    use std::path::PathBuf;
    use std::sync::LazyLock;

    use ksni::blocking::TrayMethods;

    /// The lymnal mark, embedded at build time so the tray never depends on an
    /// icon theme being installed or the repo staying where it was. Two sizes so
    /// the tray can pick a crisp one for its panel.
    static ICONS: LazyLock<Vec<ksni::Icon>> = LazyLock::new(|| {
        // The tray is the one place that wears the silhouette, not the
        // full-colour mark — everything else (taskbar, menu, window, popups)
        // reads the colour icon from the theme. These are dedicated silhouette
        // files so the all-colour theme never overwrites them.
        [
            include_bytes!("../../branding/png/lymnal/lymnal-sil-32.png").as_slice(),
            include_bytes!("../../branding/png/lymnal/lymnal-sil-64.png").as_slice(),
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
        // Pixmap only — no icon_name. The theme's com.elyxr.lymnal is the
        // full-colour mark now (for the popups), so naming it would pull colour
        // into the tray. The embedded silhouette pixmap is what the tray draws.
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
                            // setsid so the app outlives the tray/service; fall
                            // back to a plain launch if setsid isn't present.
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
        // assume_sni_available: lymnal starts at login, often before the
        // desktop's tray host is ready. Without this a not-ready host fails the
        // one attempt and the icon never appears; with it, ksni keeps trying and
        // the icon shows up once the tray is up.
        match tray.assume_sni_available(true).spawn() {
            Ok(handle) => Some(handle),
            Err(e) => {
                tracing::debug!(error = %e, "no system tray to show lymnal in");
                None
            }
        }
    }
}

#[cfg(target_os = "windows")]
mod windows_tray {
    use std::path::PathBuf;

    use tray_icon::menu::{Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem};
    use tray_icon::{Icon, TrayIconBuilder};

    /// Holds the tray thread alive. The thread owns the icon and runs the message
    /// loop for the life of the process; the caller keeps this for symmetry with
    /// the Linux handle.
    pub struct Handle(#[allow(dead_code)] std::thread::JoinHandle<()>);

    pub fn spawn(
        status: String,
        _app_bin: Option<PathBuf>,
        repo: Option<PathBuf>,
    ) -> Option<Handle> {
        // On Windows the app sits next to lymnal (the installer puts elyxr.exe and
        // lymnal.exe in one folder), so find it there rather than trusting the
        // Linux bundle path the caller computed.
        let app_bin = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("elyxr.exe")))
            .filter(|p| p.exists());

        let handle = std::thread::spawn(move || {
            if let Err(e) = run(status, app_bin, repo) {
                tracing::debug!(error = %e, "couldn't show lymnal in the system tray");
            }
        });
        Some(Handle(handle))
    }

    fn run(status: String, app_bin: Option<PathBuf>, _repo: Option<PathBuf>) -> anyhow::Result<()> {
        let menu = Menu::new();
        let status_item = MenuItem::new(&status, false, None);
        menu.append(&status_item)?;
        menu.append(&PredefinedMenuItem::separator())?;
        let open_item = MenuItem::new("Open elyxr", app_bin.is_some(), None);
        menu.append(&open_item)?;
        let update_item = MenuItem::new("Update now", true, None);
        menu.append(&update_item)?;

        let open_id: MenuId = open_item.id().clone();
        let update_id: MenuId = update_item.id().clone();

        // The tray icon must outlive the message loop, so keep it in scope here.
        let _tray = TrayIconBuilder::new()
            .with_tooltip(format!("lymnal — {status}"))
            .with_icon(load_icon()?)
            .with_menu(Box::new(menu))
            .build()?;

        let menu_rx = MenuEvent::receiver();
        pump_messages(|| {
            while let Ok(ev) = menu_rx.try_recv() {
                if ev.id == open_id {
                    if let Some(bin) = &app_bin {
                        let _ = std::process::Command::new(bin).spawn();
                    }
                } else if ev.id == update_id {
                    // Same update the agent runs — a prebuilt fetch on Windows.
                    crate::agent::update_now(std::path::Path::new(""));
                }
            }
        });
        Ok(())
    }

    /// A minimal Win32 message loop. tray-icon posts its click and menu messages
    /// to this thread's queue; after each dispatched message we drain the menu
    /// channel. Blocks for the life of the process, which is what we want — the
    /// service runs until it's stopped.
    fn pump_messages(mut on_tick: impl FnMut()) {
        use windows_sys::Win32::UI::WindowsAndMessaging::{
            DispatchMessageW, GetMessageW, TranslateMessage, MSG,
        };
        let mut msg: MSG = unsafe { std::mem::zeroed() };
        loop {
            // hwnd = null: messages for any window on this thread, plus thread
            // messages. Returns 0 on WM_QUIT, -1 on error — stop on either.
            let r = unsafe { GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) };
            if r <= 0 {
                break;
            }
            unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            on_tick();
        }
    }

    /// The silhouette mark, embedded so the tray never depends on an install path.
    fn load_icon() -> anyhow::Result<Icon> {
        let bytes = include_bytes!("../../branding/png/lymnal/lymnal-sil-32.png");
        let img = image::load_from_memory_with_format(bytes, image::ImageFormat::Png)?;
        let (w, h) = (img.width(), img.height());
        Ok(Icon::from_rgba(img.into_rgba8().into_vec(), w, h)?)
    }
}
