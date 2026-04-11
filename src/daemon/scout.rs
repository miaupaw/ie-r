use anyhow::Result;
use global_hotkey::{GlobalHotKeyManager, hotkey::HotKey};
use std::str::FromStr;

pub struct Scout {
    pub _manager: GlobalHotKeyManager,
    pub _hotkey: HotKey,
}

use crate::core::terminal::{log_step, log_warn, log_error};

impl Scout {
    pub fn new(hotkey_str: &str) -> Result<Self> {
        let manager = GlobalHotKeyManager::new()?;

        let hotkey = match HotKey::from_str(hotkey_str) {
            Ok(h) => h,
            Err(_) => {
                log_warn(&format!("Failed to parse hotkey '{}'. Falling back to 'Alt+Shift+C'", hotkey_str));
                HotKey::from_str("Alt+Shift+C").unwrap() // this default should always parse
            }
        };

        if let Err(e) = manager.register(hotkey) {
            log_error(&format!("Global Hotkey registration failed (Normal on Wayland). Details: {:?}", e));
        } else {
            log_step("Scout", &format!("Global Hotkey registered: {}", hotkey_str));
        }

        Ok(Self {
            _manager: manager,
            _hotkey: hotkey,
        })
    }
}
