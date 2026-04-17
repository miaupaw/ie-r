pub mod dbus_menu;
pub mod dbus_tray;
pub mod event_sender;
pub mod rofi_menu;
pub mod scout;
pub mod timer;

/// Events from the outside world (tray, hotkeys, signals) to the main event loop.
/// Defined here rather than main.rs because all daemon modules and connectors use them.
pub enum UserEvent {
    LaunchOverlay(Option<(i32, i32)>),
    EditConfig,
    ToggleHUD,
    CopyFromHistory(String),
    SelectTemplate(String),
    ShowAbout,
    OpenHomepage,
    Quit,
}

/// Opens the homepage in the default browser.
pub fn open_homepage() {
    let _ = open::that("https://instant-eyedropper.com/linux/?ie-r");
}
