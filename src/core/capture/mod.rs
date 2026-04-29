#[cfg(unix)]
pub mod kwin;
#[cfg(unix)]
pub mod portal;
#[cfg(unix)]
pub mod wlr;
#[cfg(windows)]
pub mod windows;

// Re-export for X11 connector and backwards compatibility.
#[cfg(unix)]
pub use portal::capture_screen;

use anyhow::Result;
#[cfg(unix)]
use crate::core::terminal::log_warn;
#[cfg(unix)]
use wayland_client::protocol::wl_output;

// ══════════════════════════════════════════════════════════════════════════════
// Capture pipeline data types.
//
// ScreenCapture  — raw XRGB8888 buffer for a single monitor.
// MonitorTile    — ScreenCapture + tile metadata (scale, position, output).
// PhysicalCanvas — virtual mosaic of all monitors, unified interface for
//                  overlay/render/input regardless of capture method.
// ══════════════════════════════════════════════════════════════════════════════

/// Screenshot data ready for SHM/HBITMAP (XRGB8888)
pub struct ScreenCapture {
    pub xrgb_buffer: Vec<u32>,
    pub width: u32,
    pub height: u32,
}

pub struct MonitorTile {
    pub capture: ScreenCapture,
    /// Platform-specific output handle (WlOutput on Unix, unused on Windows for now)
    #[cfg(unix)]
    pub output: Option<wayland_client::protocol::wl_output::WlOutput>,
    /// Fractional scale factor (e.g. 1.0, 1.5, 2.0).
    /// Used to translate pointer events (logical) → world coordinates.
    pub scale: f64,
    /// Logical position of this monitor in compositor space.
    pub logical_pos: (i32, i32),
    #[cfg(unix)]
    pub transform: wl_output::Transform,
}

impl MonitorTile {
    /// Construct a tile from capture + output metadata.
    /// Scale = capture_width / logical_width (fractional scaling).
    #[cfg(unix)]
    pub fn from_capture(
        capture: ScreenCapture,
        output: wayland_client::protocol::wl_output::WlOutput,
        logical_pos: (i32, i32),
        logical_w: i32,
        transform: wl_output::Transform,
    ) -> Self {
        let capture = apply_transform(capture, transform);
        let scale = if logical_w > 0 {
            capture.width as f64 / logical_w as f64
        } else {
            1.0
        };
        Self { capture, output: Some(output), scale, logical_pos, transform }
    }
}

/// Virtual mosaic of all captured monitors.
///
/// No single contiguous buffer — each tile lives in its own allocation.
/// Pixel lookup is O(N) where N = number of monitors (typically 1–4).
pub struct PhysicalCanvas {
    pub tiles: Vec<MonitorTile>,
    /// Index of the tile where the overlay surface currently lives.
    pub active_idx: usize,
}

impl PhysicalCanvas {
    /// Create a canvas from a set of tiles.
    pub fn build(tiles: Vec<MonitorTile>) -> Self {
        Self { tiles, active_idx: 0 }
    }

    /// Tile index by wl_output. O(N), N = number of monitors (1–4).
    #[cfg(unix)]
    pub fn find_tile(&self, output: &wayland_client::protocol::wl_output::WlOutput) -> Option<usize> {
        self.tiles.iter().position(|t| t.output.as_ref() == Some(output))
    }

    /// Like find_tile, but falls back to 0 (for input — cursor is always on some monitor).
    #[cfg(unix)]
    pub fn tile_index_for(&self, output: &wayland_client::protocol::wl_output::WlOutput) -> usize {
        self.find_tile(output).unwrap_or(0)
    }

    /// Create a canvas from a single full-desktop capture (Portal, X11, KWin).
    #[cfg(unix)]
    pub fn from_single(capture: ScreenCapture, output: Option<wayland_client::protocol::wl_output::WlOutput>) -> Self {
        Self {
            tiles: vec![MonitorTile {
                capture,
                output,
                scale: 1.0,
                logical_pos: (0, 0),
                transform: wl_output::Transform::Normal,
            }],
            active_idx: 0,
        }
    }

    /// Create a canvas from a single full-desktop capture (Windows / headless).
    #[cfg(windows)]
    pub fn from_single(capture: ScreenCapture) -> Self {
        Self {
            tiles: vec![MonitorTile {
                capture,
                scale: 1.0,
                logical_pos: (0, 0),
            }],
            active_idx: 0,
        }
    }

    /// Sample a pixel using active tile's local physical coordinates.
    /// If the point extends beyond the active tile, it does a raycast through
    /// the compositor's logical space to find the correct adjacent physical pixel.
    #[inline]
    pub fn sample(&self, local_x: i32, local_y: i32) -> Option<u32> {
        let active = &self.tiles[self.active_idx];

        // Fast path: point is inside the active tile
        if local_x >= 0 && (local_x as u32) < active.capture.width &&
           local_y >= 0 && (local_y as u32) < active.capture.height {
            let idx = local_y as usize * active.capture.width as usize + local_x as usize;
            return Some(active.capture.xrgb_buffer[idx]);
        }

        // Slower path: Raycast across logical space.
        // Convert local physical -> absolute logical coordinate
        let logical_x = active.logical_pos.0 + (local_x as f64 / active.scale).floor() as i32;
        let logical_y = active.logical_pos.1 + (local_y as f64 / active.scale).floor() as i32;

        for tile in &self.tiles {
            // Reconstruct logical dimensions of this tile
            let tile_log_w = (tile.capture.width as f64 / tile.scale).round() as i32;
            let tile_log_h = (tile.capture.height as f64 / tile.scale).round() as i32;

            // Checking if the absolute logical pos hits this tile's logical box
            if logical_x >= tile.logical_pos.0 && logical_x < tile.logical_pos.0 + tile_log_w &&
               logical_y >= tile.logical_pos.1 && logical_y < tile.logical_pos.1 + tile_log_h {

                // Translate back to the target tile's local physical pixels
                let target_local_log_x = logical_x - tile.logical_pos.0;
                let target_local_log_y = logical_y - tile.logical_pos.1;

                let phys_x = (target_local_log_x as f64 * tile.scale).round() as i32;
                let phys_y = (target_local_log_y as f64 * tile.scale).round() as i32;

                if phys_x >= 0 && (phys_x as u32) < tile.capture.width &&
                   phys_y >= 0 && (phys_y as u32) < tile.capture.height {
                    let idx = phys_y as usize * tile.capture.width as usize + phys_x as usize;
                    return Some(tile.capture.xrgb_buffer[idx]);
                }
            }
        }
        None
    }

    /// Average color of (2*radius+1)² area around (cx, cy). radius=0 → single pixel.
    /// Cross-monitor aware via sample(). Out-of-bounds pixels are excluded from the average.
    pub fn sample_average(&self, cx: i32, cy: i32, radius: i32) -> (u8, u8, u8) {
        let mut sum_r = 0u32;
        let mut sum_g = 0u32;
        let mut sum_b = 0u32;
        let mut count = 0u32;
        for dy in -radius..=radius {
            for dx in -radius..=radius {
                if let Some(px) = self.sample(cx + dx, cy + dy) {
                    sum_r += (px >> 16) & 0xFF;
                    sum_g += (px >> 8) & 0xFF;
                    sum_b += px & 0xFF;
                    count += 1;
                }
            }
        }
        if count > 0 {
            ((sum_r / count) as u8, (sum_g / count) as u8, (sum_b / count) as u8)
        } else {
            (0, 0, 0)
        }
    }

    /// The tile where the overlay surface lives.
    pub fn active(&self) -> &MonitorTile {
        &self.tiles[self.active_idx]
    }
}

#[cfg(unix)]
fn apply_transform(capture: ScreenCapture, transform: wl_output::Transform) -> ScreenCapture {
    let src_w = capture.width as usize;
    let src_h = capture.height as usize;
    let src = &capture.xrgb_buffer;

    match transform {
        wl_output::Transform::Normal => capture,

        wl_output::Transform::_90 => {
            let dst_w = src_h;
            let dst_h = src_w;
            let mut dst = vec![0u32; dst_w * dst_h];
            for y in 0..src_h {
                for x in 0..src_w {
                    dst[x * dst_w + (src_h - 1 - y)] = src[y * src_w + x];
                }
            }
            ScreenCapture { xrgb_buffer: dst, width: dst_w as u32, height: dst_h as u32 }
        }

        wl_output::Transform::_180 => {
            let mut dst = vec![0u32; src_w * src_h];
            for y in 0..src_h {
                for x in 0..src_w {
                    dst[(src_h - 1 - y) * src_w + (src_w - 1 - x)] = src[y * src_w + x];
                }
            }
            ScreenCapture { xrgb_buffer: dst, width: capture.width, height: capture.height }
        }

        wl_output::Transform::_270 => {
            let dst_w = src_h;
            let dst_h = src_w;
            let mut dst = vec![0u32; dst_w * dst_h];
            for y in 0..src_h {
                for x in 0..src_w {
                    dst[(src_w - 1 - x) * dst_w + y] = src[y * src_w + x];
                }
            }
            ScreenCapture { xrgb_buffer: dst, width: dst_w as u32, height: dst_h as u32 }
        }

        wl_output::Transform::Flipped => {
            let mut dst = vec![0u32; src_w * src_h];
            for y in 0..src_h {
                for x in 0..src_w {
                    dst[y * src_w + (src_w - 1 - x)] = src[y * src_w + x];
                }
            }
            ScreenCapture { xrgb_buffer: dst, width: capture.width, height: capture.height }
        }

        wl_output::Transform::Flipped90 => {
            let dst_w = src_h;
            let dst_h = src_w;
            let mut dst = vec![0u32; dst_w * dst_h];
            for y in 0..src_h {
                for x in 0..src_w {
                    dst[(src_w - 1 - x) * dst_w + (src_h - 1 - y)] = src[y * src_w + x];
                }
            }
            ScreenCapture { xrgb_buffer: dst, width: dst_w as u32, height: dst_h as u32 }
        }

        wl_output::Transform::Flipped180 => {
            let mut dst = vec![0u32; src_w * src_h];
            for y in 0..src_h {
                for x in 0..src_w {
                    dst[(src_h - 1 - y) * src_w + x] = src[y * src_w + x];
                }
            }
            ScreenCapture { xrgb_buffer: dst, width: capture.width, height: capture.height }
        }

        wl_output::Transform::Flipped270 => {
            let dst_w = src_h;
            let dst_h = src_w;
            let mut dst = vec![0u32; dst_w * dst_h];
            for y in 0..src_h {
                for x in 0..src_w {
                    dst[x * dst_w + y] = src[y * src_w + x];
                }
            }
            ScreenCapture { xrgb_buffer: dst, width: dst_w as u32, height: dst_h as u32 }
        }

        _ => capture,
    }
}

/// Convert decoded RGBA image to XRGB u32 buffer
#[cfg(unix)]
pub(crate) fn rgba_to_capture(img: &image::RgbaImage) -> ScreenCapture {
    let (w, h) = img.dimensions();
    let raw = img.as_raw();
    let num = (w * h) as usize;
    let mut buf = Vec::with_capacity(num);
    for chunk in raw.chunks_exact(4) {
        buf.push(((chunk[0] as u32) << 16) | ((chunk[1] as u32) << 8) | (chunk[2] as u32));
    }
    ScreenCapture {
        xrgb_buffer: buf,
        width: w,
        height: h,
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════

/// Output metadata pre-collected on the main thread (OutputState is !Send).
#[cfg(unix)]
pub struct OutputMeta {
    pub output: wayland_client::protocol::wl_output::WlOutput,
    pub name: String,
    pub logical_pos: (i32, i32),
    pub logical_w: i32,
    pub transform: wl_output::Transform,
}

/// Capture all monitors, selecting the best available protocol.
#[cfg(unix)]
pub fn capture_all_outputs(
    output_meta: &[OutputMeta],
    screencopy: Option<(&wayland_client::Connection, &wayland_protocols_wlr::screencopy::v1::client::zwlr_screencopy_manager_v1::ZwlrScreencopyManagerV1, &wayland_client::protocol::wl_shm::WlShm)>,
    dbus_conn: Option<&zbus::blocking::Connection>,
) -> Result<PhysicalCanvas> {
    // --- Tier 1: WLR Screencopy (Hyprland / Sway) ---
    if let Some((conn, manager, wl_shm)) = screencopy {
        let handles: Vec<_> = output_meta.iter().map(|meta| {
            let conn = conn.clone();
            let manager = manager.clone();
            let wl_shm = wl_shm.clone();
            let out_clone = meta.output.clone();
            let logical_pos = meta.logical_pos;
            let logical_w = meta.logical_w;
            let transform = meta.transform;
            std::thread::spawn(move || {
                wlr::capture_output(&conn, &manager, &wl_shm, &out_clone)
                    .map(|capture| MonitorTile::from_capture(capture, out_clone, logical_pos, logical_w, transform))
            })
        }).collect();

        let tiles: Vec<_> = handles.into_iter()
            .filter_map(|h| h.join().ok()?.map_err(|e| {
                log_warn(&format!("WLR capture skipped: {}", e));
            }).ok())
            .collect();

        if !tiles.is_empty() {
            return Ok(PhysicalCanvas::build(tiles));
        }
    }

    // --- Tier 2: KWin per-output DBus (Plasma multi-monitor) ---
    if let Some(conn) = dbus_conn {
        let tiles: Vec<_> = output_meta.iter()
            .filter(|m| !m.name.is_empty())
            .filter_map(|meta| {
                match kwin::capture_output_dbus(conn, &meta.name) {
                    Ok(capture) => Some(MonitorTile::from_capture(
                        capture,
                        meta.output.clone(),
                        meta.logical_pos,
                        meta.logical_w,
                        meta.transform,
                    )),
                    Err(e) => {
                        let e_str = e.to_string();
                        let (kind, desc) = e_str.split_once(": ").unwrap_or(("", &e_str));
                        log_warn(&format!("KWin capture skipped for {}:", meta.name));
                        if !kind.is_empty() { log_warn(&format!("   {}:", kind)); }
                        log_warn(&format!("   {}", desc));
                        None
                    }
                }
            })
            .collect();

        if !tiles.is_empty() {
            return Ok(PhysicalCanvas::build(tiles));
        }
    }

    // --- Tier 3: single-capture fallback (KWin single / XDG Portal / Spectacle) ---
    let capture = portal::capture_screen(dbus_conn)?;
    let output = output_meta.first().map(|m| m.output.clone());
    Ok(PhysicalCanvas::from_single(capture, output))
}

// ══════════════════════════════════════════════════════════════════════════════
// Windows capture — DXGI Desktop Duplication / GDI BitBlt (Phase 1).
// ══════════════════════════════════════════════════════════════════════════════

/// Capture all monitors: GDI BitBlt (Tier 1) → DXGI Desktop Duplication (Tier 2).
///
/// GDI first: reliable on all Windows versions including 8.1 VMs.
/// DXGI has cold-start issues (black frame without prior compositor activity)
/// and higher latency with warm-up (~90ms). GDI BitBlt is ~30ms and always works.
/// TODO: revisit tier order after real-hardware testing (DXGI may be faster there).
#[cfg(windows)]
pub fn capture_all_outputs() -> Result<PhysicalCanvas> {
    use crate::core::terminal::log_warn;

    // Tier 1: GDI BitBlt (~30ms, reliable, single virtual screen)
    match windows::capture_gdi() {
        Ok(canvas) => return Ok(canvas),
        Err(e) => log_warn(&format!("GDI failed, falling back to DXGI: {}", e)),
    }

    // Tier 2: DXGI Desktop Duplication (may return black on cold start)
    windows::capture_dxgi()
}
