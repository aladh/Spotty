use super::{SCROLL, components::*};
use crate::{
    MenuSource, Panel, State,
    model::{Device, Route, Track},
};
use rune::{Cursor, El, Phase, col, el, row};

pub fn player(state: &State) -> El {
    let snapshot = &state.snapshot;
    let pb = &snapshot.playback;
    let stamp = snapshot.stamp;
    let playing = pb.playing;
    let mut now = row()
        .gap(11.0)
        .center_y()
        .grow(1.0)
        .min_w(0.0)
        .child(picture(state, pb.artwork.as_deref(), 56.0, 56.0, 4.0));
    let known_track = snapshot
        .tracks
        .iter()
        .chain(&snapshot.history)
        .find(|row| row.uri == pb.uri);
    let title = label(&pb.title, 14.0, 565.0, INK).w_full().truncate();
    let artist = label(&pb.artist, 12.0, 460.0, MUTED).w_full().truncate();
    let title = if let Some(album) = known_track.and_then(|track| track.album_item.as_ref()) {
        let uri = album.uri.clone();
        title
            .role("link")
            .cursor(Cursor::Pointer)
            .on_press_tx(move |s: &mut State, tx| s.navigate(Route::Detail(uri.clone()), tx))
    } else {
        title
    };
    let artist = if let Some(artist_ref) = known_track.and_then(|track| track.artists.first()) {
        let uri = artist_ref.uri.clone();
        artist
            .role("link")
            .cursor(Cursor::Pointer)
            .on_press_tx(move |s: &mut State, tx| s.navigate(Route::Detail(uri.clone()), tx))
    } else {
        artist
    };
    now = now.child(
        col()
            .grow(1.0)
            .min_w(0.0)
            .gap(2.0)
            .child(title)
            .child(artist),
    );

    let toggle_uri = pb.uri.clone();
    let glyph = |action, description, icon, enabled, green| {
        control(
            action,
            description,
            icon_button(icon, 32.0, 20.0, BLACK, if green { ACCENT } else { MUTED }),
            enabled,
            move |s, _| s.command(action, None, None, None, stamp),
        )
    };
    let controls = row()
        .center()
        .gap(9.0)
        .h(40.0)
        .child(glyph(
            "shuffle",
            if pb.shuffle {
                "Shuffle on"
            } else {
                "Shuffle off"
            },
            "shuffle",
            pb.can_start,
            pb.shuffle,
        ))
        .child(glyph(
            "previous",
            "Previous track",
            "prev",
            pb.can_skip,
            false,
        ))
        .child(control(
            "toggle",
            if playing { "Pause" } else { "Play" },
            icon_button(
                if playing { "pause" } else { "play" },
                32.0,
                21.0,
                if pb.can_toggle { INK } else { TILE },
                BLACK,
            ),
            pb.can_toggle,
            move |s, _| s.command("toggle", Some(&toggle_uri), None, None, stamp),
        ))
        .child(glyph("next", "Next track", "next", pb.can_skip, false))
        .child(glyph(
            "repeat",
            match pb.repeat.as_str() {
                "context" => "Repeat queue",
                "track" => "Repeat track",
                _ => "Repeat off",
            },
            "repeat",
            pb.can_start,
            pb.repeat != "off",
        ));
    let seeking = pb.duration > 0.0 && pb.can_start;
    let fraction = state.seek_preview.unwrap_or_else(|| {
        if pb.duration > 0.0 {
            (pb.position / pb.duration).clamp(0.0, 1.0)
        } else {
            0.0
        }
    });
    let mut scrubber = col()
        .key("seek")
        .grow(1.0)
        .min_w(0.0)
        .h(22.0)
        .justify_center()
        .role("slider")
        .label("Playback position")
        .focusable(seeking)
        .disabled(!seeking)
        .range_value(fraction, 0.0, 1.0)
        .hover_group_focus();
    let mut filled = el()
        .grow(fraction as f32)
        .h(4.0)
        .fill(color(if state.seek_preview.is_some() {
            ACCENT
        } else {
            INK
        }))
        .radius(2.0);
    if seeking {
        filled = filled.child(
            el().size(12.0, 12.0)
                .radius(6.0)
                .fill(color(INK))
                .self_end()
                .offset(6.0, -4.0)
                .group_opacity(
                    if state.seek_preview.is_some() {
                        1.0
                    } else {
                        0.0
                    },
                    1.0,
                ),
        );
    }
    scrubber = scrubber.child(
        row()
            .h(4.0)
            .w_full()
            .radius(2.0)
            .fill(color("#555555"))
            .child(filled)
            .child(el().grow(1.0 - fraction as f32)),
    );
    if seeking {
        let uri = pb.uri.clone();
        let keyboard = uri.clone();
        scrubber = scrubber
            .range_step(0.025)
            .cursor(Cursor::Pointer)
            .on_step(move |s: &mut State, direction, _| {
                let current = &s.snapshot.playback;
                if current.uri == keyboard && current.duration > 0.0 {
                    let at = (current.position / current.duration + 0.025 * f64::from(direction))
                        .clamp(0.0, 1.0);
                    s.command("seek", Some(&keyboard), None, Some(at), stamp);
                }
            })
            .on_drag(move |s: &mut State, drag, _| {
                let at = f64::from((drag.x / drag.w.max(1.0)).clamp(0.0, 1.0));
                if drag.phase == Phase::Up {
                    s.seek_preview = None;
                    if !drag.cancelled() && s.snapshot.playback.uri == uri {
                        s.command("seek", Some(&uri), None, Some(at), stamp);
                    }
                } else if s.snapshot.playback.uri == uri {
                    s.seek_preview = Some(at);
                }
            });
    }
    let at = fraction * pb.duration;
    let progress = row()
        .w_full()
        .h(23.0)
        .gap(11.0)
        .center_y()
        .child(
            row()
                .w(43.0)
                .center_y()
                .justify_end()
                .child(label(time(at), 11.0, 530.0, MUTED)),
        )
        .child(scrubber)
        .child(label(format!("-{}", time(pb.duration - at)), 11.0, 530.0, MUTED).w(44.0));
    let center = col()
        .grow(1.7)
        .min_w(240.0)
        .max_w(680.0)
        .center_y()
        .child(controls)
        .child(progress);
    let queue = control(
        "open-queue",
        "Queue",
        icon_button(
            "queue",
            32.0,
            19.0,
            BLACK,
            if state.panel == Some(Panel::Queue) {
                ACCENT
            } else {
                MUTED
            },
        ),
        true,
        |s, _| s.toggle_panel(Panel::Queue),
    );
    let devices = control(
        "open-devices",
        "Connect to a device",
        icon_button(
            "device",
            32.0,
            19.0,
            BLACK,
            if state.panel == Some(Panel::Devices) {
                ACCENT
            } else {
                MUTED
            },
        ),
        true,
        |s, _| s.toggle_panel(Panel::Devices),
    );
    let mut right = row().grow(1.0).min_w(0.0).gap(1.0).center_y().justify_end();
    if let Some(feedback) = &snapshot.feedback {
        right = right.child(label(feedback, 12.0, 550.0, INK).max_w(240.0).truncate());
    }
    if !cfg!(target_os = "macos") && !state.is_demo() {
        right = right.child(control(
            "account",
            "Account",
            icon_button("dots", 32.0, 19.0, BLACK, MUTED),
            true,
            |s, _| s.toggle_panel(Panel::Account),
        ));
    }
    let bar = row()
        .key("player")
        .w_full()
        .h(78.0)
        .px(16.0)
        .gap(15.0)
        .center_y()
        .fill(color(BLACK))
        .child(now)
        .child(center)
        .child(right.child(queue).child(devices));
    let mut stack = col().child(bar);
    if !pb.device.is_empty() && pb.device != "This computer" && !pb.uri.is_empty() {
        let status = format!(
            "{} on {}",
            if playing { "Playing" } else { "Paused" },
            pb.device
        );
        let face = row()
            .w_full()
            .h(23.0)
            .px(10.0)
            .gap(6.0)
            .center_y()
            .justify_end()
            .radius(5.0)
            .fill(color(ACCENT))
            .child(mark("device", 15.0, BLACK))
            .child(label(&status, 12.0, 700.0, BLACK));
        stack = stack.child(col().px(8.0).pb(6.0).child(control(
            "connect-status",
            status,
            face,
            true,
            |s, _| s.toggle_panel(Panel::Devices),
        )));
    }
    stack
}

pub fn inspector(state: &State, panel: Panel) -> El {
    let title = match panel {
        Panel::Queue => "Queue",
        Panel::Devices => "Connect to a device",
        Panel::Account => "Account",
    };
    let top = row()
        .h(59.0)
        .px(16.0)
        .center_y()
        .justify_between()
        .child(label(title, 19.0, 720.0, INK).role("heading").level(2))
        .child(control(
            "close-inspector",
            "Close panel",
            icon_button("close", 30.0, 18.0, BG, MUTED),
            true,
            move |s, _| s.toggle_panel(panel),
        ));
    let content = match panel {
        Panel::Queue => queue(state),
        Panel::Devices => devices(state),
        Panel::Account => account(state),
    };
    col()
        .key("inspector")
        .w(state.panel_width)
        .min_w(260.0)
        .min_h(0.0)
        .fill(color(BG))
        .child(top)
        .child(content)
}

fn queue(state: &State) -> El {
    let snapshot = &state.snapshot;
    let tabs = row()
        .px(15.0)
        .h(41.0)
        .gap(12.0)
        .center_y()
        .child(tab("queue-tab", "Queue", !state.history_tab, false))
        .child(tab(
            "history-tab",
            "Recently played",
            state.history_tab,
            true,
        ));
    let mut contents = col().px(12.0).pb(12.0).gap(2.0);
    if state.history_tab {
        if snapshot.history.is_empty() {
            contents = contents.child(label("Nothing played yet", 14.0, 450.0, MUTED).py(15.0));
        }
        contents = contents.children(
            snapshot
                .history
                .iter()
                .enumerate()
                .map(|(i, track)| playlist_row(state, track, i, MenuSource::History)),
        );
    } else {
        let pb = &snapshot.playback;
        if !pb.uri.is_empty() {
            let track = Track {
                id: "now-playing".into(),
                uri: pb.uri.clone(),
                title: pb.title.clone(),
                artist: pb.artist.clone(),
                artwork: pb.artwork.clone(),
                ..Track::default()
            };
            contents = contents
                .child(label("Now playing", 14.0, 680.0, INK).pt(15.0).pb(7.0))
                .child(playlist_row(state, &track, 0, MenuSource::Queue));
        }
        let mut next = col()
            .gap(4.0)
            .pt(16.0)
            .pb(8.0)
            .child(label("Next up", 14.0, 680.0, INK));
        if !pb.context.is_empty()
            && let Some(context) = snapshot
                .details
                .as_ref()
                .filter(|item| item.uri == pb.context)
                .or_else(|| snapshot.library.iter().find(|item| item.uri == pb.context))
        {
            let uri = context.uri.clone();
            next = next.child(
                label(format!("Next from {}", context.title), 13.0, 450.0, MUTED)
                    .w_full()
                    .truncate()
                    .role("link")
                    .cursor(Cursor::Pointer)
                    .on_press_tx(move |s: &mut State, tx| {
                        s.navigate(Route::Detail(uri.clone()), tx)
                    }),
            );
        }
        contents = contents.child(next).children(
            snapshot
                .queue
                .iter()
                .enumerate()
                .map(|(i, track)| playlist_row(state, track, i + 1, MenuSource::Queue)),
        );
        if snapshot.queue.is_empty() {
            contents = contents.child(label("No upcoming tracks", 14.0, 450.0, MUTED).py(10.0));
        }
    }
    col().min_h(0.0).grow(1.0).child(tabs).child(line()).child(
        col()
            .key("queue-scroll")
            .grow(1.0)
            .min_h(0.0)
            .scroll(SCROLL)
            .child(contents.role("list").focus_group()),
    )
}

fn tab(key: &str, title: &str, active: bool, history: bool) -> El {
    let mut face = col()
        .h(39.0)
        .px(4.0)
        .justify_end()
        .child(label(title, 14.0, 690.0, if active { INK } else { MUTED }).pb(9.0));
    face = face.child(el().w_full().h(2.0).fill(if active {
        color(ACCENT)
    } else {
        rune::Color::TRANSPARENT
    }));
    control(key, title, face, true, move |s, _| s.history_tab = history)
        .role("tab")
        .focus_selected(active)
}

fn playlist_row(state: &State, track: &Track, index: usize, source: MenuSource) -> El {
    let now = track.id == "now-playing";
    let playing = now && state.snapshot.playback.playing;
    let selected = if source == MenuSource::History {
        state.history_selected.as_deref() == Some(&track.id)
    } else {
        state.queue_selected.contains(&track.id)
    };
    let id = track.id.clone();
    let select = id.clone();
    let activation = id.clone();
    let menu = id.clone();
    let source_key = if source == MenuSource::History {
        "history"
    } else {
        "queue"
    };
    let stamp = state.snapshot.stamp;
    let play_key = format!("{source_key}-play-{index}");
    let row_key = format!("{source_key}-row-{index}");
    let can_play = if now {
        state.snapshot.playback.can_toggle
    } else {
        state.snapshot.playback.can_start
    };
    let focus_id = id.clone();
    let art = picture(state, track.artwork.as_deref(), 48.0, 48.0, 4.0);
    let art = art.child(
        control(
            play_key.clone(),
            format!("{} {}", if playing { "Pause" } else { "Play" }, track.title),
            icon_button(if playing { "pause" } else { "play" }, 48.0, 23.0, BG, INK).radius(4.0),
            can_play,
            move |s, _| {
                let action = if now {
                    "toggle"
                } else if source == MenuSource::History {
                    "playHistory"
                } else {
                    "playQueue"
                };
                s.command(action, (!now).then_some(id.as_str()), None, None, stamp);
            },
        )
        .tab_index(-1)
        .group_opacity(0.0, 1.0),
    );
    let row = row()
        .key(row_key.clone())
        .h(64.0)
        .px(7.0)
        .gap(10.0)
        .center_y()
        .radius(4.0)
        .fill(color(if selected {
            if state.window_focused {
                "#454545"
            } else {
                "#343434"
            }
        } else {
            BG
        }))
        .child(art)
        .child(
            col()
                .grow(1.0)
                .min_w(0.0)
                .gap(3.0)
                .child(
                    label(&track.title, 15.0, 555.0, if now { ACCENT } else { INK })
                        .w_full()
                        .truncate(),
                )
                .child(label(&track.artist, 13.0, 460.0, MUTED).w_full().truncate()),
        )
        .role("row")
        .label(format!("{}, {}", track.title, track.artist))
        .focusable(true)
        .focus_selected(selected)
        .hover_group_focus()
        .on_key(move |s: &mut State, event, tx| {
            let selected = if source == MenuSource::History {
                s.history_selected.as_ref() == Some(&focus_id)
            } else {
                s.queue_selected.len() == 1 && s.queue_selected.contains(&focus_id)
            };
            can_play && selected && focus_row_action(event, tx, &row_key, &play_key)
        })
        .on_press_tx(move |s: &mut State, tx| {
            if source == MenuSource::History {
                s.history_selected = Some(select.clone());
            } else {
                s.select_queue(&select, tx.mods());
            }
        })
        .on_double_press(move |s: &mut State| {
            if source == MenuSource::History && s.history_selected.as_ref() == Some(&activation)
                || source == MenuSource::Queue
                    && s.queue_selected.len() == 1
                    && s.queue_selected.contains(&activation)
            {
                s.primary(source, false);
            }
        })
        .on_secondary_press(move |s: &mut State, point, _| {
            s.context_menu(source, &menu, [point.x, point.y])
        });
    if selected {
        row
    } else {
        row.hover(color(INK).alpha(0.10))
    }
}

fn devices(state: &State) -> El {
    let snap = &state.snapshot;
    let local = |device: &Device| device.name == "This computer";
    let current = snap.devices.iter().find(|device| device.active);
    let default = current.is_none() && snap.playback.can_start && snap.playback.device.is_empty();
    let highlighted = current.or_else(|| {
        default
            .then(|| snap.devices.iter().find(|device| local(device)))
            .flatten()
    });
    let mut contents = col().px(14.0).py(12.0).gap(5.0);
    if let Some(device) = highlighted {
        let status = if default {
            "Ready to play"
        } else {
            "Active device"
        };
        let accessibility = if default { "Default device" } else { status };
        contents = contents
            .child(label("Current device", 14.0, 680.0, INK).pb(5.0))
            .child(
                device_row(device, status, true)
                    .role("group")
                    .label(format!("{accessibility}, {}", device.name)),
            );
    }
    let mut available: Vec<_> = snap
        .devices
        .iter()
        .filter(|device| highlighted.is_none_or(|picked| picked.id != device.id))
        .collect();
    available.sort_by_key(|device| !local(device));
    if !available.is_empty() {
        contents = contents.child(label("Available devices", 14.0, 680.0, INK).pt(8.0).pb(4.0));
    } else if highlighted.is_none() {
        contents = contents.child(label("No devices available", 14.0, 450.0, MUTED).py(10.0));
    }
    for (i, device) in available.into_iter().enumerate() {
        let id = device.id.clone();
        let stamp = snap.stamp;
        contents = contents.child(control(
            format!("device-{i}"),
            &device.name,
            device_row(device, &device.detail, false),
            snap.playback.can_transfer,
            move |s, _| s.command("device", Some(&id), None, None, stamp),
        ));
    }
    col().grow(1.0).min_h(0.0).scroll(SCROLL).child(contents)
}

fn device_row(device: &Device, detail: &str, current: bool) -> El {
    row()
        .h(if current { 66.0 } else { 56.0 })
        .px(8.0)
        .gap(11.0)
        .center_y()
        .radius(5.0)
        .fill(color(if current { TILE } else { BG }))
        .child(mark(
            if device.detail.eq_ignore_ascii_case("computer") {
                "device"
            } else {
                "speaker"
            },
            25.0,
            if current { ACCENT } else { MUTED },
        ))
        .child(
            col()
                .gap(3.0)
                .grow(1.0)
                .min_w(0.0)
                .child(
                    label(
                        &device.name,
                        15.0,
                        650.0,
                        if current { ACCENT } else { INK },
                    )
                    .w_full()
                    .truncate(),
                )
                .child(label(detail, 13.0, 450.0, MUTED).w_full().truncate()),
        )
}

fn account(state: &State) -> El {
    let snapshot = &state.snapshot;
    let mut contents = col()
        .items_start()
        .gap(10.0)
        .px(18.0)
        .py(14.0)
        .child(label(&snapshot.account, 19.0, 700.0, INK))
        .child(label(&snapshot.status, 14.0, 450.0, MUTED));
    if !matches!(snapshot.phase.as_str(), "signedOut" | "unavailable") {
        if state.signout_confirmation {
            contents = contents
                .child(label(
                    "Sign out of Spotify on this device?",
                    14.0,
                    530.0,
                    INK,
                ))
                .child(
                    row()
                        .gap(7.0)
                        .child(control(
                            "confirm-sign-out",
                            "Confirm sign out",
                            button("Sign out", true),
                            true,
                            |s, _| {
                                s.signout_confirmation = false;
                                s.send("logout", None, None);
                            },
                        ))
                        .child(control(
                            "cancel-sign-out",
                            "Cancel",
                            button("Cancel", false),
                            true,
                            |s, _| s.signout_confirmation = false,
                        )),
                );
        } else {
            contents = contents.child(control(
                "sign-out",
                "Sign out",
                button("Sign out", false),
                true,
                |s, _| s.signout_confirmation = true,
            ));
        }
    }
    contents
}
