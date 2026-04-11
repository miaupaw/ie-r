/// Rofi/wofi/fuzzel fallback menu for wlroots-based compositors.
///
/// On KDE/GNOME the tray host renders dbusmenu popups natively.
/// On wlroots (Hyprland, Sway, niri, river…) GTK3 can't spawn a popup
/// from a layer-shell surface, so we launch an external menu instead.

use super::UserEvent;
use super::event_sender::EventSender;
use crate::core::terminal::log_error;

/// Desktop environments known to render dbusmenu popups natively.
/// Everything else gets the external menu fallback.
const NATIVE_POPUP_DESKTOPS: &[&str] = &[
    "KDE", "GNOME", "X-Cinnamon", "LXQt", "Deepin", "MATE", "Pantheon",
];

/// Returns `true` if the current DE can render a dbusmenu popup without help.
pub fn has_native_popup() -> bool {
    let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
    desktop.split(':').any(|d| NATIVE_POPUP_DESKTOPS.contains(&d))
}

/// Show the context menu via an external launcher (rofi → wofi → fuzzel).
pub async fn show_menu(proxy: EventSender) {
    use crate::core::config::TEMPLATE_LABELS;
    use crate::daemon::dbus_menu::MenuSnapshot;
    use tokio::io::AsyncWriteExt;

    let snap = MenuSnapshot::take();

    enum Action {
        History(String),
        Template(String),
        ToggleHUD,
        EditConfig,
        About,
        Homepage,
        Quit,
    }

    // Prepare temp dir for color swatch PNGs (rofi icon support)
    let color_icon_dir = std::path::PathBuf::from("/tmp/ie-r-colors");
    let _ = std::fs::create_dir_all(&color_icon_dir);

    let mut lines: Vec<String> = Vec::new();
    let mut actions: Vec<Action> = Vec::new();

    for hex in &snap.history {
        let filename = format!("{}.png", hex.trim_start_matches('#'));
        let icon_path = color_icon_dir.join(&filename);
        if !icon_path.exists() {
            let png = crate::daemon::dbus_menu::generate_color_png(hex);
            let _ = std::fs::write(&icon_path, &png);
        }
        lines.push(format!("{}\0icon\x1f{}", hex, icon_path.display()));
        actions.push(Action::History(hex.clone()));
    }

    for &(key, label) in TEMPLATE_LABELS {
        let dot = if snap.selected_template == key { "●" } else { "○" };
        lines.push(format!("{} {}", dot, label));
        actions.push(Action::Template(key.to_string()));
    }

    let hud_dot = if snap.show_hud { "✓" } else { "○" };
    lines.push(format!("{} Show HUD", hud_dot));
    actions.push(Action::ToggleHUD);

    lines.push("⚙ Edit Config".to_string());
    actions.push(Action::EditConfig);

    lines.push("🌐 Homepage".to_string());
    actions.push(Action::Homepage);

    lines.push("ℹ About".to_string());
    actions.push(Action::About);

    lines.push("✕ Quit".to_string());
    actions.push(Action::Quit);

    let input = lines.join("\n");

    // Fallback chain: rofi → wofi → fuzzel
    let launchers: &[(&str, &[&str])] = &[
        ("rofi",   &["-dmenu", "-p", "IE-R", "-format", "i", "-no-custom", "-show-icons"]),
        ("wofi",   &["--dmenu", "--prompt", "IE-R"]),
        ("fuzzel", &["--dmenu", "--prompt", "IE-R "]),
    ];

    let mut child = None;
    for (cmd, args) in launchers {
        match tokio::process::Command::new(cmd)
            .args(*args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
        {
            Ok(c) => { child = Some(c); break; }
            Err(_) => continue,
        }
    }

    let mut child = match child {
        Some(c) => c,
        None => {
            log_error("No menu launcher found. Install rofi, wofi, or fuzzel.");
            return;
        }
    };

    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input.as_bytes()).await;
    }

    let out = match child.wait_with_output().await {
        Ok(o) => o,
        Err(e) => { log_error(&format!("menu launcher failed: {}", e)); return; }
    };

    let idx_str = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if idx_str.is_empty() { return; }

    let idx: usize = match idx_str.parse() {
        Ok(i) => i,
        Err(_) => return,
    };

    if let Some(action) = actions.into_iter().nth(idx) {
        match action {
            Action::History(hex)  => { let _ = proxy.send(UserEvent::CopyFromHistory(hex)); }
            Action::Template(key) => { let _ = proxy.send(UserEvent::SelectTemplate(key)); }
            Action::ToggleHUD     => { let _ = proxy.send(UserEvent::ToggleHUD); }
            Action::EditConfig    => { let _ = proxy.send(UserEvent::EditConfig); }
            Action::About         => { let _ = proxy.send(UserEvent::ShowAbout); }
            Action::Homepage      => { let _ = proxy.send(UserEvent::OpenHomepage); }
            Action::Quit          => { let _ = proxy.send(UserEvent::Quit); }
        }
    }
}
