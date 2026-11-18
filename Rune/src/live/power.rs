use block2::RcBlock;
use objc2::{rc::Retained, runtime::ProtocolObject};
use objc2_app_kit::{
    NSWorkspace, NSWorkspaceDidWakeNotification, NSWorkspaceWillSleepNotification,
};
use objc2_foundation::{NSNotification, NSNotificationCenter, NSObjectProtocol};
use std::ptr::NonNull;

#[derive(Clone, Copy)]
pub(super) enum Event {
    Sleep,
    Wake,
}

pub struct PowerObserver {
    center: Retained<NSNotificationCenter>,
    tokens: [Retained<ProtocolObject<dyn NSObjectProtocol>>; 2],
}

impl PowerObserver {
    pub(super) fn new(publish: impl Fn(Event) + Send + Sync + 'static) -> Self {
        let center = NSWorkspace::sharedWorkspace().notificationCenter();
        let publish = std::sync::Arc::new(publish);
        // The blocks capture only a thread-safe publisher and never retain the notification.
        let tokens = unsafe {
            [
                (NSWorkspaceWillSleepNotification, Event::Sleep),
                (NSWorkspaceDidWakeNotification, Event::Wake),
            ]
            .map(|(name, event)| {
                let publish = publish.clone();
                let block = RcBlock::new(move |_: NonNull<NSNotification>| publish(event));
                center.addObserverForName_object_queue_usingBlock(Some(name), None, None, &block)
            })
        };
        Self { center, tokens }
    }
}

impl Drop for PowerObserver {
    fn drop(&mut self) {
        for token in &self.tokens {
            // Each token is still retained and was returned by this notification center.
            unsafe { self.center.removeObserver((**token).as_ref()) };
        }
    }
}

pub(super) fn connect_name() -> String {
    let label = std::process::Command::new("/usr/sbin/scutil")
        .args(["--get", "ComputerName"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok());
    let name = label
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty());
    format!("{} (Spotty)", name.unwrap_or("Mac"))
}
