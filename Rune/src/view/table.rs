use super::{SCROLL, components::*};
use crate::{
    Menu, MenuSource, Sort, State,
    model::{Route, grouped},
};
use rune::{Cursor, El, GrowthSpec, col, el, row};

#[derive(Clone, Copy)]
struct Columns {
    album: bool,
    added: bool,
    artist: bool,
    plays: bool,
    art: bool,
}

impl Columns {
    fn new(state: &State, width: f32) -> Self {
        let kind = state
            .snapshot
            .details
            .as_ref()
            .map(|item| item.kind.as_str());
        let is_playlist = kind == Some("Playlist") || state.route() == &Route::Likes;
        let search = state.route() == &Route::Search;
        Self {
            album: (is_playlist || search) && width >= 590.0,
            added: is_playlist && width >= 740.0,
            artist: search && width >= 660.0,
            plays: matches!(kind, Some("Artist" | "Album"))
                && width >= 670.0
                && state
                    .snapshot
                    .tracks
                    .iter()
                    .any(|track| track.count.is_some()),
            art: kind != Some("Album"),
        }
    }
}

fn align(contents: [El; 7], columns: Columns) -> El {
    let [ordinal, title, artist, album, date, plays, duration] = contents;
    let mut row = row()
        .w_full()
        .px(26.0)
        .gap(15.0)
        .center_y()
        .child(ordinal.w(49.0))
        .child(
            title
                .grow(if columns.artist { 1.65 } else { 2.0 })
                .min_w(0.0),
        );
    if columns.artist {
        row = row.child(artist.grow(0.9).min_w(0.0));
    }
    if columns.album {
        row = row.child(album.grow(1.0).min_w(0.0));
    }
    if columns.added {
        row = row.child(date.grow(1.0).min_w(0.0));
    }
    if columns.plays {
        row = row.child(plays.w(110.0));
    }
    row.child(duration.w(48.0)).child(el().w(3.0))
}

pub fn header(state: &State, width: f32) -> El {
    let sort = |key: &str, title: &str, column: Sort, contents: El| {
        let active = state.table.sort == column;
        let face = row()
            .h(35.0)
            .center_y()
            .gap(6.0)
            .radius(4.0)
            .child(contents);
        let face = if active && column != Sort::Position {
            face.child(label(
                if state.table.descending { "▾" } else { "▴" },
                12.0,
                660.0,
                ACCENT,
            ))
        } else {
            face
        };
        control(
            key,
            format!(
                "Sort by {title}{}",
                if !active {
                    ""
                } else if state.table.descending {
                    ", descending"
                } else {
                    ", ascending"
                }
            ),
            face,
            true,
            move |s, _| s.set_sort(column),
        )
        .role("columnheader")
    };
    let text = |value| label(value, 13.0, 530.0, DATA).min_w(0.0).truncate();
    let ordinal = sort("sort-position", "position", Sort::Position, text("#")).justify_end();
    let title = sort("sort-title", "title", Sort::Title, text("Title"));
    let artist = sort("sort-artist", "artist", Sort::Artist, text("Artist"));
    let album = sort("sort-album", "album", Sort::Album, text("Album"));
    let date = sort("sort-added", "date added", Sort::Added, text("Date added"));
    let plays = sort("sort-plays", "play count", Sort::Plays, text("Plays"));
    let duration = sort(
        "sort-duration",
        "duration",
        Sort::Duration,
        mark("clock", 19.0, DATA),
    )
    .justify_center();
    align(
        [ordinal, title, artist, album, date, plays, duration],
        Columns::new(state, width),
    )
    .key("track-heading")
    .h(36.0)
    .role("row")
    .fill(color(TILE))
    .border_sides([0.0, 0.0, 1.0, 0.0], color(LINE))
}

pub fn tracks(state: &State, width: f32) -> El {
    let columns = Columns::new(state, width);
    col()
        .key("track-list")
        .w_full()
        .role("table")
        .label("Tracks")
        .growth(GrowthSpec::default())
        .virtual_rows(
            state.table.order.len(),
            56.0,
            |s: &State, i| State::row_key(&s.row_at(i).id).into(),
            move |s: &State, i| track_row(s, i, i, columns),
        )
        .virtual_rows_version((state.route().clone(), state.table.version))
        .on_visible_rows(|s: &mut State, range| {
            s.request_row_artwork(range);
            false
        })
}

pub fn release_tracks(state: &State, album: &str, width: f32) -> El {
    let indices: std::rc::Rc<[usize]> = state
        .table
        .order
        .iter()
        .enumerate()
        .filter(|(_, i)| {
            state.snapshot.tracks[**i]
                .album_item
                .as_ref()
                .is_some_and(|item| item.uri == album)
        })
        .map(|(position, _)| position)
        .collect();
    let keys = indices.clone();
    let columns = Columns {
        album: false,
        added: false,
        artist: false,
        plays: width >= 670.0,
        art: false,
    };
    col()
        .growth(GrowthSpec::default())
        .key(format!("release-tracks-{album}"))
        .w_full()
        .role("table")
        .label("Album tracks")
        .virtual_rows(
            indices.len(),
            56.0,
            move |s: &State, n| State::row_key(&s.row_at(keys[n]).id).into(),
            move |s: &State, n| track_row(s, indices[n], n, columns),
        )
        .virtual_rows_version((album.to_owned(), state.table.version))
}

fn track_row(state: &State, index: usize, ordinal_index: usize, columns: Columns) -> El {
    let track = state.row_at(index);
    let now = state.snapshot.playback.uri == track.uri;
    let playing = now && state.snapshot.playback.playing;
    let active = state.snapshot.playback.can_start && (!track.unavailable || playing);
    let selected = state.table.selected.contains(&track.id);
    let preview = state.route() == &Route::Search && state.search_filter == "All";
    let row_key = State::row_key(&track.id);
    let artwork_key = format!("preview-art-{}", track.id);
    let ink = if now && !selected {
        ACCENT
    } else if track.unavailable {
        SOFT
    } else {
        INK
    };
    let id = track.id.clone();
    let ordinal = row().h(40.0).center_y().justify_end().child(if playing {
        mark("speaker", 18.0, ACCENT)
    } else {
        label(
            (ordinal_index + 1).to_string(),
            13.0,
            510.0,
            if now { ACCENT } else { DATA },
        )
    });
    let target = id.clone();
    let stamp = state.snapshot.stamp;
    let title_action = format!("{} {}", if playing { "Pause" } else { "Play" }, track.title);
    let size = if preview { 40.0 } else { 28.0 };
    let play = control(
        if preview {
            artwork_key.clone()
        } else {
            format!("play-track-{index}")
        },
        title_action.clone(),
        icon_button(
            if playing { "pause" } else { "play" },
            size,
            17.0,
            BG,
            if active { INK } else { SOFT },
        ),
        active,
        move |s, _| s.command("playTrack", Some(&target), None, None, stamp),
    )
    .help(title_action)
    .group_opacity(0.0, 1.0);
    let index_button = if preview {
        row().center_y().justify_end().child(
            picture(state, track.artwork.as_deref(), size, size, 4.0)
                .child(play.radius(4.0).tab_index(-1)),
        )
    } else if active {
        ordinal.child(play.absolute(8.0, 5.0))
    } else {
        ordinal
    };
    let mut title = row().gap(12.0).center_y().min_w(0.0);
    if columns.art && !preview {
        title = title.child(picture(state, track.artwork.as_deref(), 40.0, 40.0, 4.0));
    }
    let title_text = matched_label(&track.title, 16.0, 550.0, ink, state)
        .w_full()
        .truncate();
    title = if columns.artist {
        title.child(title_text.grow(1.0))
    } else {
        title.child(
            col()
                .grow(1.0)
                .min_w(0.0)
                .gap(1.0)
                .child(title_text)
                .child(artist_link(
                    state,
                    track,
                    if now && !selected { ACCENT } else { MUTED },
                )),
        )
    };
    let artist = artist_link(state, track, DATA);
    let album_text = matched_label(&track.album, 13.0, 460.0, DATA, state)
        .w_full()
        .truncate();
    let album = if let Some(album) = &track.album_item {
        let uri = album.uri.clone();
        row()
            .min_w(0.0)
            .center_y()
            .child(album_text)
            .cursor(Cursor::Pointer)
            .on_press_tx(move |s: &mut State, tx| s.navigate(Route::Detail(uri.clone()), tx))
    } else {
        album_text
    };
    let date = label(date(&track.added), 13.0, 460.0, DATA)
        .w_full()
        .truncate();
    let plays = label(
        track.count.map(grouped).unwrap_or_default(),
        13.0,
        450.0,
        DATA,
    )
    .w_full()
    .truncate();
    let duration = row().center().child(label(
        time(if columns.added {
            track.duration.round()
        } else {
            track.duration
        }),
        13.0,
        460.0,
        DATA,
    ));
    let selection = if selected && state.window_focused {
        "#454545"
    } else if selected {
        "#343434"
    } else {
        BG
    };
    let menu_id = id.clone();
    let primary = id.clone();
    let focus_id = id.clone();
    let row = align(
        [index_button, title, artist, album, date, plays, duration],
        columns,
    )
    .h(56.0)
    .radius(4.0)
    .fill(color(selection))
    .role("row")
    .label(format!(
        "{}{} · {} · {}",
        ordinal_index + 1,
        if track.unavailable {
            ", Unavailable"
        } else {
            ""
        },
        track.title,
        track.artist
    ))
    .focusable(true)
    .focus_selected(selected)
    .hover_group_focus()
    .focus_ring(1.0, -1.0, color("#737373"))
    .on_key(move |s: &mut State, event, tx| {
        preview
            && active
            && s.table.selected.len() == 1
            && s.table.selected.contains(&focus_id)
            && focus_row_action(event, tx, &row_key, &artwork_key)
            || tx.focused() != Some(artwork_key.as_str()) && crate::keyboard(s, event, tx)
    })
    .on_press_tx(move |s: &mut State, tx| s.select_row(&id, tx.mods()))
    .on_double_press(move |s: &mut State| {
        if s.table.selected.len() == 1 && s.table.selected.contains(&primary) {
            s.primary(MenuSource::Tracks, true);
        }
    })
    .on_secondary_press(move |s: &mut State, point, _| {
        s.context_menu(MenuSource::Tracks, &menu_id, [point.x, point.y])
    });
    if selected {
        row
    } else {
        row.hover(color("#ffffff").alpha(0.10))
    }
}

fn artist_link(state: &State, track: &crate::model::Track, ink: &str) -> El {
    if track.unavailable {
        return label("Unavailable", 14.0, 450.0, SOFT).w_full().truncate();
    }
    if track.artists.is_empty() {
        return matched_label(&track.artist, 14.0, 460.0, ink, state)
            .w_full()
            .truncate();
    }
    let mut names = row().min_w(0.0).gap(4.0).clip_rounded(0.0).center_y();
    for (index, item) in track.artists.iter().enumerate() {
        let uri = item.uri.clone();
        let name = if index + 1 < track.artists.len() {
            format!("{},", item.title)
        } else {
            item.title.clone()
        };
        names = names.child(
            matched_label(&name, 14.0, 460.0, ink, state)
                .truncate()
                .role("link")
                .label(name)
                .cursor(Cursor::Pointer)
                .on_press_tx(move |s: &mut State, tx| s.navigate(Route::Detail(uri.clone()), tx)),
        );
    }
    names
}

fn matched_label(name: &str, size: f32, weight: f32, ink: &str, state: &State) -> El {
    let text = label(name, size, weight, ink);
    let query = state.table.filter.text.trim().to_lowercase();
    if query.is_empty() {
        return text;
    }
    let lower = name.to_lowercase();
    if lower.len() == name.len()
        && let Some(start) = lower.find(&query)
        && name.is_char_boundary(start)
        && name.is_char_boundary(start + query.len())
    {
        text.spans(vec![
            rune::Span::new(start, start + query.len()).bg(color("#383838"), 1.0),
        ])
    } else {
        text
    }
}

fn date(value: &str) -> String {
    let Some(day) = value.get(..10) else {
        return String::new();
    };
    chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d")
        .map(|date| date.format("%b %-d, %Y").to_string())
        .unwrap_or_default()
}

pub fn menu(state: &State, menu: &Menu, size: [f32; 2]) -> El {
    let source = menu.source;
    let x = menu.origin[0].min(size[0] - 283.0).max(8.0);
    let y = menu.origin[1].min(size[1] - 232.0).max(8.0);
    let mut choices = col()
        .gap(2.0)
        .padding(5.0)
        .radius(7.0)
        .fill(color("#282828"))
        .border(1.0, color("#383838"))
        .shadow(6.0, 22.0, color(BLACK).alpha(0.45))
        .absolute(x, y)
        .w(272.0)
        .role("menu")
        .label("Track actions");
    let can_play = state.snapshot.playback.can_start;
    if menu.playlists {
        choices = choices
            .child(menu_row("playlist-menu-back", "Back", true, |s, _| {
                if let Some(menu) = &mut s.menu {
                    menu.playlists = false;
                }
            }))
            .child(line());
        let mut playlists = col().gap(2.0);
        for (index, item) in state.snapshot.edit_targets.iter().enumerate() {
            let uri = item.uri.clone();
            playlists = playlists.child(menu_row(
                format!("add-to-playlist-{index}"),
                &item.title,
                true,
                move |s, _| s.batch("addPlaylist", MenuSource::Tracks, Some(&uri)),
            ));
        }
        choices = choices.child(col().max_h(170.0).scroll(SCROLL).child(playlists));
    } else {
        let single = match source {
            MenuSource::Tracks => state.table.selected.len() == 1,
            MenuSource::Queue => state.queue_selected.len() == 1,
            MenuSource::History => state.history_selected.is_some(),
        };
        choices = choices.child(menu_row(
            "menu-play",
            "Play",
            can_play && single,
            move |s, _| s.primary(source, false),
        ));
        if source == MenuSource::Tracks {
            choices = choices
                .child(menu_row(
                    "menu-restart",
                    "Play from beginning",
                    can_play && single,
                    move |s, _| s.primary(source, true),
                ))
                .child(menu_row(
                    "add-queue",
                    "Add to Queue",
                    can_play && !state.table.selected.is_empty(),
                    |s, _| s.batch("queueTrack", MenuSource::Tracks, None),
                ));
            if !state.snapshot.edit_targets.is_empty() {
                choices = choices.child(menu_row(
                    "playlist-menu",
                    "Add to Playlist ›",
                    !state.table.selected.is_empty(),
                    |s, _| {
                        if let Some(menu) = &mut s.menu {
                            menu.playlists = true;
                        }
                    },
                ));
            }
            if state.snapshot.editable {
                let eligible = state
                    .snapshot
                    .tracks
                    .iter()
                    .filter(|row| state.table.selected.contains(&row.id))
                    .all(|row| row.removable);
                let target = state.snapshot.details.as_ref().map(|item| item.uri.clone());
                choices = choices.child(menu_row(
                    "remove-playlist",
                    "Remove from Playlist",
                    eligible,
                    move |s, _| {
                        s.batch("removePlaylist", MenuSource::Tracks, target.as_deref());
                    },
                ));
            }
        }
        if source == MenuSource::Queue
            && !state.queue_selected.contains("now-playing")
            && !state.queue_selected.is_empty()
            && state
                .snapshot
                .queue
                .iter()
                .filter(|row| state.queue_selected.contains(&row.id))
                .all(|row| row.removable)
        {
            choices = choices.child(menu_row(
                "remove-queue",
                "Remove from Queue",
                true,
                |s, _| s.batch("removeQueue", MenuSource::Queue, None),
            ));
        }
    }
    el().absolute(0.0, 0.0)
        .size(size[0], size[1])
        .child(
            el().w_full()
                .h_full()
                .hit()
                .on_press(|s: &mut State| s.menu = None),
        )
        .child(choices)
}

fn menu_row(
    key: impl Into<String>,
    title: &str,
    enabled: bool,
    action: impl Fn(&mut State, &mut rune::Tx) + 'static,
) -> El {
    let face = row().h(35.0).px(9.0).radius(4.0).center_y().child(
        label(title, 13.0, 520.0, if enabled { INK } else { SOFT })
            .w_full()
            .truncate(),
    );
    control(key, title, face, enabled, action).role("menuitem")
}
