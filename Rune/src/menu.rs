use crate::{Panel, Route, State};
use rune::{AppHandle, MenuItem};

#[derive(Default)]
pub struct Menus {
    pub host: Option<AppHandle<State>>,
    last: Option<Availability>,
}

#[derive(Copy, Clone, PartialEq)]
struct Availability {
    browse: bool,
    back: bool,
    forward: bool,
    toggle: bool,
    skip: bool,
    start: bool,
    sign_out: bool,
    #[cfg(target_os = "macos")]
    updater: Option<bool>,
}

pub fn update(state: &mut State) {
    let Some(host) = &state.menus.host else {
        return;
    };
    let player = &state.snapshot.playback;
    let flags = Availability {
        browse: state.snapshot.catalog_ready,
        back: state.cursor > 0,
        forward: state.cursor + 1 < state.history.len(),
        toggle: player.can_toggle,
        skip: player.can_skip,
        start: player.can_start,
        sign_out: !matches!(
            state.snapshot.phase.as_str(),
            "" | "signedOut" | "unavailable"
        ),
        #[cfg(target_os = "macos")]
        updater: state
            .updater
            .as_ref()
            .map(crate::updater::Updater::can_check),
    };
    if state.menus.last == Some(flags) {
        return;
    }
    let mut items = vec![
        MenuItem::new("Search", |s: &mut State, tx| s.navigate(Route::Search, tx))
            .menu("Navigate")
            .enabled(flags.browse),
        MenuItem::new("Go Back", |s: &mut State, tx| s.move_history(-1, tx))
            .menu("Navigate")
            .enabled(flags.back),
        MenuItem::new("Go Forward", |s: &mut State, tx| s.move_history(1, tx))
            .menu("Navigate")
            .enabled(flags.forward),
        MenuItem::new("Play/Pause", |s: &mut State, _| {
            s.send("toggle", None, None)
        })
        .menu("Playback")
        .enabled(flags.toggle),
        MenuItem::new("Previous", |s: &mut State, _| {
            s.send("previous", None, None)
        })
        .menu("Playback")
        .enabled(flags.skip)
        .key_equivalent("mod+shift+left".parse().expect("Previous shortcut")),
        MenuItem::new("Next", |s: &mut State, _| s.send("next", None, None))
            .menu("Playback")
            .enabled(flags.skip)
            .key_equivalent("mod+shift+right".parse().expect("Next shortcut")),
        MenuItem::separator().menu("Playback"),
        MenuItem::new("Toggle Shuffle", |s: &mut State, _| {
            s.send("shuffle", None, None)
        })
        .menu("Playback")
        .enabled(flags.start),
        MenuItem::new("Cycle Repeat Mode", |s: &mut State, _| {
            s.send("repeat", None, None)
        })
        .menu("Playback")
        .enabled(flags.start),
        MenuItem::new("Show Queue", |s: &mut State, _| {
            s.toggle_panel(Panel::Queue)
        })
        .menu("Playback"),
        MenuItem::new("Spotify Account", |s: &mut State, _| {
            s.toggle_panel(Panel::Account)
        }),
        MenuItem::new("Sign Out", |s: &mut State, _| {
            s.panel = Some(Panel::Account);
            s.signout_confirmation = true;
        })
        .enabled(flags.sign_out),
    ];
    #[cfg(target_os = "macos")]
    if let Some(enabled) = flags.updater {
        items.push(
            MenuItem::new("Check for Updates…", |s: &mut State, _| {
                if let Some(updater) = &s.updater {
                    updater.check();
                }
            })
            .after("orderFrontStandardAboutPanel:")
            .enabled(enabled),
        );
    }
    if host.set_menu(items.drain(..)).is_ok() {
        state.menus.last = Some(flags);
    }
}
