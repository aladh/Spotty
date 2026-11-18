mod demo;
mod live;
mod menu;
mod model;
mod playback;
#[cfg(target_os = "macos")]
mod updater;
mod view;

use model::*;
use rune::{App, AppSpec, Chrome, ImageCache, Key, KeyEvent, Mods, Pixels, TextEdit, Tx, Waker};
use std::{
    cell::Cell,
    collections::{HashMap, HashSet},
    rc::Rc,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, PartialEq)]
enum Panel {
    Queue,
    Devices,
    Account,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Sort {
    Position,
    Title,
    Artist,
    Album,
    Added,
    Duration,
    Plays,
}

#[derive(Clone)]
struct Table {
    order: Vec<usize>,
    selected: HashSet<String>,
    anchor: Option<String>,
    cursor: Option<String>,
    filter: TextEdit,
    filtering: bool,
    sort: Sort,
    descending: bool,
    version: u64,
}

impl Default for Table {
    fn default() -> Self {
        Self {
            order: Vec::new(),
            selected: HashSet::new(),
            anchor: None,
            cursor: None,
            filter: TextEdit::new(""),
            filtering: false,
            sort: Sort::Position,
            descending: false,
            version: 0,
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum MenuSource {
    Tracks,
    Queue,
    History,
}

struct Menu {
    source: MenuSource,
    origin: [f32; 2],
    playlists: bool,
}

enum Backend {
    Demo(Box<demo::Demo>),
    Starting,
    Live(live::Live),
}

#[derive(Clone, Default)]
struct ArtistControls {
    kind: String,
    list: bool,
    sort_name: bool,
    expanded: bool,
}

#[derive(Default)]
struct ArtworkRequests {
    pending: HashSet<String>,
    failed: HashMap<String, Instant>,
}

impl ArtworkRequests {
    const RETRY_DELAY: Duration = Duration::from_secs(30);

    fn start(&mut self, url: &str, now: Instant) -> bool {
        if self.pending.contains(url)
            || self
                .failed
                .get(url)
                .is_some_and(|failure| now.duration_since(*failure) < Self::RETRY_DELAY)
        {
            return false;
        }
        self.failed.remove(url);
        self.pending.insert(url.to_owned())
    }

    fn finish(&mut self, url: &str, succeeded: bool, now: Instant) {
        self.pending.remove(url);
        if !succeeded {
            if self.failed.len() >= 160
                && let Some(old) = self
                    .failed
                    .iter()
                    .min_by_key(|(_, time)| **time)
                    .map(|(url, _)| url.clone())
            {
                self.failed.remove(&old);
            }
            self.failed.insert(url.to_owned(), now);
        }
    }

    fn expire(&mut self, now: Instant) -> bool {
        let before = self.failed.len();
        self.failed
            .retain(|_, failure| now < *failure + Self::RETRY_DELAY);
        self.failed.len() < before
    }

    fn next_retry(&self) -> Option<Instant> {
        self.failed
            .values()
            .min()
            .map(|failure| *failure + Self::RETRY_DELAY)
    }
}

struct HistoryEntry {
    route: Route,
    search: String,
}

impl From<Route> for HistoryEntry {
    fn from(route: Route) -> Self {
        Self {
            route,
            search: String::new(),
        }
    }
}

struct State {
    menus: menu::Menus,
    backend: Backend,
    snapshot: Snapshot,
    history: Vec<HistoryEntry>,
    cursor: usize,
    pending_link: Option<String>,
    query: TextEdit,
    search_filter: &'static str,
    last_query: String,
    panel: Option<Panel>,
    history_tab: bool,
    queue_selected: HashSet<String>,
    queue_anchor: Option<String>,
    history_selected: Option<String>,
    table: Table,
    retained: HashMap<Route, (Table, f32, ArtistControls)>,
    scroll: Rc<Cell<f32>>,
    compact: bool,
    sidebar_width: f32,
    panel_width: f32,
    collapsed: HashSet<String>,
    menu: Option<Menu>,
    signout_confirmation: bool,
    show_about: bool,
    artist_controls: ArtistControls,
    window_focused: bool,
    artwork: HashMap<String, Pixels>,
    artwork_requests: ArtworkRequests,
    artwork_rows: Option<std::ops::Range<usize>>,
    artwork_tints: HashMap<String, [u8; 3]>,
    artwork_order: std::collections::VecDeque<String>,
    seek_preview: Option<f64>,
    #[cfg(target_os = "macos")]
    media: Option<live::Media>,
    #[cfg(target_os = "macos")]
    updater: Option<updater::Updater>,
    #[cfg(target_os = "macos")]
    power: Option<live::PowerObserver>,
}

impl State {
    fn new() -> Self {
        let demo =
            rune::tooling::is_headless() || rune::extra_args().iter().any(|arg| arg == "--demo");
        Self::with_backend(if demo {
            Backend::Demo(Box::new(demo::Demo::new()))
        } else {
            Backend::Starting
        })
    }

    fn with_backend(backend: Backend) -> Self {
        let mut state = Self {
            menus: menu::Menus::default(),
            backend,
            snapshot: Snapshot {
                phase: "connecting".into(),
                status: "Restoring your Spotify session…".into(),
                ..Snapshot::default()
            },
            history: vec![Route::Home.into()],
            cursor: 0,
            pending_link: None,
            query: TextEdit::new(""),
            search_filter: "All",
            last_query: String::new(),
            panel: None,
            history_tab: false,
            queue_selected: HashSet::new(),
            queue_anchor: None,
            history_selected: None,
            table: Table::default(),
            retained: HashMap::new(),
            scroll: Rc::new(Cell::new(0.0)),
            compact: false,
            sidebar_width: 208.0,
            panel_width: 280.0,
            collapsed: HashSet::new(),
            menu: None,
            signout_confirmation: false,
            show_about: false,
            artist_controls: ArtistControls::default(),
            window_focused: true,
            artwork: HashMap::new(),
            artwork_requests: ArtworkRequests::default(),
            artwork_rows: None,
            artwork_tints: HashMap::new(),
            artwork_order: std::collections::VecDeque::new(),
            seek_preview: None,
            #[cfg(target_os = "macos")]
            media: None,
            #[cfg(target_os = "macos")]
            updater: None,
            #[cfg(target_os = "macos")]
            power: None,
        };
        state.refresh();
        state
    }

    fn route(&self) -> &Route {
        &self.history[self.cursor].route
    }

    fn is_demo(&self) -> bool {
        matches!(self.backend, Backend::Demo(_))
    }

    fn refresh(&mut self) -> bool {
        let (next, artwork, timing) = match &self.backend {
            Backend::Demo(demo) => (
                Some(demo.snapshot(self.route(), &self.query.text)),
                Vec::new(),
                None,
            ),
            Backend::Live(worker) => {
                let updates = worker.updates();
                (updates.snapshot, updates.artwork, updates.timing)
            }
            Backend::Starting => (None, Vec::new(), None),
        };
        let mut changed = false;
        if let Some(next) = next {
            if next.stamp.account != self.snapshot.stamp.account {
                self.history.truncate(1);
                self.cursor = 0;
                self.query = TextEdit::new("");
                self.search_filter = "All";
                self.last_query.clear();
                self.table = Table::default();
                self.retained.clear();
                self.queue_selected.clear();
                self.queue_anchor = None;
                self.history_selected = None;
                self.collapsed.clear();
                self.menu = None;
                self.signout_confirmation = false;
                if !self.is_demo() {
                    self.artwork.clear();
                    self.artwork_requests = ArtworkRequests::default();
                    self.artwork_rows = None;
                    self.artwork_tints.clear();
                    self.artwork_order.clear();
                }
            }
            if self.snapshot.playback.uri != next.playback.uri
                || self.snapshot.stamp.engine != next.stamp.engine
            {
                self.seek_preview = None;
            }
            let tracks_changed = self.snapshot.stamp.playlist != next.stamp.playlist
                || (self.is_demo() && self.snapshot.tracks != next.tracks);
            self.queue_selected.retain(|id| {
                id == "now-playing" && !next.playback.uri.is_empty()
                    || next.queue.iter().any(|track| &track.id == id)
            });
            if self
                .history_selected
                .as_ref()
                .is_some_and(|id| !next.history.iter().any(|track| &track.id == id))
            {
                self.history_selected = None;
            }
            changed = self.snapshot != next;
            self.snapshot = next;
            if tracks_changed {
                self.order();
            }
        }
        if let Some((account, uri, position)) = timing
            && account == self.snapshot.stamp.account
            && uri == self.snapshot.playback.uri
            && self.snapshot.playback.position != position
        {
            self.snapshot.playback.position = position;
            changed = true;
        }
        for (account, url, bytes) in artwork {
            if account == self.snapshot.stamp.account {
                self.artwork_requests
                    .finish(&url, bytes.is_some(), Instant::now());
                if let Some(artwork) = bytes {
                    #[cfg(target_os = "macos")]
                    if let Some(media) = &mut self.media {
                        media.artwork(&self.snapshot, &url, &artwork);
                    }
                    let pixels = Pixels::new();
                    pixels.set(artwork.width, artwork.height, artwork.rgba);
                    self.artwork.insert(url.clone(), pixels);
                    self.artwork_tints.insert(url.clone(), artwork.tint);
                    self.artwork_order.push_back(url);
                    if self.artwork_order.len() > 160
                        && let Some(old) = self.artwork_order.pop_front()
                    {
                        self.artwork.remove(&old);
                        self.artwork_tints.remove(&old);
                    }
                    changed = true;
                }
            }
        }
        if changed {
            self.request_artwork();
            #[cfg(target_os = "macos")]
            if let Backend::Live(runtime) = &self.backend
                && let Some(media) = &mut self.media
            {
                media.update(runtime, &self.snapshot);
            }
        }
        menu::update(self);
        changed
    }

    fn request_artwork(&mut self) {
        let Backend::Live(worker) = &self.backend else {
            return;
        };
        let snapshot = &self.snapshot;
        let urls = snapshot
            .artwork
            .iter()
            .chain(snapshot.playback.artwork.iter())
            .chain(
                snapshot
                    .library
                    .iter()
                    .take(24)
                    .filter_map(|item| item.artwork.as_ref()),
            )
            .chain(
                snapshot
                    .sections
                    .iter()
                    .flat_map(|section| section.items.iter().take(14))
                    .filter_map(|item| item.artwork.as_ref()),
            )
            .chain(
                snapshot
                    .queue
                    .iter()
                    .take(32)
                    .chain(&snapshot.history)
                    .filter_map(|row| row.artwork.as_ref()),
            );
        let now = Instant::now();
        for url in urls {
            if !self.artwork.contains_key(url) && self.artwork_requests.start(url, now) {
                worker.artwork(snapshot.stamp.account, url.clone());
            }
        }
    }

    fn request_row_artwork(&mut self, range: std::ops::Range<usize>) {
        let Backend::Live(worker) = &self.backend else {
            return;
        };
        self.artwork_rows = Some(range.clone());
        let urls = self
            .table
            .order
            .get(range)
            .unwrap_or_default()
            .iter()
            .filter_map(|index| self.snapshot.tracks.get(*index)?.artwork.as_ref());
        let now = Instant::now();
        for url in urls {
            if !self.artwork.contains_key(url) && self.artwork_requests.start(url, now) {
                worker.artwork(self.snapshot.stamp.account, url.clone());
            }
        }
    }

    fn command(
        &mut self,
        action: &str,
        value: Option<&str>,
        target: Option<&str>,
        number: Option<f64>,
        stamp: Stamp,
    ) {
        let request = Request {
            action,
            value,
            target,
            number,
            stamp,
        };
        match &mut self.backend {
            Backend::Demo(demo) => {
                demo.command(&request);
                self.refresh();
            }
            Backend::Live(worker) => worker.command(&request),
            Backend::Starting => {}
        }
    }

    fn send(&mut self, action: &str, value: Option<&str>, target: Option<&str>) {
        if action == "logout" {
            self.pending_link = None;
        }
        self.command(action, value, target, None, self.snapshot.stamp);
    }

    fn archive_route(&mut self) {
        if self.retained.len() >= 32
            && let Some(key) = self.retained.keys().next().cloned()
        {
            self.retained.remove(&key);
        }
        self.retained.insert(
            self.route().clone(),
            (
                self.table.clone(),
                self.scroll.get(),
                self.artist_controls.clone(),
            ),
        );
    }

    fn sync_route(&mut self, tx: &mut Tx) {
        let route = self.route().clone();
        let (kind, uri) = route.wire();
        self.menu = None;
        self.show_about = false;
        let (table, scroll, artist_controls) =
            self.retained.get(&route).cloned().unwrap_or_else(|| {
                let is_playlist = uri.is_some_and(|uri| uri.contains(":playlist:"));
                let by_added = is_playlist || route == Route::Likes;
                (
                    Table {
                        sort: if by_added {
                            Sort::Added
                        } else {
                            Sort::Position
                        },
                        descending: by_added,
                        ..Table::default()
                    },
                    0.0,
                    ArtistControls::default(),
                )
            });
        self.artist_controls = artist_controls;
        self.table = table;
        self.scroll = Rc::new(Cell::new(scroll));
        self.compact = false;
        self.artwork_rows = None;
        self.send("route", Some(kind), uri);
        self.order_preserving_selection();
        tx.scroll_to_instant("main-scroll", 0.0, scroll);
        if route == Route::Search {
            tx.focus("global-search", false);
        }
    }

    fn navigate(&mut self, route: Route, tx: &mut Tx) {
        if self.route() != &route {
            self.archive_route();
            self.history.truncate(self.cursor + 1);
            self.history.push(route.into());
            self.cursor += 1;
            self.sync_route(tx);
        }
        if self.route() == &Route::Search {
            tx.focus("global-search", false);
        }
    }

    fn move_history(&mut self, step: isize, tx: &mut Tx) {
        let cursor = self
            .cursor
            .saturating_add_signed(step)
            .min(self.history.len() - 1);
        if cursor != self.cursor {
            self.archive_route();
            self.cursor = cursor;
            let search = if self.route() == &Route::Search {
                let query = self.history[self.cursor].search.clone();
                self.query = TextEdit::new(&query);
                self.last_query = query.trim().to_owned();
                if self.last_query.is_empty() {
                    self.search_filter = "All";
                }
                Some(query)
            } else {
                None
            };
            self.sync_route(tx);
            if let Some(query) = search {
                self.send("search", Some(&query), None);
                self.order();
            }
        }
    }

    fn search(&mut self, tx: &mut Tx) {
        if !self.snapshot.catalog_ready {
            return;
        }
        self.navigate(Route::Search, tx);
        let query = self.query.text.clone();
        self.history[self.cursor].search.clone_from(&query);
        if query.trim() != self.last_query {
            self.last_query = query.trim().to_owned();
            self.table = Table::default();
            if self.last_query.is_empty() {
                self.search_filter = "All";
            }
        }
        self.send("search", Some(&query), None);
        self.order();
        tx.scroll_to_instant("main-scroll", 0.0, 0.0);
    }

    fn filter_search(&mut self, filter: &'static str, tx: &mut Tx) {
        if self.search_filter != filter {
            self.search_filter = filter;
            self.order();
            tx.scroll_to_instant("main-scroll", 0.0, 0.0);
        }
    }

    fn toggle_panel(&mut self, panel: Panel) {
        self.panel = if self.panel == Some(panel) {
            None
        } else {
            Some(panel)
        };
        self.signout_confirmation = false;
        if self.panel == Some(Panel::Queue) {
            self.send("inspectQueue", None, None);
        }
    }

    fn order_preserving_selection(&mut self) {
        let filter = self.table.filter.text.trim().to_lowercase();
        let tracks = &self.snapshot.tracks;
        let mut indices = tracks
            .iter()
            .enumerate()
            .filter_map(|(index, track)| {
                (filter.is_empty()
                    || [&track.title, &track.artist, &track.album]
                        .iter()
                        .any(|field| field.to_lowercase().contains(&filter)))
                .then_some(index)
            })
            .collect::<Vec<_>>();
        let descending = self.table.descending;
        match self.table.sort {
            sort @ (Sort::Title | Sort::Artist | Sort::Album) => {
                let key = |index: &usize| {
                    let track = &tracks[*index];
                    match sort {
                        Sort::Title => &track.title,
                        Sort::Artist => &track.artist,
                        _ => &track.album,
                    }
                    .to_lowercase()
                };
                if descending {
                    indices.sort_by_cached_key(|index| std::cmp::Reverse(key(index)));
                } else {
                    indices.sort_by_cached_key(key);
                }
            }
            sort @ (Sort::Added | Sort::Duration | Sort::Plays) => {
                indices.sort_by(|&a, &b| {
                    let (a, b) = (&tracks[a], &tracks[b]);
                    let comparison = match sort {
                        Sort::Added => a.added.cmp(&b.added),
                        Sort::Duration => a.duration.total_cmp(&b.duration),
                        _ => a.count.cmp(&b.count),
                    };
                    if descending {
                        comparison.reverse()
                    } else {
                        comparison
                    }
                });
            }
            Sort::Position if descending => indices.reverse(),
            Sort::Position => {}
        }
        if self.route().wire().0 == "detail"
            && self
                .snapshot
                .details
                .as_ref()
                .is_some_and(|item| item.kind == "Artist")
            && !self.artist_controls.expanded
        {
            indices.truncate(5);
        }
        if self.route() == &Route::Search && self.search_filter == "All" {
            indices.truncate(4);
        }
        self.table.order = indices;
        self.table.version = self.table.version.wrapping_add(1);
    }

    fn order(&mut self) {
        self.order_preserving_selection();
        let tracks = &self.snapshot.tracks;
        let visible = self
            .table
            .order
            .iter()
            .map(|&index| tracks[index].id.as_str())
            .collect::<HashSet<_>>();
        self.table
            .selected
            .retain(|id| visible.contains(id.as_str()));
        if self
            .table
            .cursor
            .as_ref()
            .is_some_and(|id| !visible.contains(id.as_str()))
        {
            self.table.cursor = None;
        }
        if self
            .table
            .anchor
            .as_ref()
            .is_some_and(|id| !visible.contains(id.as_str()))
        {
            self.table.anchor = None;
        }
    }

    fn set_sort(&mut self, sort: Sort) {
        if self.table.sort == sort {
            self.table.descending = !self.table.descending;
        } else {
            self.table.sort = sort;
            self.table.descending = matches!(sort, Sort::Added | Sort::Plays);
        }
        self.order();
    }

    fn row_at(&self, i: usize) -> &Track {
        &self.snapshot.tracks[self.table.order[i]]
    }

    fn select_row(&mut self, id: &str, mods: Mods) {
        let ordered: Vec<_> = self
            .table
            .order
            .iter()
            .map(|&i| &self.snapshot.tracks[i].id)
            .collect();
        if mods.shift
            && let Some(anchor) = self.table.anchor.as_ref()
            && let (Some(first), Some(last)) = (
                ordered.iter().position(|row| *row == anchor),
                ordered.iter().position(|row| *row == id),
            )
        {
            if !mods.primary() {
                self.table.selected.clear();
            }
            self.table.selected.extend(
                ordered[first.min(last)..=first.max(last)]
                    .iter()
                    .map(|id| (*id).clone()),
            );
        } else {
            if !mods.primary() {
                self.table.selected.clear();
            }
            let id = id.to_owned();
            if !self.table.selected.remove(&id) {
                self.table.selected.insert(id.clone());
            }
            self.table.anchor = Some(id);
        }
        self.table.cursor = Some(id.to_owned());
    }

    fn select_queue(&mut self, id: &str, mods: Mods) {
        let ordered: Vec<_> = std::iter::once("now-playing")
            .filter(|_| !self.snapshot.playback.uri.is_empty())
            .chain(self.snapshot.queue.iter().map(|row| row.id.as_str()))
            .collect();
        if mods.shift
            && let Some(anchor) = self.queue_anchor.as_deref()
            && let (Some(first), Some(last)) = (
                ordered.iter().position(|row| *row == anchor),
                ordered.iter().position(|row| *row == id),
            )
        {
            if !mods.primary() {
                self.queue_selected.clear();
            }
            self.queue_selected.extend(
                ordered[first.min(last)..=first.max(last)]
                    .iter()
                    .map(|id| (*id).to_owned()),
            );
        } else {
            if !mods.primary() {
                self.queue_selected.clear();
            }
            if !self.queue_selected.remove(id) {
                self.queue_selected.insert(id.to_owned());
            }
            self.queue_anchor = Some(id.to_owned());
        }
    }

    fn context_menu(&mut self, source: MenuSource, id: &str, origin: [f32; 2]) {
        match source {
            MenuSource::Tracks if !self.table.selected.contains(id) => {
                self.select_row(id, Mods::default())
            }
            MenuSource::Queue if !self.queue_selected.contains(id) => {
                self.select_queue(id, Mods::default())
            }
            MenuSource::History => self.history_selected = Some(id.into()),
            _ => {}
        }
        self.menu = Some(Menu {
            source,
            origin,
            playlists: false,
        });
    }

    fn batch(&mut self, action: &str, source: MenuSource, target: Option<&str>) {
        if source == MenuSource::Queue && self.queue_selected.contains("now-playing") {
            return;
        }
        let ids: Vec<_> = match source {
            MenuSource::Queue => self
                .snapshot
                .queue
                .iter()
                .map(|row| &row.id)
                .filter(|id| self.queue_selected.contains(*id))
                .collect(),
            _ => self
                .table
                .order
                .iter()
                .map(|&index| &self.snapshot.tracks[index].id)
                .filter(|id| self.table.selected.contains(*id))
                .collect(),
        };
        if let Ok(json) = serde_json::to_string(&ids) {
            self.send(action, Some(&json), target);
        }
        self.menu = None;
    }

    fn primary(&mut self, source: MenuSource, restart: bool) {
        let value = match source {
            MenuSource::Tracks if self.table.selected.len() == 1 => {
                self.table.selected.iter().next().cloned()
            }
            MenuSource::Queue if self.queue_selected.len() == 1 => {
                self.queue_selected.iter().next().cloned()
            }
            MenuSource::History => self.history_selected.clone(),
            _ => None,
        };
        if let Some(value) = value {
            let action = match source {
                MenuSource::Tracks if restart => "startTrack",
                MenuSource::Tracks => "playTrack",
                MenuSource::Queue if value == "now-playing" => "toggle",
                MenuSource::Queue => "playQueue",
                MenuSource::History => "playHistory",
            };
            self.send(
                action,
                (value != "now-playing").then_some(value.as_str()),
                None,
            );
        }
        self.menu = None;
    }

    fn toggle_folder(&mut self, uri: &str) {
        if !self.collapsed.remove(uri) {
            self.collapsed.insert(uri.to_owned());
        }
    }

    fn row_key(id: &str) -> String {
        format!("track-row-{id}")
    }

    fn step_tracks(&mut self, direction: isize, mods: Mods, tx: &mut Tx) {
        if self.table.order.is_empty() {
            return;
        }
        let current = self.table.cursor.as_ref().and_then(|cursor| {
            self.table
                .order
                .iter()
                .position(|&i| self.snapshot.tracks[i].id == *cursor)
        });
        let next = current
            .map(|i| i.saturating_add_signed(direction))
            .unwrap_or(if direction < 0 {
                self.table.order.len() - 1
            } else {
                0
            })
            .min(self.table.order.len() - 1);
        let id = self.row_at(next).id.clone();
        self.select_row(&id, mods);
        let key = Self::row_key(&id);
        tx.scroll_into_view(key.clone());
        tx.focus_when_shown(key, true);
    }
}

fn setup(state: &mut State, wake: Waker) {
    let cache = ImageCache::new(wake.clone());
    if state.is_demo() {
        for &(name, bytes) in demo::ART {
            let image = cache.load(bytes);
            let _ = image.wait();
            state
                .artwork
                .insert(name.to_owned(), image.pixels().clone());
        }
    } else {
        state.backend = Backend::Live(live::Live::start(wake));
        #[cfg(target_os = "macos")]
        {
            state.media = Some(live::Media::new());
            state.updater = updater::Updater::start();
            if let Backend::Live(worker) = &state.backend {
                state.power = Some(worker.observe_power());
            }
        }
    }
}

fn poll(state: &mut State, _: f64, tx: &mut Tx) -> bool {
    if state.is_demo() {
        false
    } else {
        let changed = state.refresh();
        let now = Instant::now();
        if state.artwork_requests.expire(now) {
            state.request_artwork();
            if let Some(range) = state.artwork_rows.clone() {
                state.request_row_artwork(range);
            }
        }
        if let Some(deadline) = state.artwork_requests.next_retry() {
            tx.wake_after(deadline.saturating_duration_since(now));
        }
        open_pending_link(state, tx) || changed
    }
}

fn keyboard(state: &mut State, event: &KeyEvent, tx: &mut Tx) -> bool {
    if event.is_command('l') {
        if state.snapshot.catalog_ready {
            state.navigate(Route::Search, tx);
        }
        return true;
    }
    if event.is_command('[') || event.is_command(']') {
        state.move_history(if event.is_command('[') { -1 } else { 1 }, tx);
        return true;
    }
    let focus = tx.focused().unwrap_or_default();
    let in_tracks = focus.contains("track-row-");
    let source = if in_tracks {
        MenuSource::Tracks
    } else if focus.contains("history-row-") {
        MenuSource::History
    } else {
        MenuSource::Queue
    };
    match &event.key {
        Key::Escape if state.menu.is_some() => state.menu = None,
        Key::Escape if state.show_about => state.show_about = false,
        Key::Escape if state.table.filtering => {
            if state.table.filter.text.is_empty() {
                state.table.filtering = false;
            } else {
                state.table.filter = TextEdit::new("");
                state.order();
                tx.focus("playlist-filter", false);
            }
        }
        Key::Escape if let Some(panel) = state.panel => state.toggle_panel(panel),
        Key::Up | Key::Down if in_tracks => {
            state.step_tracks(if event.key == Key::Up { -1 } else { 1 }, event.mods, tx)
        }
        Key::Enter
            if in_tracks || focus.contains("queue-row-") || focus.contains("history-row-") =>
        {
            state.primary(source, true)
        }
        Key::Delete | Key::Backspace if in_tracks && state.snapshot.editable => {
            let uri = state.snapshot.details.as_ref().map(|item| item.uri.clone());
            state.batch("removePlaylist", source, uri.as_deref());
        }
        Key::Delete | Key::Backspace if focus.contains("queue-row-") && !state.history_tab => {
            state.batch("removeQueue", MenuSource::Queue, None)
        }
        Key::Text(space)
            if space == " "
                && !event.mods.cmd
                && !event.mods.ctrl
                && !event.mods.shift
                && !event.mods.alt
                && !event.mods.logo
                && !focus.contains("search")
                && !focus.contains("filter")
                && state.snapshot.playback.can_toggle =>
        {
            if !tx.key_repeat() {
                state.send("toggle", None, None);
            }
        }
        _ => return false,
    }
    true
}

fn quit(state: &mut State, _: &mut Tx) {
    #[cfg(target_os = "macos")]
    {
        state.power = None;
    }
    #[cfg(target_os = "macos")]
    if let Some(media) = &mut state.media {
        media.stop();
    }
    if let Backend::Live(worker) = &state.backend {
        worker.shutdown();
    }
}

fn reference(state: &mut State) {
    if state.is_demo() {
        if let Backend::Demo(demo) = &mut state.backend {
            demo.reference();
        }
        state.history = vec![
            Route::Home.into(),
            Route::Detail(demo::REFERENCE_URI.into()).into(),
        ];
        state.cursor = 1;
        state.sidebar_width = 260.0;
        state.table.sort = Sort::Added;
        state.table.descending = true;
        state.refresh();
        state.order();
    }
}

fn catalog_link(value: &str) -> Option<String> {
    let (scheme, resource) = value.split_once(':')?;
    let uri = if scheme.eq_ignore_ascii_case("spotify") {
        format!("spotify:{resource}")
    } else {
        let host = resource.strip_prefix("//")?.split(['/', '?', '#']).next()?;
        if !scheme.eq_ignore_ascii_case("https") || !host.eq_ignore_ascii_case("open.spotify.com") {
            return None;
        }
        let url = reqwest::Url::parse(value).ok()?;
        let mut segments = url.path_segments()?;
        let mut kind = segments.next()?;
        if kind.starts_with("intl-") {
            kind = segments.next()?;
        }
        let id = segments.next()?;
        if segments.any(|part| !part.is_empty()) {
            return None;
        }
        format!("spotify:{kind}:{id}")
    };
    (uri.rsplit_once(':')?.1.len() <= 22 && live::valid_catalog_uri(&uri)).then_some(uri)
}

fn receive_url(state: &mut State, value: &str, tx: &mut Tx) {
    if let Some(uri) = catalog_link(value) {
        state.pending_link = Some(uri);
        open_pending_link(state, tx);
    }
}

fn open_pending_link(state: &mut State, tx: &mut Tx) -> bool {
    if state.snapshot.catalog_ready
        && let Some(uri) = state.pending_link.take()
    {
        state.navigate(Route::Detail(uri), tx);
        true
    } else {
        false
    }
}

fn main() {
    let demo = rune::tooling::is_headless() || std::env::args_os().any(|arg| arg == "--demo");
    rune::set_app_id(if demo {
        "dev.spotty.demo"
    } else {
        "dev.spotty.app"
    });
    let spec = AppSpec {
        min_size: Some((960.0, 640.0)),
        setup: Some(setup),
        poll: Some(poll),
        on_key: Some(keyboard),
        scenes: &[("reference", reference)],
        ..AppSpec::new("Spotty", (1220.0, 780.0), State::new, view::view)
    };
    let app = App::new(spec)
        .chrome(Chrome {
            full_size_content: true,
            traffic_lights: Some((20.0, 20.0)),
            drag_regions: true,
        })
        .standard_menus()
        .on_quit(quit)
        .on_open_url(receive_url);
    #[cfg(target_os = "macos")]
    let app = app.keep_running();
    let host = app.handle();
    app.handle().update(move |state, _| {
        state.menus.host = Some(host);
        menu::update(state);
    });
    app.run();
}

#[cfg(test)]
mod tests {
    use super::*;
    use rune::{Env, Runtime};

    fn demo_runtime(reference_scene: bool) -> Runtime<State> {
        let mut state = State::with_backend(Backend::Demo(Box::new(demo::Demo::new())));
        if reference_scene {
            reference(&mut state);
        }
        let mut runtime = Runtime::new(state, view::view, (1720.0, 1078.0), Env::new(true, 1.0));
        runtime.frame(0.0);
        runtime
    }

    fn click(runtime: &mut Runtime<State>, key: &str) {
        let (x, y) = runtime.find(key).unwrap_or_else(|| panic!("Missing {key}"));
        click_at(runtime, x, y);
    }

    fn click_at(runtime: &mut Runtime<State>, x: f32, y: f32) {
        runtime.pointer_down(x, y);
        runtime.pointer_up(x, y);
        runtime.frame(0.15);
    }

    fn key(runtime: &mut Runtime<State>, key: Key) {
        runtime.key(KeyEvent {
            key,
            mods: Mods::default(),
        });
        runtime.frame(0.15);
    }

    #[test]
    fn search_opens_a_detail_and_history_restores_the_query() {
        let mut runtime = demo_runtime(false);
        click(&mut runtime, "global-search");
        key(&mut runtime, Key::Text("Moonlit".into()));
        assert_eq!(runtime.state.route(), &Route::Search);
        assert_eq!(
            runtime.state.snapshot.sections[0].items[0].title,
            "Moonlit Drive"
        );
        click(&mut runtime, "card-0-0");
        assert_eq!(runtime.state.snapshot.tracks.len(), 1000);
        click(&mut runtime, "go-back");
        assert_eq!(runtime.state.route(), &Route::Search);
        assert_eq!(runtime.state.query.text, "Moonlit");

        click(&mut runtime, "card-0-0");
        runtime.update(|state, tx| {
            state.query = TextEdit::new("Neon");
            state.search(tx);
        });
        assert_eq!(
            runtime.state.snapshot.sections[0].items[0].title,
            "Neon Afterglow"
        );
        runtime.update(|state, tx| state.move_history(-2, tx));
        assert_eq!(runtime.state.query.text, "Moonlit");
        assert_eq!(
            runtime.state.snapshot.sections[0].items[0].title,
            "Moonlit Drive"
        );
        runtime.update(|state, tx| state.move_history(2, tx));
        assert_eq!(runtime.state.query.text, "Neon");
        assert_eq!(
            runtime.state.snapshot.sections[0].items[0].title,
            "Neon Afterglow"
        );
    }

    #[test]
    fn search_filters_reuse_results_and_clearing_search_restores_all() {
        let mut runtime = demo_runtime(false);
        click(&mut runtime, "global-search");
        key(&mut runtime, Key::Text("Harbor".into()));
        let count = runtime.state.snapshot.tracks.len();
        assert!(count >= 4);
        assert_eq!(runtime.state.table.order.len(), 4);
        click(&mut runtime, "search-Songs");
        assert_eq!(runtime.state.table.order.len(), count);
        click(&mut runtime, "search-Artists");
        assert!(runtime.find("track-list").is_none());
        click(&mut runtime, "clear-search");
        assert_eq!(runtime.state.search_filter, "All");
        assert!(runtime.state.query.text.is_empty());
    }

    #[test]
    fn card_playback_and_preview_artwork_act_independently_of_navigation_and_selection() {
        let mut runtime = demo_runtime(false);
        let collection = runtime.state.snapshot.sections[0].items[0].uri.clone();
        click(&mut runtime, "quick-0-0-play");
        assert_eq!(runtime.state.route(), &Route::Home);
        assert_eq!(runtime.state.snapshot.playback.context, collection);
        assert!(runtime.state.snapshot.playback.playing);
        click(&mut runtime, "quick-0-0-play");
        assert!(!runtime.state.snapshot.playback.playing);
        click(&mut runtime, "global-search");
        key(&mut runtime, Key::Text("Harbor".into()));
        let track = runtime.state.row_at(0).clone();
        let row = State::row_key(&track.id);
        let art = format!("preview-art-{}", track.id);
        let rect = runtime.presented(&row).unwrap().0;
        click_at(&mut runtime, rect[0] + 105.0, rect[1] + 17.0);
        assert!(runtime.state.table.selected.contains(&track.id));
        key(&mut runtime, Key::Tab);
        assert!(
            runtime
                .elements()
                .iter()
                .any(|e| e.focused && e.key.as_ref() == Some(&art))
        );
        key(&mut runtime, Key::Text(" ".into()));
        assert_eq!(runtime.state.snapshot.playback.uri, track.uri);
        assert!(runtime.state.snapshot.playback.playing);
        runtime.key(KeyEvent {
            key: Key::Tab,
            mods: Mods {
                shift: true,
                ..Mods::default()
            },
        });
        runtime.frame(0.1);
        assert!(
            runtime
                .elements()
                .iter()
                .any(|e| e.focused && e.key.as_ref() == Some(&row))
        );
    }

    #[test]
    fn discography_list_loads_visible_albums_with_distinct_track_occurrences() {
        let mut runtime = demo_runtime(false);
        runtime.update(|state, tx| {
            state.navigate(Route::Discography("spotify:artist:synthetic0".into()), tx)
        });
        runtime.frame(0.1);
        click(&mut runtime, "release-layout");
        for _ in 0..3 {
            runtime.frame(0.1);
        }
        let snapshot = &runtime.state.snapshot;
        assert!(!snapshot.tracks.is_empty());
        let ids: HashSet<_> = snapshot.tracks.iter().map(|row| row.id.as_str()).collect();
        assert_eq!(ids.len(), snapshot.tracks.len());
        assert!(snapshot.tracks.iter().all(|row| {
            row.album_item
                .as_ref()
                .is_some_and(|album| row.id.starts_with(&album.uri))
        }));
        let first = snapshot.tracks[0].clone();
        let count = snapshot.queue.len();
        runtime.state.send("queueTrack", Some(&first.id), None);
        assert_eq!(runtime.state.snapshot.queue.len(), count + 1);
        assert_eq!(runtime.state.snapshot.queue[count].uri, first.uri);
        click(&mut runtime, "release-sort");
        assert!(runtime.state.artist_controls.sort_name);
        click(&mut runtime, "release-layout");
        assert!(!runtime.state.artist_controls.list);
    }

    #[test]
    fn playlist_sort_and_filter_preserve_row_identity() {
        let mut runtime = demo_runtime(true);
        assert_eq!(runtime.state.row_at(0).title, "Silver Lining");
        assert!(runtime.state.table.descending);
        click(&mut runtime, "sort-added");
        assert_eq!(runtime.state.row_at(0).id, "synthetic0x999");
        click(&mut runtime, "sort-added");
        assert_eq!(runtime.state.row_at(0).id, "synthetic0x0");
        let rect = runtime.presented("track-row-synthetic0x0").unwrap().0;
        click_at(&mut runtime, rect[0] + 105.0, rect[1] + 17.0);
        assert!(runtime.state.table.selected.contains("synthetic0x0"));
        assert!(!runtime.state.snapshot.playback.playing);
        click(&mut runtime, "filter-playlist");
        key(&mut runtime, Key::Text("Coastline".into()));
        assert!(runtime.state.table.selected.is_empty());
        assert!(!runtime.state.table.order.is_empty());
        assert!(
            runtime
                .state
                .table
                .order
                .iter()
                .all(|&i| runtime.state.snapshot.tracks[i].title == "Coastline")
        );
        key(&mut runtime, Key::Escape);
        assert_eq!(runtime.state.table.order.len(), 1000);
    }

    #[test]
    fn editing_and_queue_use_selected_occurrences_and_device_ownership() {
        let mut runtime = demo_runtime(true);
        runtime.state.select_row("synthetic0x0", Mods::default());
        runtime.state.select_row(
            "synthetic0x1",
            Mods {
                shift: true,
                ..Mods::default()
            },
        );
        assert_eq!(runtime.state.table.selected.len(), 2);
        runtime.state.batch(
            "removePlaylist",
            MenuSource::Tracks,
            Some(demo::REFERENCE_URI),
        );
        runtime.frame(0.15);
        assert_eq!(runtime.state.snapshot.tracks.len(), 998);
        assert_eq!(runtime.state.row_at(0).title, "Paper Sun");
        click(&mut runtime, "open-queue");
        click(&mut runtime, "queue-row-1");
        assert_eq!(runtime.state.snapshot.playback.title, "Silver Lining");
        runtime.state.batch("removeQueue", MenuSource::Queue, None);
        runtime.frame(0.15);
        assert_eq!(runtime.state.snapshot.queue[0].title, "Paper Sun");
        click(&mut runtime, "open-devices");
        click(&mut runtime, "device-0");
        assert_eq!(runtime.state.snapshot.playback.device, "This computer");
        assert!(
            runtime
                .state
                .snapshot
                .queue
                .iter()
                .all(|row| !row.removable)
        );
        click(&mut runtime, "next");
        assert_eq!(runtime.state.snapshot.playback.title, "Paper Sun");
    }

    #[test]
    fn queue_add_uses_visible_order_after_sorting() {
        let mut runtime = demo_runtime(true);
        runtime.state.set_sort(Sort::Added);
        let first = runtime.state.row_at(0).clone();
        let second = runtime.state.row_at(1).clone();
        assert_eq!(first.id, "synthetic0x999");
        runtime.state.table.selected = [first.id, second.id].into_iter().collect();
        let end = runtime.state.snapshot.queue.len();
        runtime.state.batch("queueTrack", MenuSource::Tracks, None);
        let added: Vec<_> = runtime.state.snapshot.queue[end..]
            .iter()
            .map(|row| row.uri.as_str())
            .collect();
        assert_eq!(added, [first.uri.as_str(), second.uri.as_str()]);
    }

    #[test]
    fn a_launch_link_waits_for_catalog_readiness() {
        let state = State::with_backend(Backend::Starting);
        let mut runtime = Runtime::new(state, view::view, (960.0, 640.0), Env::new(true, 1.0));
        runtime.update(|state, tx| {
            receive_url(state, "https://open.spotify.com/intl-de/album/example", tx);
            receive_url(
                state,
                "https://open.spotify.com.example.com/album/other",
                tx,
            );
            assert_eq!(state.route(), &Route::Home);
            state.snapshot.catalog_ready = true;
            assert!(poll(state, 0.0, tx));
            assert!(!open_pending_link(state, tx));
        });
        assert_eq!(
            runtime.state.route(),
            &Route::Detail("spotify:album:example".into())
        );
        assert!(catalog_link("https://:password@open.spotify.com/album/example").is_none());
        assert!(catalog_link("https://open.spotify.com:443/album/example").is_none());
        assert!(catalog_link("spotify:album:abcdefghijklmnopqrstuvwxyz").is_none());
        assert_eq!(
            catalog_link("SPOTIFY:artist:example").as_deref(),
            Some("spotify:artist:example")
        );
    }

    #[test]
    fn artwork_failures_cool_down_instead_of_permanently_preventing_retry() {
        let mut requests = ArtworkRequests::default();
        let started = Instant::now();
        assert!(requests.start("cover", started));
        assert!(!requests.start("cover", started));
        requests.finish("cover", false, started);
        assert_eq!(
            requests.next_retry(),
            Some(started + Duration::from_secs(30))
        );
        assert!(!requests.expire(started + Duration::from_secs(29)));
        assert!(!requests.start("cover", started + Duration::from_secs(29)));
        assert!(requests.expire(started + Duration::from_secs(30)));
        assert!(requests.start("cover", started + Duration::from_secs(30)));
        requests.finish("cover", true, started + Duration::from_secs(30));
        assert!(requests.failed.is_empty());
        assert!(requests.pending.is_empty());
    }
}
