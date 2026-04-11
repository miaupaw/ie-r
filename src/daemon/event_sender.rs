use super::UserEvent;
use std::sync::Arc;

/// Universal event sender.
/// Abstracts calloop::channel::Sender and winit::EventLoopProxy
/// into a single type compatible with zbus (Send + Sync + 'static).
#[derive(Clone)]
pub struct EventSender {
    inner: Arc<dyn Fn(UserEvent) + Send + Sync>,
}

impl EventSender {
    /// Creates from a calloop channel (Wayland path).
    pub fn from_calloop(tx: calloop::channel::Sender<UserEvent>) -> Self {
        Self {
            inner: Arc::new(move |event| {
                let _ = tx.send(event);
            }),
        }
    }

    /// Creates from a winit event loop proxy (X11 path).
    pub fn from_winit(proxy: winit::event_loop::EventLoopProxy<UserEvent>) -> Self {
        Self {
            inner: Arc::new(move |event| {
                let _ = proxy.send_event(event);
            }),
        }
    }

    /// Dispatches an event to the corresponding event loop.
    pub fn send(&self, event: UserEvent) {
        (self.inner)(event);
    }
}
