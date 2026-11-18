//! Optional Sparkle checks for signed Rune distributions. The packager supplies
//! this framework and a dedicated appcast public key together.
use objc2::{
    msg_send,
    rc::{Allocated, Retained},
    runtime::{AnyClass, AnyObject},
};
use objc2_foundation::{NSBundle, NSError, NSString};

pub struct Updater(Retained<AnyObject>);

impl Updater {
    pub fn configured() -> bool {
        NSBundle::mainBundle()
            .objectForInfoDictionaryKey(&NSString::from_str("SpottyRuneUpdateChannel"))
            .is_some_and(|value| {
                value
                    .downcast_ref::<NSString>()
                    .is_some_and(|s| s.to_string() == "rune")
            })
    }

    pub fn start() -> Option<Self> {
        if !Self::configured() {
            return None;
        }
        let frameworks = NSBundle::mainBundle().privateFrameworksURL()?;
        let url =
            frameworks.URLByAppendingPathComponent(&NSString::from_str("Sparkle.framework"))?;
        let bundle = NSBundle::bundleWithURL(&url)?;
        // Only load the framework embedded and signed with this application.
        unsafe {
            bundle.loadAndReturnError().ok()?;
        }
        let class = AnyClass::get(c"SPUStandardUpdaterController")?;
        // These selectors are the public Objective-C API from Sparkle 2.10.
        unsafe {
            let allocated: Allocated<AnyObject> = msg_send![class, alloc];
            let controller: Retained<AnyObject> = msg_send![allocated,
                initWithStartingUpdater: false,
                updaterDelegate: Option::<&AnyObject>::None,
                userDriverDelegate: Option::<&AnyObject>::None
            ];
            let updater: Retained<AnyObject> = msg_send![&controller, updater];
            let _: () = msg_send![&updater, setAutomaticallyChecksForUpdates: true];
            let started: bool =
                msg_send![&updater, startUpdater: std::ptr::null_mut::<*mut NSError>()];
            if !started {
                return None;
            }
            let _: () = msg_send![&updater, checkForUpdatesInBackground];
            Some(Self(controller))
        }
    }

    pub fn can_check(&self) -> bool {
        unsafe {
            let updater: Retained<AnyObject> = msg_send![&self.0, updater];
            msg_send![&updater, canCheckForUpdates]
        }
    }

    pub fn check(&self) {
        unsafe {
            if self.can_check() {
                let _: () = msg_send![&self.0, checkForUpdates: Option::<&AnyObject>::None];
            }
        }
    }
}
