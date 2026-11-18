mod components;
mod player;
mod table;

use crate::{State, model::*};
use components::*;
use rune::tok::TextStyle;
use rune::{Cx, El, Phase, ScrollSpec, col, el, row, text_input};

const SCROLL: ScrollSpec = ScrollSpec {
    stick_bottom: false,
};

pub fn view(state: &State, cx: &mut Cx<State>) -> El {
    cx.foreground(color(INK));
    let inset = cx.titlebar_inset();
    let size = cx.layout_size("window").unwrap_or([1220.0, 780.0]);
    let width = cx
        .layout_size("main-column")
        .map(|r| r[0])
        .unwrap_or(size[0] - state.sidebar_width);
    let middle = col()
        .key("main-column")
        .grow(1.0)
        .min_w(0.0)
        .min_h(0.0)
        .fill(color(BG))
        .child(if state.snapshot.catalog_ready {
            browse(state, width)
        } else {
            connect(state)
        });
    let mut body = row()
        .grow(1.0)
        .min_h(0.0)
        .child(sidebar(state))
        .child(divider(state, false))
        .child(middle);
    if let Some(panel) = state.panel {
        body = body
            .child(divider(state, true))
            .child(player::inspector(state, panel));
    }
    let mut window = col()
        .key("window")
        .w_full()
        .h_full()
        .fill(color(BLACK))
        .on_window_focus(|s: &mut State, active, _| s.window_focused = active)
        .child(toolbar(state, inset, size[0]))
        .child(body)
        .child(player::player(state));
    if let Some(menu) = &state.menu {
        window = window.child(table::menu(state, menu, size));
    }
    if state.show_about {
        window = window.child(about_overlay(state, size));
    }
    window
}

fn toolbar(state: &State, inset: f32, width: f32) -> El {
    let back = state.cursor > 0;
    let forward = state.cursor + 1 < state.history.len();
    let arrows = row()
        .gap(2.0)
        .center_y()
        .absolute(inset.max(14.0) + 10.0, 6.0)
        .child(control(
            "go-back",
            "Go back",
            icon_button(
                "back",
                36.0,
                22.0,
                BLACK,
                if back { MUTED } else { "#535353" },
            ),
            back,
            |s, tx| s.move_history(-1, tx),
        ))
        .child(control(
            "go-forward",
            "Go forward",
            icon_button(
                "forward",
                36.0,
                22.0,
                BLACK,
                if forward { MUTED } else { "#535353" },
            ),
            forward,
            |s, tx| s.move_history(1, tx),
        ));
    let home = control(
        "nav-home",
        "Home",
        icon_button(
            "home",
            48.0,
            25.0,
            TILE,
            if state.route() == &Route::Home {
                INK
            } else {
                MUTED
            },
        ),
        state.snapshot.catalog_ready,
        |s, tx| s.navigate(Route::Home, tx),
    );
    let edit = text_input(&state.query, TextStyle::new(16.0, 450.0))
        .key("global-search")
        .single_line()
        .grow(1.0)
        .min_w(0.0)
        .label("Search")
        .color(color(INK))
        .placeholder("What do you want to play?", color(SOFT))
        .caret(color(INK), color("#555555"))
        .disabled(!state.snapshot.catalog_ready)
        .on_edit(|s: &mut State| &mut s.query)
        .on_input_change(|s: &mut State, tx| s.search(tx))
        .on_submit(|s: &mut State, tx| s.search(tx));
    let mut search = row()
        .key("open-search")
        .size(width.min(1520.0) * 0.30, 48.0)
        .max_w(456.0)
        .min_w(240.0)
        .px(14.0)
        .gap(10.0)
        .center_y()
        .radius(24.0)
        .fill(color(TILE))
        .focus_within_ring(2.0, -2.0, color(INK))
        .child(mark("search", 23.0, MUTED))
        .child(edit);
    if !state.query.text.is_empty() {
        search = search.child(control(
            "clear-search",
            "Clear search",
            icon_button("close", 27.0, 16.0, TILE, MUTED),
            true,
            |s, tx| {
                s.query = rune::TextEdit::new("");
                s.search(tx);
                tx.focus("global-search", false);
            },
        ));
    }
    let toolbar = row()
        .key("toolbar")
        .h(52.0)
        .w_full()
        .center()
        .fill(color(BLACK))
        .window_drag()
        .child(
            row()
                .gap(8.0)
                .center_y()
                .no_window_drag()
                .child(home)
                .child(search),
        )
        .child(arrows.no_window_drag());
    if rune::tooling::is_headless() && !std::env::args_os().any(|arg| arg == "--chrome") {
        toolbar.children(
            ["#ff5f57", "#febc2e", "#28c840"]
                .into_iter()
                .enumerate()
                .map(|(index, fill)| {
                    el().absolute(20.0 + 21.0 * index as f32, 20.0)
                        .size(12.0, 12.0)
                        .radius(6.0)
                        .fill(color(fill))
                        .a11y_hidden()
                }),
        )
    } else {
        toolbar
    }
}

fn divider(state: &State, right: bool) -> El {
    let at = if right {
        state.panel_width
    } else {
        state.sidebar_width
    };
    el().w(if right { 7.0 } else { 8.0 })
        .h_full()
        .cursor(rune::Cursor::ResizeColumn)
        .key(if right {
            "inspector-resize"
        } else {
            "sidebar-resize"
        })
        .fill(color("#161616"))
        .hover(color("#383838"))
        .on_drag(move |s: &mut State, drag, _| {
            if drag.phase != Phase::Down && !drag.cancelled() {
                if right {
                    s.panel_width = (at - drag.dx).clamp(260.0, 360.0);
                } else {
                    s.sidebar_width = (at + drag.dx).clamp(180.0, 260.0);
                }
            }
        })
}

fn sidebar(state: &State) -> El {
    let snapshot = &state.snapshot;
    let heading = row().h(56.0).px(20.0).center_y().gap(6.0).child(
        label("Playlists", 16.0, 700.0, INK)
            .grow(1.0)
            .role("heading")
            .level(2),
    );
    let mut list = col().px(11.0).pb(10.0).w_full();
    let error = snapshot
        .library_error
        .as_ref()
        .or(snapshot.profile_error.as_ref());
    if snapshot.library.is_empty() {
        if snapshot.library_loading {
            list = list.child(label("Loading playlists…", 13.0, 450.0, MUTED).py(10.0));
        } else if let Some(error) = error {
            list = list
                .child(label(error, 13.0, 450.0, MUTED).w_full())
                .child(control(
                    "retry-library",
                    "Try again",
                    button("Try again", false),
                    snapshot.catalog_ready,
                    |s, _| s.send("retryLibrary", None, None),
                ));
        } else if snapshot.library_loaded {
            list = list.child(label("No playlists yet", 13.0, 450.0, MUTED).py(10.0));
        }
    } else {
        if let Some(error) = error {
            list = list
                .child(label(error, 13.0, 450.0, MUTED).w_full())
                .child(control(
                    "retry-library",
                    "Retry library",
                    button("Retry", false),
                    !snapshot.library_loading,
                    |s, _| s.send("retryLibrary", None, None),
                ));
        }
        list = list.children(sidebar_rows(state, &snapshot.library, 0));
    }
    col()
        .key("library-sidebar")
        .w(state.sidebar_width)
        .min_w(180.0)
        .min_h(0.0)
        .fill(color(BG))
        .child(heading)
        .child(el().w(51.0).h(6.0).ml(22.0).radius(3.0).fill(color(TILE)))
        .child(
            col()
                .key("library-scroll")
                .grow(1.0)
                .min_h(0.0)
                .pt(11.0)
                .scroll(SCROLL)
                .child(list.role("list").focus_group()),
        )
}

fn sidebar_rows(state: &State, items: &[Item], depth: usize) -> Vec<El> {
    let mut rows = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let selected = state.route() == &Route::Detail(item.uri.clone());
        let playing_context =
            state.snapshot.playback.context == item.uri && !state.snapshot.playback.uri.is_empty();
        let folder = item.kind == "Folder";
        let expanded = folder && state.collapsed.contains(&item.uri);
        let uri = item.uri.clone();
        let action_key = if folder {
            format!("sidebar-disclosure-{}", item.uri)
        } else {
            format!("sidebar-play-{}", item.uri)
        };
        let mut art = if folder {
            icon_button("folder", 48.0, 25.0, TILE, MUTED).radius(5.0)
        } else {
            picture(state, item.artwork.as_deref(), 48.0, 48.0, 4.0)
        };
        if !folder {
            let pause = playing_context && state.snapshot.playback.playing;
            let enabled = state.snapshot.playback.can_start;
            let artwork_uri = item.uri.clone();
            let artwork_label = format!("{} {}", if pause { "Pause" } else { "Play" }, item.title);
            art = art.child(
                control(
                    action_key.clone(),
                    artwork_label,
                    icon_button(
                        if pause { "pause" } else { "play" },
                        48.0,
                        23.0,
                        "#161616",
                        INK,
                    )
                    .radius(4.0),
                    enabled,
                    move |s, _| s.send("playItem", Some(&artwork_uri), None),
                )
                .tab_index(-1)
                .group_opacity(0.0, 1.0),
            );
        }
        let row = row()
            .h(64.0)
            .pl(12.0 + depth as f32 * 14.0)
            .pr(8.0)
            .gap(12.0)
            .center_y()
            .radius(4.0)
            .fill(color(if selected && state.window_focused {
                "#282828"
            } else if selected {
                "#212121"
            } else {
                BG
            }))
            .child(art)
            .child(
                col()
                    .grow(1.0)
                    .min_w(0.0)
                    .gap(2.0)
                    .child(
                        label(
                            &item.title,
                            16.0,
                            500.0,
                            if playing_context { ACCENT } else { INK },
                        )
                        .w_full()
                        .truncate(),
                    )
                    .child(
                        label(
                            if folder {
                                "Folder"
                            } else if item.subtitle.is_empty() {
                                "Playlist"
                            } else {
                                &item.subtitle
                            },
                            14.0,
                            430.0,
                            MUTED,
                        )
                        .w_full()
                        .truncate(),
                    ),
            );
        let trailing = if folder {
            let folder_uri = uri.clone();
            Some(
                control(
                    action_key.clone(),
                    format!(
                        "{} {}",
                        if expanded { "Collapse" } else { "Expand" },
                        item.title
                    ),
                    icon_button(
                        if expanded { "down" } else { "forward" },
                        22.0,
                        15.0,
                        BG,
                        MUTED,
                    ),
                    true,
                    move |s, _| s.toggle_folder(&folder_uri),
                )
                .tab_index(-1),
            )
        } else if playing_context && !selected {
            Some(mark("speaker", 16.0, ACCENT))
        } else {
            None
        };
        let row = if let Some(trailing) = trailing {
            row.child(trailing)
        } else {
            row
        };
        let key = if depth == 0 {
            format!("shortcut-{index}")
        } else {
            format!("sidebar-{}", item.uri)
        };
        let can_play = state.snapshot.playback.can_start;
        rows.push(
            control(key.clone(), &item.title, row, true, move |s, tx| {
                if folder {
                    s.toggle_folder(&uri);
                } else {
                    s.navigate(Route::Detail(uri.clone()), tx);
                }
            })
            .role("row")
            .focus_selected(selected)
            .hover_group_focus()
            .on_key(move |_: &mut State, event, tx| {
                (folder || selected && can_play) && focus_row_action(event, tx, &key, &action_key)
            }),
        );
        if expanded {
            rows.extend(sidebar_rows(state, &item.children, depth + 1));
        }
    }
    rows
}

fn connect(state: &State) -> El {
    let busy = matches!(
        state.snapshot.phase.as_str(),
        "authorizing" | "connecting" | "recovering"
    );
    let title = if state.snapshot.phase == "unavailable" {
        "Spotty is unavailable"
    } else {
        "Connect Spotify"
    };
    let mut contents = col()
        .center()
        .gap(16.0)
        .child(mark("note", 52.0, INK))
        .child(label(title, 32.0, 750.0, INK))
        .child(label(&state.snapshot.status, 14.0, 470.0, MUTED));
    if !busy && state.snapshot.phase != "unavailable" {
        let title = if state.snapshot.reauthenticate {
            "Sign in again"
        } else {
            "Connect Spotify"
        };
        contents = contents.child(control(
            "connect",
            title,
            button(title, true),
            true,
            |s, _| s.send("connect", None, None),
        ));
    } else if state.snapshot.phase == "authorizing" {
        contents = contents.child(control(
            "cancel-connect",
            "Cancel sign-in",
            button("Cancel", false),
            true,
            |s, _| s.send("cancelConnect", None, None),
        ));
    }
    col().grow(1.0).center().child(contents)
}

fn browse(state: &State, width: f32) -> El {
    let snapshot = &state.snapshot;
    let detail = matches!(state.route(), Route::Detail(_) | Route::Likes);
    let is_artist = snapshot
        .details
        .as_ref()
        .is_some_and(|item| item.kind == "Artist");
    let is_playlist = snapshot
        .details
        .as_ref()
        .is_some_and(|item| item.kind == "Playlist");
    let scroll = state.scroll.clone();
    let mut content = col().w_full();
    if detail {
        content = content
            .child(hero(state, width))
            .child(actions(state, is_playlist));
        if state.compact {
            content = content.child(compact_header(state).absolute(0.0, 0.0).sticky_top(0.0));
        }
    } else {
        content = content.child(
            label(&snapshot.title, 32.0, 740.0, INK)
                .role("heading")
                .level(1)
                .px(26.0)
                .pt(24.0)
                .pb(12.0),
        );
        if state.route() == &Route::Home {
            content = content.child(quick_access(state, width));
        }
        if state.route() == &Route::Search {
            content = content.child(search_filters(state));
        }
        if matches!(state.route(), Route::Discography(_)) {
            content = content.child(release_filters(state, true));
        }
    }
    let search = state.route() == &Route::Search;
    let errors: Vec<_> = snapshot
        .search_errors
        .iter()
        .filter(|(category, _)| {
            state.search_filter == "All" || state.search_filter == category.as_str()
        })
        .map(|(category, reason)| format!("{category}: {reason}"))
        .collect();
    let partial_error = (!errors.is_empty()).then(|| errors.join(" "));
    if let Some(error) = snapshot.error.as_ref().or(partial_error.as_ref()) {
        content = content.child(
            row()
                .center_y()
                .gap(12.0)
                .px(26.0)
                .py(16.0)
                .child(label(error, 14.0, 460.0, MUTED))
                .child(control(
                    "retry",
                    "Try again",
                    button("Try again", false),
                    snapshot.catalog_ready && !snapshot.loading,
                    |s, _| s.send("retry", None, None),
                )),
        );
    } else if snapshot.loading {
        content = content.child(label("Loading…", 14.0, 450.0, MUTED).px(26.0).py(12.0));
    } else if snapshot.cached {
        content = content.child(
            label("Showing saved results", 13.0, 450.0, MUTED)
                .px(26.0)
                .py(9.0),
        );
    }
    if state.route() == &Route::Search && state.query.text.trim().is_empty() {
        content = content.child(
            label(
                "Search for songs, albums, artists or playlists.",
                15.0,
                460.0,
                MUTED,
            )
            .px(26.0),
        );
    }
    let show_songs = !matches!(state.route(), Route::Discography(_))
        && (!search || matches!(state.search_filter, "All" | "Songs"));
    if show_songs && !state.table.order.is_empty() {
        if is_artist || state.route() == &Route::Search {
            content = content.child(
                label(
                    if is_artist { "Popular" } else { "Songs" },
                    24.0,
                    740.0,
                    INK,
                )
                .px(26.0)
                .py(12.0)
                .role("heading")
                .level(2),
            );
        }
        if search && state.search_filter == "All" && snapshot.tracks.len() > 4 {
            content = content.child(row().px(26.0).child(show_search("Songs")));
        }
        let sticky_top = if state.compact { 64.0 } else { 0.0 };
        if !search || state.search_filter != "All" {
            content = content.child(table::header(state, width).sticky_top(sticky_top));
        }
        content = content.child(table::tracks(state, width));
        if is_artist && snapshot.tracks.len() > 5 {
            let title = if state.artist_controls.expanded {
                "Show less"
            } else {
                "See more"
            };
            content = content.child(row().px(26.0).py(14.0).child(control(
                "expand-popular",
                title,
                button(title, false),
                true,
                |s, _| {
                    s.artist_controls.expanded = !s.artist_controls.expanded;
                    s.order();
                },
            )));
        }
    } else if !snapshot.loading
        && snapshot.error.is_none()
        && partial_error.is_none()
        && (detail
            || search
                && !state.query.text.trim().is_empty()
                && match state.search_filter {
                    "All" => snapshot
                        .sections
                        .iter()
                        .all(|section| section.items.is_empty()),
                    "Songs" => true,
                    filter => snapshot
                        .sections
                        .iter()
                        .all(|section| section.title != filter || section.items.is_empty()),
                })
    {
        let message = if search {
            match state.search_filter {
                "Artists" => "No artists found",
                "Albums" => "No albums found",
                "Songs" => "No songs found",
                "Playlists" => "No playlists found",
                _ => "No results found",
            }
        } else if !state.table.filter.text.is_empty() {
            "No results found"
        } else if state.route() == &Route::Likes {
            "No liked songs yet"
        } else {
            "No songs in this collection"
        };
        content = content.child(label(message, 15.0, 480.0, MUTED).px(26.0).py(16.0));
    }
    for (index, section) in snapshot.sections.iter().enumerate() {
        if section.items.is_empty()
            || search && state.search_filter != "All" && section.title != state.search_filter
        {
            continue;
        }
        if is_artist && section.title == "Discography" {
            content = content.child(release_filters(state, false));
        }
        content = content.child(shelf(state, section, index, width));
    }
    if is_artist && let Some(bio) = &snapshot.artist_about {
        content = content.child(
            col()
                .gap(12.0)
                .px(26.0)
                .py(14.0)
                .child(label("About", 24.0, 740.0, INK).role("heading").level(2))
                .child(control(
                    "show-about",
                    "Read biography",
                    col()
                        .w_full()
                        .max_w(640.0)
                        .padding(24.0)
                        .gap(8.0)
                        .radius(8.0)
                        .fill(color(TILE))
                        .child(label(&snapshot.subtitle, 15.0, 650.0, INK))
                        .child(label(
                            bio.chars().take(180).collect::<String>(),
                            15.0,
                            460.0,
                            MUTED,
                        )),
                    true,
                    |s, _| s.show_about = true,
                )),
        );
    }
    col()
        .key("main-scroll")
        .grow(1.0)
        .min_h(0.0)
        .scroll(SCROLL)
        .on_scroll_offset(move |pos| scroll.set(pos.offset[1]))
        .child(content.pb(30.0))
}

fn hero(state: &State, width: f32) -> El {
    let snapshot = &state.snapshot;
    let item = snapshot.details.as_ref();
    let kind = item
        .map(|item| item.kind.as_str())
        .unwrap_or(if state.route() == &Route::Likes {
            "Playlist"
        } else {
            ""
        });
    let art_size = if width >= 1000.0 {
        232.0
    } else if width >= 600.0 {
        192.0
    } else {
        (width * 0.30).clamp(128.0, 192.0)
    };
    let font_size = if width >= 840.0 {
        96.0
    } else if width >= 650.0 {
        68.0
    } else {
        46.0
    };
    let title = if snapshot.title.is_empty() {
        kind
    } else {
        &snapshot.title
    };
    let text_width = (width - art_size - 110.0).max(200.0);
    let longest = title
        .split_whitespace()
        .map(|word| word.chars().count())
        .max()
        .unwrap_or(1);
    let font_size = f32::min(font_size, text_width / (longest as f32 * 0.59)).max(30.0);
    let count = state.table.order.len();
    let total: f64 = state
        .table
        .order
        .iter()
        .map(|index| snapshot.tracks[*index].duration.round())
        .sum();
    let mut info = Vec::new();
    if !snapshot.subtitle.is_empty() {
        info.push(snapshot.subtitle.clone());
    }
    if kind == "Album"
        && let Some(item) = item
        && let Some(year) = item.date.split('-').next().filter(|s| !s.is_empty())
    {
        info.push(year.into());
    }
    if count > 0 && kind != "Artist" {
        info.push(format!(
            "{} {}",
            count,
            if count == 1 { "song" } else { "songs" }
        ));
        info.push(duration(total));
    }
    let mut copy = col()
        .grow(1.0)
        .min_w(0.0)
        .gap(6.0)
        .items_start()
        .child(label(kind, 14.0, 470.0, MUTED))
        .child(
            label(title, font_size, 900.0, INK)
                .font(TextStyle {
                    line_height: font_size * 1.04,
                    tracking: -font_size * 0.025,
                    ..TextStyle::new(font_size, 900.0)
                })
                .role("heading")
                .level(1)
                .w_full()
                .truncate(),
        );
    if !snapshot.description.is_empty() {
        copy = copy.child(
            label(&snapshot.description, 14.0, 470.0, MUTED)
                .pt(8.0)
                .w_full()
                .truncate(),
        );
    }
    if !info.is_empty() {
        copy = copy.child(
            label(info.join(" · "), 14.0, 500.0, MUTED)
                .w_full()
                .truncate(),
        );
    }
    let tint = snapshot
        .artwork
        .as_ref()
        .and_then(|url| state.artwork_tints.get(url))
        .map(|[r, g, b]| color(&format!("#{r:02x}{g:02x}{b:02x}")))
        .unwrap_or_else(|| color("#1c2630"));
    let art = picture(state, snapshot.artwork.as_deref(), art_size, art_size, 6.0).shadow(
        6.0,
        28.0,
        color(BLACK).alpha(0.55),
    );
    row()
        .key("playlist-hero")
        .w_full()
        .px(27.0)
        .pt(64.0)
        .pb(24.0)
        .gap(24.0)
        .items_end()
        .linear_gradient(
            std::f32::consts::FRAC_PI_2,
            &[(0.0, tint), (1.0, color("#151515"))],
        )
        .child(art)
        .child(copy)
}

fn actions(state: &State, playlist: bool) -> El {
    let enabled = state.snapshot.playback.can_start;
    let item = state.snapshot.details.as_ref();
    let uri = item.map(|item| item.uri.clone()).unwrap_or_default();
    let playing = uri == state.snapshot.playback.context && state.snapshot.playback.playing;
    let play = control(
        "play-context",
        if playing { "Pause" } else { "Play" },
        icon_button(
            if playing { "pause" } else { "play" },
            56.0,
            31.0,
            ACCENT,
            BLACK,
        ),
        enabled && state.snapshot.context_playable,
        move |s, _| {
            if playing {
                s.send("toggle", None, None);
            } else {
                s.send("playContext", Some(&uri), None);
            }
        },
    );
    let shuffle = control(
        "context-shuffle",
        if state.snapshot.playback.shuffle {
            "Shuffle on"
        } else {
            "Shuffle off"
        },
        icon_button(
            "shuffle",
            41.0,
            28.0,
            BG,
            if state.snapshot.playback.shuffle {
                ACCENT
            } else {
                MUTED
            },
        ),
        enabled,
        |s, _| s.send("shuffle", None, None),
    );
    let mut bar = row()
        .key("playlist-actions")
        .w_full()
        .h(96.0)
        .px(27.0)
        .gap(17.0)
        .center_y()
        .fill(color(BG))
        .on_layout_tx(|s: &mut State, rect, tx| {
            let compact = rect[1] + rect[3] < 54.0;
            if s.compact == compact {
                tx.live_only();
            } else {
                s.compact = compact;
            }
        })
        .child(play)
        .child(shuffle)
        .child(el().grow(1.0));
    if playlist && state.table.filtering {
        let edit = text_input(&state.table.filter, TextStyle::new(14.0, 450.0))
            .key("playlist-filter")
            .single_line()
            .grow(1.0)
            .label("Find in playlist")
            .placeholder("Find in playlist", color(MUTED))
            .caret(color(INK), color("#555555"))
            .on_edit(|s: &mut State| &mut s.table.filter)
            .on_input_change(|s: &mut State, _| s.order())
            .on_input_key(|s: &mut State, key, tx| {
                if key.key != rune::Key::Escape {
                    return false;
                }
                if s.table.filter.text.is_empty() {
                    s.table.filtering = false;
                    tx.blur();
                } else {
                    s.table.filter = rune::TextEdit::new("");
                    s.order();
                    tx.focus("playlist-filter", false);
                }
                true
            });
        bar = bar.child(
            row()
                .size(225.0, 36.0)
                .px(9.0)
                .gap(6.0)
                .center_y()
                .radius(4.0)
                .fill(color(TILE))
                .child(mark("search", 16.0, MUTED))
                .child(edit)
                .child(control(
                    "clear-playlist-filter",
                    "Clear playlist search",
                    icon_button("close", 25.0, 16.0, TILE, MUTED),
                    true,
                    |s, tx| {
                        s.table.filter = rune::TextEdit::new("");
                        s.order();
                        tx.focus("playlist-filter", false);
                    },
                )),
        );
    } else if playlist {
        bar = bar.child(control(
            "filter-playlist",
            "Find in playlist",
            icon_button("search", 36.0, 19.0, BG, MUTED),
            true,
            |s, tx| {
                s.table.filtering = true;
                tx.focus("playlist-filter", false);
            },
        ));
    }
    bar
}

fn compact_header(state: &State) -> El {
    let title = &state.snapshot.title;
    let uri = state
        .snapshot
        .details
        .as_ref()
        .map(|item| item.uri.clone())
        .unwrap_or_default();
    let playing = uri == state.snapshot.playback.context && state.snapshot.playback.playing;
    row()
        .w_full()
        .h(64.0)
        .px(26.0)
        .center_y()
        .gap(14.0)
        .fill(color("#1d2329"))
        .child(control(
            "compact-play",
            if playing { "Pause" } else { "Play" },
            icon_button(
                if playing { "pause" } else { "play" },
                40.0,
                22.0,
                ACCENT,
                BLACK,
            ),
            state.snapshot.playback.can_start && state.snapshot.context_playable,
            move |s, _| {
                if playing {
                    s.send("toggle", None, None);
                } else {
                    s.send("playContext", Some(&uri), None);
                }
            },
        ))
        .child(label(title, 24.0, 750.0, INK).grow(1.0).truncate())
}

fn open_item(state: &mut State, item: &Item, tx: &mut rune::Tx) {
    if item.kind == "Track" {
        state.send("playItem", Some(&item.uri), None);
    } else {
        state.navigate(Route::Detail(item.uri.clone()), tx);
    }
}

fn quick_access(state: &State, width: f32) -> El {
    let grid = if width >= 900.0 {
        4
    } else if width >= 570.0 {
        3
    } else {
        2
    };
    let items = state
        .snapshot
        .sections
        .first()
        .map(|s| s.items.iter().take(8).collect::<Vec<_>>())
        .unwrap_or_default();
    let links = row()
        .gap(8.0)
        .center_y()
        .child(control(
            "open-liked",
            "Liked Songs",
            button("Liked Songs", false),
            true,
            |s, tx| s.navigate(Route::Likes, tx),
        ))
        .child(control(
            "open-library",
            "Saved Albums and Artists",
            button("Albums and artists", false),
            true,
            |s, tx| s.navigate(Route::Library, tx),
        ));
    col()
        .w_full()
        .px(26.0)
        .gap(8.0)
        .pb(12.0)
        .child(links)
        .children(items.chunks(grid).enumerate().map(|(r, cards)| {
            row()
                .gap(8.0)
                .children(cards.iter().enumerate().map(|(n, item)| {
                    let item = *item;
                    let face = row()
                        .grow(1.0)
                        .min_w(0.0)
                        .h(56.0)
                        .center_y()
                        .gap(10.0)
                        .radius(4.0)
                        .clip_rounded(4.0)
                        .fill(color("#282828"))
                        .child(picture(state, item.artwork.as_deref(), 56.0, 56.0, 4.0))
                        .child(
                            label(&item.title, 14.0, 680.0, INK)
                                .grow(1.0)
                                .min_w(0.0)
                                .truncate(),
                        );
                    let key = format!("quick-{r}-{n}");
                    let navigation = item.clone();
                    row()
                        .grow(1.0)
                        .min_w(0.0)
                        .hover_group_focus()
                        .child(control(
                            key.clone(),
                            item.title.clone(),
                            face,
                            true,
                            move |s, tx| open_item(s, &navigation, tx),
                        ))
                        .child(card_play(state, item, &key, 40.0).absolute(8.0, 8.0))
                }))
        }))
}

const SEARCH_FILTERS: [&str; 5] = ["All", "Artists", "Songs", "Albums", "Playlists"];

fn search_filters(state: &State) -> El {
    row()
        .px(26.0)
        .py(8.0)
        .gap(8.0)
        .children(SEARCH_FILTERS.map(|filter| {
            let active = filter == state.search_filter;
            let chip = row()
                .h(32.0)
                .px(14.0)
                .center()
                .radius(16.0)
                .fill(color(if active { INK } else { TILE }))
                .child(label(filter, 14.0, 590.0, if active { BG } else { INK }));
            control(
                format!("search-{filter}"),
                filter,
                chip,
                true,
                move |s, tx| s.filter_search(filter, tx),
            )
            .role("tab")
            .focus_selected(active)
        }))
}

fn show_search(filter: &'static str) -> El {
    control(
        format!("show-search-{filter}"),
        format!("Show all {filter}"),
        button("Show all", false),
        true,
        move |s, tx| s.filter_search(filter, tx),
    )
}

fn shelf(state: &State, section: &Section, index: usize, width: f32) -> El {
    let mut items = section
        .items
        .iter()
        .filter(|item| {
            state.artist_controls.kind.is_empty()
                || section.title != "Discography" && !matches!(state.route(), Route::Discography(_))
                || item
                    .category
                    .eq_ignore_ascii_case(&state.artist_controls.kind)
                || state.artist_controls.kind == "SINGLE"
                    && item.category.eq_ignore_ascii_case("EP")
        })
        .collect::<Vec<_>>();
    let discography = matches!(state.route(), Route::Discography(_));
    if discography {
        if state.artist_controls.sort_name {
            items.sort_by_cached_key(|item| item.title.to_lowercase());
        } else {
            items.sort_by(|a, b| b.date.cmp(&a.date));
        }
    }
    let mut heading = row().center_y().justify_between();
    if !section.title.is_empty() {
        heading = heading.child(
            label(&section.title, 24.0, 740.0, INK)
                .role("heading")
                .level(2),
        );
    }
    let preview = state.route() == &Route::Search && state.search_filter == "All";
    if preview
        && let Some(filter) = SEARCH_FILTERS
            .into_iter()
            .find(|filter| *filter == section.title)
    {
        heading = heading.child(show_search(filter));
        items.truncate(6);
    }
    if section.title == "Discography"
        && let Route::Detail(uri) = state.route()
    {
        let uri = uri.clone();
        heading = heading.child(control(
            "show-discography",
            "Show all releases",
            button("Show all", false),
            true,
            move |s, tx| s.navigate(Route::Discography(uri.clone()), tx),
        ));
    }
    let mut contents = col().w_full().px(26.0).py(10.0).gap(7.0).child(heading);
    if discography && state.artist_controls.list {
        contents = contents.children(items.iter().enumerate().map(|(n, item)| {
            let item = (*item).clone();
            let face = row()
                .h(62.0)
                .padding(6.0)
                .gap(11.0)
                .center_y()
                .radius(4.0)
                .child(picture(state, item.artwork.as_deref(), 48.0, 48.0, 4.0))
                .child(label(&item.title, 16.0, 660.0, INK).grow(1.0).truncate())
                .child(label(&item.date, 14.0, 450.0, MUTED).w(94.0));
            let uri = item.uri.clone();
            let open = item.clone();
            let play = uri.clone();
            let header = row()
                .w_full()
                .px(10.0)
                .center_y()
                .child(
                    control(
                        format!("card-{index}-{n}"),
                        item.title.clone(),
                        face.grow(1.0),
                        true,
                        move |s, tx| open_item(s, &open, tx),
                    )
                    .grow(1.0),
                )
                .child(control(
                    format!("play-release-{n}"),
                    format!("Play {}", item.title),
                    icon_button("play", 40.0, 18.0, TILE, INK),
                    state.snapshot.playback.can_start,
                    move |s, _| s.send("playItem", Some(&play), None),
                ));
            let mut group = col().w_full().child(header);
            match state.snapshot.release_loads.get(&uri) {
                Some(crate::model::ReleaseLoad::Ready) => {
                    group = group.child(table::release_tracks(state, &uri, width));
                }
                Some(crate::model::ReleaseLoad::Failed(reason)) => {
                    let album = uri.clone();
                    group = group.child(
                        row()
                            .gap(8.0)
                            .child(label(reason, 14.0, 450.0, MUTED))
                            .child(control(
                                format!("retry-{uri}"),
                                "Try again",
                                button("Try again", false),
                                state.snapshot.catalog_ready,
                                move |s, _| s.send("retryRelease", Some(&album), None),
                            )),
                    );
                }
                _ => {
                    group = group.child(
                        label("Loading tracks…", 14.0, 450.0, MUTED)
                            .px(14.0)
                            .py(8.0),
                    );
                }
            }
            group
                .key(format!("release-{uri}"))
                .on_visible(move |s: &mut State, visible, _| {
                    if visible && !s.snapshot.release_loads.contains_key(&uri) {
                        s.send("releaseTracks", Some(&uri), None);
                    }
                })
        }));
    } else if discography
        || state.route() == &Route::Search && !preview
        || state.route() == &Route::Library
    {
        let columns = ((width - 52.0) / 173.0).floor().clamp(2.0, 8.0) as usize;
        contents = contents.children(items.chunks(columns).enumerate().map(|(r, items)| {
            row().gap(6.0).children(
                items
                    .iter()
                    .enumerate()
                    .map(|(n, item)| card(state, item, index, r * columns + n)),
            )
        }));
    } else {
        contents = contents.child(
            row().scroll_x().w_full().child(
                row().gap(8.0).children(
                    items
                        .iter()
                        .enumerate()
                        .map(|(n, item)| card(state, item, index, n)),
                ),
            ),
        );
    }
    contents
}

fn card_play(state: &State, item: &Item, key: &str, size: f32) -> El {
    let playback = &state.snapshot.playback;
    let current = if item.kind == "Track" {
        &playback.uri
    } else {
        &playback.context
    };
    let pause = playback.playing && current == &item.uri;
    let title = format!("{} {}", if pause { "Pause" } else { "Play" }, item.title);
    let uri = item.uri.clone();
    let stamp = state.snapshot.stamp;
    control(
        format!("{key}-play"),
        title.clone(),
        icon_button(
            if pause { "pause" } else { "play" },
            size,
            size * 0.5,
            if playback.can_start || state.snapshot.phase == "ready" {
                ACCENT
            } else {
                SOFT
            },
            BLACK,
        ),
        playback.can_start,
        move |s, _| s.command("playItem", Some(&uri), None, None, stamp),
    )
    .help(title)
    .group_opacity(0.0, 1.0)
}

fn card(state: &State, item: &Item, section: usize, index: usize) -> El {
    let secondary = if !item.description.is_empty() && state.route() == &Route::Home {
        &item.description
    } else {
        &item.subtitle
    };
    let face = col()
        .w(176.0)
        .padding(8.0)
        .gap(8.0)
        .radius(6.0)
        .child(picture(
            state,
            item.artwork.as_deref(),
            160.0,
            160.0,
            if item.kind == "Artist" { 80.0 } else { 6.0 },
        ))
        .child(label(&item.title, 16.0, 680.0, INK).w_full().truncate())
        .child(label(secondary, 14.0, 430.0, MUTED).w_full().truncate());
    let key = format!("card-{section}-{index}");
    let navigation = item.clone();
    col()
        .w(176.0)
        .hover_group_focus()
        .child(control(
            key.clone(),
            item.title.clone(),
            face,
            true,
            move |s, tx| open_item(s, &navigation, tx),
        ))
        .child(card_play(state, item, &key, 48.0).absolute(116.0, 116.0))
}

fn release_filters(state: &State, mode: bool) -> El {
    let mut filters = row().px(26.0).py(8.0).gap(7.0).center_y();
    for (name, value) in [
        ("All", ""),
        ("Albums", "ALBUM"),
        ("Singles & EPs", "SINGLE"),
        ("Compilations", "COMPILATION"),
    ] {
        filters = filters.child(control(
            format!("releases-{value}"),
            name,
            button(name, state.artist_controls.kind == value),
            true,
            move |s, _| {
                s.artist_controls.kind = value.into();
            },
        ));
    }
    if mode {
        let sort = if state.artist_controls.sort_name {
            "Sort: Name"
        } else {
            "Sort: Release date"
        };
        filters = filters.child(control(
            "release-sort",
            sort,
            button(sort, false),
            true,
            |s, tx| {
                s.artist_controls.sort_name = !s.artist_controls.sort_name;
                tx.scroll_to_instant("main-scroll", 0.0, 0.0);
            },
        ));
        let title = if state.artist_controls.list {
            "Grid view"
        } else {
            "List view"
        };
        filters = filters.child(el().grow(1.0)).child(control(
            "release-layout",
            title,
            button(title, false),
            true,
            |s, _| s.artist_controls.list = !s.artist_controls.list,
        ));
    }
    filters
}

fn about_overlay(state: &State, size: [f32; 2]) -> El {
    let about = state.snapshot.artist_about.as_deref().unwrap_or_default();
    col()
        .absolute(0.0, 0.0)
        .size(size[0], size[1])
        .center()
        .fill(color(BLACK).alpha(0.68))
        .child(
            col()
                .w(size[0].min(660.0) - 32.0)
                .max_h(size[1] - 74.0)
                .padding(24.0)
                .gap(12.0)
                .radius(9.0)
                .fill(color(TILE))
                .role("dialog")
                .label("About the artist")
                .child(
                    row()
                        .center_y()
                        .justify_between()
                        .child(label(&state.snapshot.title, 24.0, 750.0, INK))
                        .child(control(
                            "close-about",
                            "Close biography",
                            icon_button("close", 32.0, 18.0, TILE, MUTED),
                            true,
                            |s, _| s.show_about = false,
                        )),
                )
                .child(label(&state.snapshot.subtitle, 14.0, 500.0, MUTED))
                .child(
                    col()
                        .grow(1.0)
                        .min_h(100.0)
                        .scroll(SCROLL)
                        .child(label(about, 16.0, 450.0, INK).w_full().wrap()),
                ),
        )
}
