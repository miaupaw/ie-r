use anyhow::Result;
use calloop::{
    EventLoop,
    timer::{TimeoutAction, Timer},
};
use calloop_wayland_source::WaylandSource;
use core::capture::{self, OutputMeta};
use core::color_service::ColorService;
use core::config::Config;
use core::terminal::{log_info, log_error, log_step, print_logo, log_warn};
use daemon::dbus_tray::DBusTray;
use daemon::scout::Scout;
use global_hotkey::GlobalHotKeyEvent;
use std::time::Duration;
use wayland_client::{Connection, globals::registry_queue_init};

pub mod connectors;
pub mod core;
pub mod daemon;

use connectors::wayland::IEWaylandState;
use core::overlay::OverlayApp;
pub use daemon::UserEvent;

/// Wayland daemon branch. Thin wrapper around ColorService that adds
/// only platform-specific orchestration: creating the Layer Shell overlay
/// and integrating with Calloop.
struct DaemonApp {
    svc: ColorService,
    _tray: DBusTray,
    _scout: Scout,
}

impl DaemonApp {
    fn new(tray: DBusTray) -> Result<Self> {
        let svc = ColorService::new();
        let scout = Scout::new(&svc.config.system.hotkey)?;

        Ok(Self {
            svc,
            _tray: tray,
            _scout: scout,
        })
    }

    /// Activates eyedropper mode. Entry point for hotkeys and tray icon clicks.
    /// Synchronously hot-reloads config, fires KWin/Portal for raw-pixel capture,
    /// and raises the Wayland overlay.
    pub fn launch_overlay(
        &mut self,
        state: &mut IEWaylandState,
        qh: &wayland_client::QueueHandle<IEWaylandState>,
    ) {
        if state.overlay_app.is_some() {
            log_info("Overlay already active. Simulating LMB click.");
            state.simulate_click(qh);
            return;
        }

        log_info("Launching overlay...");
        let mut perf = self.svc.reload_config();

        // Pre-collect output metadata (output_state is !Send, must happen on this thread)
        let output_meta: Vec<_> = state.output_state.outputs().map(|o| {
            let info = state.output_state.info(&o);
            let name = info.as_ref()
                .and_then(|i| i.name.clone())
                .unwrap_or_default();
            let logical_pos = info.as_ref()
                .and_then(|i| i.logical_position)
                .or_else(|| info.as_ref().map(|i| i.location))
                .unwrap_or((0, 0));
            let logical_w = info.as_ref()
                .and_then(|i| i.logical_size)
                .map(|s| s.0)
                .unwrap_or(0);
            let transform = info.as_ref()
                .map(|i| i.transform)
                .unwrap_or(wayland_client::protocol::wl_output::Transform::Normal);
            OutputMeta { output: o, name, logical_pos, logical_w, transform }
        }).collect();

        let screencopy = match (&state.screencopy_manager, &state.shm) {
            (Some(manager), Some(shm)) => Some((&state.conn, manager, shm.wl_shm())),
            _ => None,
        };

        let canvas_res = capture::capture_all_outputs(
            &output_meta,
            screencopy,
            self.svc.dbus_conn.as_ref(),
        );

        if let Ok(canvas) = canvas_res {
            perf.log("Screen captured");

            let overlay = OverlayApp::new(
                canvas,
                self.svc.config.clone(),
                self.svc.cached_font_data.clone(),
                "COMPOSITOR: WAYLAND".to_string(),
                state.scale_factor,
            );

            state.launch_overlay(qh, overlay);
            log_step("Ready", "Overlay state initialized & Layer requested");
        } else {
            log_error("Failed to capture screen.");
        }
    }
}

/// Global context threaded through all Calloop callbacks.
/// Combines the Wayland dispatcher, daemon logic, and event queue
/// for lifecycle management (shutdown, channel handling).
struct AppState {
    daemon: DaemonApp,
    wayland: IEWaylandState,
    qh: wayland_client::QueueHandle<IEWaylandState>,
    exit_requested: bool,
    /// Deferred About launch — gives menus time to close before screenshot
    about_requested_at: Option<std::time::Instant>,
}

// ─── Wayland Main Loop ──────────────────────────────────────────────────────

fn run_wayland_daemon() -> Result<()> {
    print_logo();
    log_info("Wayland backend active");
    log_info("...");
    log_info("To trigger IE-R, bind system shortcuts to UNIX signals:");
    log_info("SIGUSR1 (Pick Color): killall -SIGUSR1 ie-r");
    log_info("SIGUSR2 (Open Menu):  killall -SIGUSR2 ie-r");
    log_info("... or pkill -SIGUSR1 ie-r");
    log_info("Hyprland example (add to hyprland.conf):");
    log_info("bind = SUPER SHIFT, P, exec, pkill -SIGUSR1 ie-r");

    // Grab the Wayland socket and initialise the object registry.
    // This is the foundation without which the Layer Shell cannot be built.
    let conn = Connection::connect_to_env().expect("Failed to connect to Wayland");
    let (globals, event_queue) = registry_queue_init(&conn).expect("Failed to get registry");
    let qh = event_queue.handle();
    let wayland_state = IEWaylandState::new(conn.clone(), &globals, &qh);

    // --- Signal Matrix (POSIX Kill Block) ---
    // Critical: we must intercept signals BEFORE Tokio spawns threads.
    // Without this, background workers inherit the old kill-mask
    // and the OS will simply terminate the process on -USR1.
    let signals = calloop::signals::Signals::new(&[
        calloop::signals::Signal::SIGUSR1,
        calloop::signals::Signal::SIGUSR2,
    ])?;

    // Tokio is needed solely to keep async DBus and zbus running under the hood.
    // We do not run our own code asynchronously, but let the crates breathe.
    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    // Calloop — Epoll at full power. We wait for OS events without burning CPU.
    let mut event_loop = EventLoop::<AppState>::try_new()?;
    let loop_handle = event_loop.handle();

    // Inject the Wayland queue into Epoll. Now any mouse movement
    // or click will wake our thread.
    let wayland_source = WaylandSource::new(conn.clone(), event_queue);
    loop_handle
        .insert_source(wayland_source, |_, queue, state: &mut AppState| {
            queue.dispatch_pending(&mut state.wayland)
        })
        .map_err(|e| anyhow::anyhow!("Wayland source error: {}", e))?;

    // Bridge between the SNI system tray (DBus) and our main loop.
    // The tray runs in its own thread and sends events (click/exit) here via a channel.
    let (tx, rx) = calloop::channel::channel();
    let sender = daemon::event_sender::EventSender::from_calloop(tx);
    let sender_for_signals = sender.clone();
    let tray = DBusTray::new(sender)?;
    let daemon = DaemonApp::new(tray)?;

    loop_handle
        .insert_source(rx, |event, _, state: &mut AppState| match event {
            calloop::channel::Event::Msg(UserEvent::LaunchOverlay(_coords)) => {
                // Wayland path doesn't currently need the specific coordinates since Wayland compositor manages pointers
                state.daemon.launch_overlay(&mut state.wayland, &state.qh);
            }
            calloop::channel::Event::Msg(UserEvent::EditConfig) => {
                let config_path = Config::get_config_path();
                log_info(&format!("Opening config in editor: {:?}", config_path));
                let _ = open::that(config_path);
            }
            calloop::channel::Event::Msg(UserEvent::CopyFromHistory(hex)) => {
                let s = hex.trim_start_matches('#');
                if let Ok(val) = u32::from_str_radix(s, 16) {
                    let r = ((val >> 16) & 0xFF) as u8;
                    let g = ((val >> 8) & 0xFF) as u8;
                    let b = (val & 0xFF) as u8;
                    state.daemon.svc.copy_color(&[image::Rgba([r, g, b, 255])]);
                }
            }
            calloop::channel::Event::Msg(UserEvent::SelectTemplate(key)) => {
                log_step("Menu", &format!("Template selected: {}", key));
                state.daemon.svc.config.templates.selected = key.clone();
                state.daemon.svc.config.save();
                daemon::dbus_menu::DBusMenu::notify_template_changed(&key);
            }
            calloop::channel::Event::Msg(UserEvent::ShowAbout) => {
                if state.wayland.overlay_app.is_none() && state.wayland.about_surface.is_none()
                    && state.about_requested_at.is_none()
                {
                    state.about_requested_at = Some(std::time::Instant::now());
                }
            }
            calloop::channel::Event::Msg(UserEvent::OpenHomepage) => {
                daemon::open_homepage();
            }
            calloop::channel::Event::Msg(UserEvent::Quit) => {
                state.exit_requested = true;
            }
            calloop::channel::Event::Msg(UserEvent::ToggleHUD) => {
                state.daemon.svc.config.hud.show = !state.daemon.svc.config.hud.show;
                state.daemon.svc.config.save();
                crate::daemon::dbus_menu::DBusMenu::notify_hud_changed(
                    state.daemon.svc.config.hud.show,
                );
            }
            _ => {}
        })
        .map_err(|e| anyhow::anyhow!("Tray channel source error: {}", e))?;

    // Unix Signals (SIGUSR1 → overlay, SIGUSR2 → rofi menu)
    loop_handle
        .insert_source(
            signals,
            move |event: calloop::signals::Event, _, state: &mut AppState| {
                if event.signal() == calloop::signals::Signal::SIGUSR1 {
                    log_info("Received SIGUSR1. Launching overlay.");
                    state.daemon.launch_overlay(&mut state.wayland, &state.qh);
                } else if event.signal() == calloop::signals::Signal::SIGUSR2 {
                    log_info("Received SIGUSR2. Launching menu.");
                    let proxy = sender_for_signals.clone();
                    tokio::spawn(daemon::rofi_menu::show_menu(proxy));
                }
            },
        )
        .map_err(|e| anyhow::anyhow!("Signals source error: {}", e))?;

    // Daemon heartbeat: wake every ~50 ms to check global hotkeys (X11/Wayland-agnostic)
    // and confirm the overlay has closed cleanly so we can free buffers.
    let timer = Timer::immediate();
    loop_handle
        .insert_source(timer, |_, _, state: &mut AppState| {
            // Poll global hotkeys
            let mut hotkey_triggered = false;
            while let Ok(event) = GlobalHotKeyEvent::receiver().try_recv() {
                if event.state == global_hotkey::HotKeyState::Released {
                    hotkey_triggered = true;
                }
            }
            if hotkey_triggered {
                state.daemon.launch_overlay(&mut state.wayland, &state.qh);
            }

            if state.wayland.open_url {
                daemon::open_homepage();
                state.wayland.open_url = false;
            }

            // Deferred About launch: wait for menus to disappear before capturing background
            if let Some(t) = state.about_requested_at {
                if t.elapsed() >= Duration::from_millis(150) {
                    state.about_requested_at = None;
                    if state.wayland.overlay_app.is_none() && state.wayland.about_surface.is_none() {
                        let font_data = state.daemon.svc.cached_font_data.clone();
                        let dbus_conn = state.daemon.svc.dbus_conn.as_ref();
                        state.wayland.launch_about(&state.qh, font_data, dbus_conn);
                    }
                }
            }

            // --- Watchdog: single kick to bootstrap the render chain ---
            // Idle overlay (HUD off, no mouse) never calls render(), so the
            // watchdog inside render() never fires. We send ONE redraw when
            // the warning threshold is crossed; after that render() sets
            // needs_redraw=true itself and the frame callback keeps the loop alive.
            if let Some(ref app) = state.wayland.overlay_app {
                let timeout = app.config.system.auto_cancel;
                if timeout > 0 {
                    let elapsed = app.last_activity.elapsed().as_secs();
                    let warning_at = timeout.saturating_sub(10);
                    if elapsed >= warning_at && !state.wayland.is_redraw_pending() {
                        state.wayland.request_redraw();
                        state.wayland.redraw(&state.qh);
                    }
                }
            }

            if state.wayland.exit {
                if let Some(ref mut o) = state.wayland.overlay_app {
                    let color_deck = o.take_color_deck();
                    let overlay_config = o.config.clone();
                    
                    state.daemon.svc.finalize_overlay(&overlay_config, color_deck);
                }

                state.wayland.close_overlay();
                state.wayland.exit = false; // Reset for next time
            }

            TimeoutAction::ToDuration(Duration::from_millis(
                state.daemon.svc.config.system.poll_interval_ms,
            ))
        })
        .map_err(|e| anyhow::anyhow!("Timer source error: {}", e))?;

    // Assemble the global state and enter the eternal OS-socket listening loop.
    let mut app_state = AppState {
        daemon,
        wayland: wayland_state,
        qh,
        exit_requested: false,
        about_requested_at: None,
    };

    let signal = event_loop.get_signal();

    event_loop.run(None, &mut app_state, |state| {
        let qh = state.qh.clone();
        state.wayland.flush_pending_enters(&qh);
        if state.exit_requested {
            signal.stop();
        }
    })?;

    Ok(())
}

// ─── X11 Main Loop ──────────────────────────────────────────────────────────

fn run_x11_daemon() -> Result<()> {
    let svc = ColorService::new();

    // Tokio is required for DBusTray.
    let rt = tokio::runtime::Runtime::new()?;
    let _guard = rt.enter();

    connectors::x11::run_x11_daemon(svc)
}

// ─── Entry Point ─────────────────────────────────────────────────────────────

/// Checks via D-Bus whether another instance of the application is already running.
/// If it is, politely asks it to quit and waits for it to release resources.
fn check_and_kill_existing_instance() {
    let rt = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(_) => return,
    };

    rt.block_on(async {
        use std::time::Duration;

        let conn = match zbus::Connection::session().await {
            Ok(c) => c,
            Err(_) => return,
        };

        let proxy = match zbus::fdo::DBusProxy::new(&conn).await {
            Ok(p) => p,
            Err(_) => return,
        };

        // Check whether the D-Bus name we expect is already taken.
        let bus_name: zbus::names::WellKnownName = "org.kde.StatusNotifierItem.InstantEyedropper".try_into().unwrap();
        let bus_name_ref = zbus::names::BusName::WellKnown(bus_name.clone());

        if let Ok(has_owner) = proxy.name_has_owner(bus_name_ref.as_ref()).await {
            if has_owner {
                log_info("Found existing instance. Asking it to quit politely...");

                // Send the Quit command via D-Bus.
                let _ = conn.call_method(
                    Some(bus_name.as_ref()),
                    "/StatusNotifierItem",
                    Some("org.kde.StatusNotifierItem"),
                    "Quit",
                    &(),
                ).await;

                // Wait for the old process to actually release the bus (up to 2 seconds).
                for _ in 0..20 {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    if let Ok(still_alive) = proxy.name_has_owner(bus_name_ref.as_ref()).await {
                        if !still_alive {
                            log_info("Old instance successfully terminated. Taking over...");
                            return;
                        }
                    }
                }
                log_warn("Old instance didn't quit in time. Proceeding anyway, but resources might conflict.");
            }
        }
    });
}

/// Entry point into the matrix.
/// Wayland detected → Layer Shell + Calloop path.
/// No Wayland → fallback to the proven Winit + Softbuffer architecture.
fn main() -> Result<()> {
    // 0. Announce our correct name to the OS so killall -SIGUSR1 ie-r works
    // even through layers of wrappers and loaders.
    let ret = unsafe { libc::prctl(libc::PR_SET_NAME, "ie-r\0".as_ptr()) };
    if ret != 0 {
        log_warn("prctl(PR_SET_NAME) failed — killall -SIGUSR1 ie-r may not work");
    }

    // 1. Politely ask the old process to quit.
    check_and_kill_existing_instance();

    // 2. Attempt to connect to Wayland. If $WAYLAND_DISPLAY is empty or
    // the compositor does not respond, take the X11 path.
    match Connection::connect_to_env() {
        Ok(_conn) => {
            // conn is dropped here — run_wayland_daemon will create its own.
            drop(_conn);
            run_wayland_daemon()
        }
        Err(e) => {
            log_info(&format!("Wayland connection failed ({}). Falling back to X11/Winit.", e));
            run_x11_daemon()
        }
    }
}
