use crate::model::*;
use chrono::{Datelike, NaiveDate};

const PLAYLIST_NAMES: &[&str] = &[
    "Moonlit Drive",
    "Neon Afterglow",
    "Sunday Coffee",
    "Soft Focus",
    "Coastal Morning",
    "Night Bus Home",
    "Golden Hour",
    "Rain on the Window",
    "Kitchen Dancing",
    "Quiet Momentum",
    "Indie Daydream",
    "Late Checkout",
    "City in Bloom",
    "Analog Warmth",
    "Open Road",
    "Slow Sundays",
    "After Work",
    "Fresh Air",
    "Midnight Radio",
    "Low-Key Favorites",
    "Deep Work",
    "Instrumental Focus",
    "Morning Flow",
    "No Distractions",
    "Weekend Warm-Up",
    "Saturday Sun",
    "Dinner with Friends",
    "Sunday Reset",
];
const FOLDERS: [(&str, usize); 2] = [("Focus", 4), ("Weekend", 4)];
const PLAYLIST_DESCRIPTIONS: &[&str] = &[
    "Dreamy songs for the drive home",
    "Electric nights and glowing city streets",
    "A slow start with something warm",
    "Gentle textures for an unhurried afternoon",
    "Bright songs for open windows",
    "The soundtrack for watching the city pass by",
    "Hold on to the last light",
    "Soft songs for grey weather",
    "Turn the kitchen into a dance floor",
    "Steady energy without the noise",
    "Guitars, daydreams, and good company",
    "One more song before heading downstairs",
    "Fresh finds with room to breathe",
    "Warm recordings and timeless melodies",
    "Songs that make the miles disappear",
    "Nothing urgent, nowhere else to be",
    "A clean break between work and evening",
    "Music made for getting outside",
    "Songs worth staying up for",
    "The ones that always fit",
    "Long stretches of uninterrupted concentration",
    "Words out, focus on",
    "A clear head and an easy rhythm",
    "Calm sounds for getting things done",
    "Start the weekend at full volume",
    "Sunshine, side streets, and nowhere to rush",
    "Crowd-pleasers for a table full of people",
    "Ease into the week ahead",
];
const TRACK_NAMES: &[&str] = &[
    "Silver Lining",
    "Night Transit",
    "Paper Sun",
    "Glass Garden",
    "Afterimage",
    "Violet Orbit",
    "Static on the Line",
    "Coastline",
    "Half Awake",
    "Borrowed Time",
    "Northern Lights",
    "Slow Motion",
    "Blue Hour",
    "Backseat Summer",
    "Familiar Streets",
    "Signals",
    "Warm Nights",
    "Passing Through",
    "Open Window",
    "Satellite Heart",
    "Second Wind",
    "Side by Side",
    "Wildflower",
    "Stay for a While",
    "First Light",
    "Out of Frame",
    "Long Way Home",
    "Tidal Lines",
    "Velvet Sky",
    "Here and Now",
    "Easy Company",
    "Turning Pages",
    "Distant Thunder",
    "Under the Pines",
    "Little Victories",
    "Daybreak",
    "Parallel Lines",
    "Good Intentions",
    "September Air",
    "Anywhere with You",
    "Last Train",
    "Soft Landing",
    "Bright Side",
    "The Way It Goes",
    "Quietly Loud",
    "Between Stations",
    "New Perspective",
    "Home Again",
];
const ALBUM_NAMES: &[&str] = &[
    "Signals at Dusk",
    "Postcards from Nowhere",
    "Rooms with Open Windows",
    "Northern Exposure",
    "Everything in Motion",
    "Polaroid Weather",
    "The Long Weekend",
    "Maps We Never Used",
    "Small Hours",
    "Color Theory",
    "Familiar Places",
    "A Different Light",
];
const ARTIST_NAMES: &[&str] = &[
    "Harbor Lights",
    "Mara Vale",
    "The Side Streets",
    "June Arcade",
    "Northbound",
    "Ellis Rowe",
    "Paper Satellites",
    "Cedar House",
    "Lena Hart",
    "Atlas Bloom",
    "Night Weather",
    "Theo Lane",
];
const LISTENER_NAMES: &[&str] = &[
    "Mara Vale",
    "Ellis Rowe",
    "Lena Hart",
    "Theo Lane",
    "Nina Cole",
];
pub const REFERENCE_URI: &str = "spotify:playlist:synthetic0";
pub const ART: &[(&str, &[u8])] = &[
    (
        "tidal-light",
        include_bytes!("../../Tests/BrowsingHarness/Support/Artwork/tidal-light.jpg"),
    ),
    (
        "night-transit",
        include_bytes!("../../Tests/BrowsingHarness/Support/Artwork/night-transit.jpg"),
    ),
    (
        "paper-sun",
        include_bytes!("../../Tests/BrowsingHarness/Support/Artwork/paper-sun.jpg"),
    ),
    (
        "glass-garden",
        include_bytes!("../../Tests/BrowsingHarness/Support/Artwork/glass-garden.jpg"),
    ),
    (
        "afterimage",
        include_bytes!("../../Tests/BrowsingHarness/Support/Artwork/afterimage.jpg"),
    ),
    (
        "violet-orbit",
        include_bytes!("../../Tests/BrowsingHarness/Support/Artwork/violet-orbit.jpg"),
    ),
];

pub struct Demo {
    playlists: Vec<Item>,
    artists: Vec<Item>,
    albums: Vec<Item>,
    requested_releases: std::collections::HashSet<String>,
    changes: std::collections::HashMap<String, Vec<Track>>,
    playback: Playback,
    queue: Vec<Track>,
    history: Vec<Track>,
    devices: Vec<Device>,
    route: Route,
    query: String,
    feedback: Option<String>,
    signed_in: bool,
    stamp: Stamp,
    queue_id: u64,
}

fn art(index: usize) -> Option<String> {
    Some(ART[index % ART.len()].0.into())
}

impl Demo {
    pub fn new() -> Self {
        let playlists = PLAYLIST_NAMES
            .iter()
            .enumerate()
            .map(|(i, title)| Item {
                uri: format!("spotify:playlist:synthetic{i}"),
                title: (*title).into(),
                subtitle: LISTENER_NAMES[i % LISTENER_NAMES.len()].into(),
                kind: "Playlist".into(),
                artwork: art(i),
                owner: Some(
                    if i == 0 || i == 3 {
                        "spotify:user:demo"
                    } else {
                        "spotify:user:another"
                    }
                    .into(),
                ),
                description: PLAYLIST_DESCRIPTIONS
                    .get(i)
                    .copied()
                    .unwrap_or_default()
                    .into(),
                ..Item::default()
            })
            .collect();
        let artists = ARTIST_NAMES
            .iter()
            .enumerate()
            .map(|(i, name)| Item {
                uri: format!("spotify:artist:synthetic{i}"),
                title: (*name).into(),
                kind: "Artist".into(),
                subtitle: format!("{} monthly listeners", 380_000 + 5790 * i),
                artwork: art(i),
                ..Item::default()
            })
            .collect();
        let albums = ALBUM_NAMES
            .iter()
            .enumerate()
            .map(|(i, name)| Item {
                uri: format!("spotify:album:synthetic{i}"),
                title: (*name).into(),
                kind: "Album".into(),
                subtitle: ARTIST_NAMES[i % ARTIST_NAMES.len()].into(),
                artwork: art(i),
                date: format!("{}-08-14", 2026 - i % 5),
                category: ["ALBUM", "SINGLE", "COMPILATION"][i % 3].into(),
                ..Item::default()
            })
            .collect();
        let mut demo = Self {
            requested_releases: Default::default(),
            playlists,
            artists,
            albums,
            changes: Default::default(),
            playback: Playback {
                can_start: true,
                can_toggle: true,
                can_skip: true,
                can_transfer: true,
                device: "Living Room".into(),
                ..Playback::default()
            },
            queue: Vec::new(),
            history: Vec::new(),
            devices: vec![
                Device {
                    id: "local".into(),
                    name: "This computer".into(),
                    detail: "Computer".into(),
                    active: false,
                },
                Device {
                    id: "speaker".into(),
                    name: "Living Room".into(),
                    detail: "Speaker".into(),
                    active: true,
                },
                Device {
                    id: "phone".into(),
                    name: "Phone".into(),
                    detail: "Smartphone".into(),
                    active: false,
                },
            ],
            route: Route::Home,
            query: String::new(),
            feedback: None,
            signed_in: true,
            stamp: Stamp {
                account: 1,
                engine: 1,
                catalog: 1,
                route: 1,
                ..Stamp::default()
            },
            queue_id: 1,
        };
        let track = demo.track(0, 0);
        demo.play(track, Some(REFERENCE_URI));
        demo.playback.playing = false;
        for i in 1..4 {
            let track = demo.track(0, i * 4);
            demo.history.push(track);
        }
        demo.queue = (1..7)
            .map(|i| Track {
                id: format!("demo-queue-{i}"),
                removable: true,
                ..demo.track(0, i)
            })
            .collect();
        demo
    }

    fn track(&self, playlist: usize, i: usize) -> Track {
        let artist = i % ARTIST_NAMES.len();
        let album = i % ALBUM_NAMES.len();
        let base = NaiveDate::from_ymd_opt(2025, 12, 27).unwrap();
        let date = base - chrono::Duration::days((i + playlist * 13) as i64);
        Track {
            id: format!("synthetic{playlist}x{i}"),
            uri: format!("spotify:track:synthetic{playlist}x{i}"),
            title: TRACK_NAMES[i % TRACK_NAMES.len()].into(),
            artist: ARTIST_NAMES[artist].into(),
            album: ALBUM_NAMES[album].into(),
            artwork: art(i),
            duration: (180 + i % 60) as f64,
            added: format!(
                "{:04}-{:02}-{:02}T00:00:00Z",
                date.year(),
                date.month(),
                date.day()
            ),
            occurrence: Some(format!("occurrence-{playlist}-{i}")),
            removable: playlist == 0 || playlist == 3,
            artists: vec![self.artists[artist].clone()],
            album_item: Some(self.albums[album].clone()),
            ..Track::default()
        }
    }

    fn tracks(&self, route: &Route, search: &str) -> Vec<Track> {
        match route {
            Route::Search if !search.trim().is_empty() => {
                let term = search.trim().to_lowercase();
                (0..TRACK_NAMES.len())
                    .map(|i| self.track(0, i))
                    .filter(|row| {
                        [&row.title, &row.artist, &row.album]
                            .iter()
                            .any(|text| text.to_lowercase().contains(&term))
                    })
                    .map(|row| Track {
                        removable: false,
                        ..row
                    })
                    .collect()
            }
            Route::Likes => (0..48)
                .map(|i| Track {
                    removable: false,
                    ..self.track(0, i)
                })
                .collect(),
            Route::Detail(uri) => {
                if let Some(rows) = self.changes.get(uri) {
                    return rows.clone();
                }
                if let Some(index) = self.playlists.iter().position(|item| &item.uri == uri) {
                    return (0..1000).map(|i| self.track(index, i)).collect();
                }
                if let Some(n) = self.albums.iter().position(|item| &item.uri == uri) {
                    return (0..12)
                        .map(|i| Track {
                            removable: false,
                            ..self.track(0, n + i * 12)
                        })
                        .collect();
                }
                if let Some(n) = self.artists.iter().position(|item| &item.uri == uri) {
                    return (0..10)
                        .map(|i| Track {
                            removable: false,
                            count: Some(4_900_000 - 37100 * i as u64),
                            ..self.track(0, n + i * 12)
                        })
                        .collect();
                }
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    fn library(&self) -> Vec<Item> {
        let folder_rows = FOLDERS.iter().map(|(_, count)| count).sum::<usize>();
        let (root, mut remaining) = self.playlists.split_at(self.playlists.len() - folder_rows);
        let mut items = root.to_vec();
        for (i, (title, count)) in FOLDERS.into_iter().enumerate() {
            let (children, rest) = remaining.split_at(count);
            remaining = rest;
            items.push(Item {
                uri: format!("spotify:folder:synthetic{i}"),
                title: title.into(),
                kind: "Folder".into(),
                children: children.to_vec(),
                ..Item::default()
            });
        }
        items
    }

    fn item(&self, uri: &str) -> Option<Item> {
        self.playlists
            .iter()
            .chain(&self.artists)
            .chain(&self.albums)
            .find(|item| item.uri == uri)
            .cloned()
    }

    fn play(&mut self, track: Track, context: Option<&str>) {
        self.playback.context = context.unwrap_or_default().into();
        self.playback.uri.clone_from(&track.uri);
        self.playback.title.clone_from(&track.title);
        self.playback.artist.clone_from(&track.artist);
        self.playback.artwork.clone_from(&track.artwork);
        self.playback.duration = track.duration;
        self.playback.position = 0.0;
        self.playback.playing = true;
        self.history.retain(|row| row.uri != track.uri);
        self.history.insert(
            0,
            Track {
                id: track.uri.clone(),
                removable: false,
                ..track
            },
        );
        self.history.truncate(10);
    }

    pub fn command(&mut self, request: &Request<'_>) {
        let stamp = self.stamp;
        if request.stamp.account != stamp.account {
            return;
        }
        let current_catalog = request.stamp.catalog == stamp.catalog;
        let current_view = current_catalog && request.stamp.view == stamp.view;
        let current_playlist = current_view && request.stamp.playlist == stamp.playlist;
        let current_queue = request.stamp.queue == stamp.queue;
        self.feedback = None;
        let value = request.value.unwrap_or_default();
        let target = request.target.unwrap_or_default();
        let ids: Vec<String> = if value.starts_with('[') {
            serde_json::from_str(value).unwrap_or_default()
        } else {
            vec![value.into()]
        };
        if request.action == "connect" {
            self.signed_in = true;
            self.stamp.account += 1;
            return;
        }
        if !self.signed_in {
            return;
        }
        match request.action {
            "route" if current_catalog => {
                self.requested_releases.clear();
                self.route = match value {
                    "search" => Route::Search,
                    "likes" => Route::Likes,
                    "library" => Route::Library,
                    "detail" => Route::Detail(target.into()),
                    "discography" => Route::Discography(target.into()),
                    _ => Route::Home,
                };
                self.stamp.view += 1;
            }
            "releaseTracks" | "retryRelease" if current_view => {
                if self.requested_releases.insert(value.into()) {
                    self.stamp.playlist += 1;
                }
            }
            "search" if current_catalog && self.route == Route::Search && self.query != value => {
                self.query = value.into();
                self.stamp.view += 1;
            }
            "toggle" => self.playback.playing = !self.playback.playing,
            "playTrack" | "startTrack" if current_view => {
                if let Some(track) = self
                    .snapshot(&self.route, &self.query)
                    .tracks
                    .into_iter()
                    .find(|track| track.id == value)
                {
                    if self.playback.uri == track.uri && request.action != "startTrack" {
                        self.playback.playing = !self.playback.playing;
                    } else {
                        let context = match &self.route {
                            Route::Detail(uri) => Some(uri.clone()),
                            _ => None,
                        };
                        self.play(track, context.as_deref());
                    }
                }
            }
            "playContext" | "playItem" if current_view => {
                if request.action == "playItem" && self.playback.context == value {
                    self.playback.playing = !self.playback.playing;
                } else if let Some(track) = self
                    .tracks(&Route::Detail(value.into()), "")
                    .into_iter()
                    .next()
                {
                    self.play(track, Some(value));
                }
            }
            "next" => {
                if let Some(track) = self.queue.first().cloned() {
                    self.queue.remove(0);
                    self.stamp.queue += 1;
                    let context = self.playback.context.clone();
                    self.play(track, Some(&context));
                }
            }
            "previous" => {
                if let Some(track) = self.history.get(1).cloned() {
                    self.play(track, None);
                }
            }
            "seek" => {
                self.playback.position =
                    request.number.unwrap_or(0.0).clamp(0.0, 1.0) * self.playback.duration
            }
            "shuffle" => self.playback.shuffle = !self.playback.shuffle,
            "repeat" => {
                self.playback.repeat = match self.playback.repeat.as_str() {
                    "off" => "context",
                    "context" => "track",
                    _ => "off",
                }
                .into()
            }
            "queueTrack" if current_playlist => {
                let tracks = self.snapshot(&self.route, &self.query).tracks;
                let selected = ordered_tracks(&tracks, &ids);
                if selected.is_empty() {
                    return;
                }
                for track in selected {
                    self.queue_id += 1;
                    self.queue.push(Track {
                        id: format!("local-queue-{}", self.queue_id),
                        removable: true,
                        ..track.clone()
                    });
                }
                self.stamp.queue += 1;
                self.feedback = Some("Queue request sent".into());
            }
            "playQueue" if current_queue => {
                if let Some(track) = self.queue.iter().find(|track| track.id == value).cloned() {
                    self.play(track, None);
                }
            }
            "playHistory" => {
                if let Some(track) = self.history.iter().find(|track| track.id == value).cloned() {
                    self.play(track, None);
                }
            }
            "removeQueue" if current_queue && self.playback.device != "This computer" => {
                self.queue.retain(|track| !ids.contains(&track.id));
                self.stamp.queue += 1;
                self.feedback = Some("Queue updated".into());
            }
            "addPlaylist" | "removePlaylist" if current_playlist => {
                if let Some(item) = self
                    .item(target)
                    .filter(|item| item.owner.as_deref() == Some("spotify:user:demo"))
                {
                    let mut tracks = self.tracks(&Route::Detail(target.into()), "");
                    if request.action == "addPlaylist" {
                        let visible = self.snapshot(&self.route, &self.query).tracks;
                        for row in ordered_tracks(&visible, &ids) {
                            let mut track = row.clone();
                            self.queue_id += 1;
                            track.id = format!("new-{}", self.queue_id);
                            track.occurrence = Some(track.id.clone());
                            track.removable = true;
                            tracks.push(track);
                        }
                    } else {
                        tracks.retain(|row| !ids.contains(&row.id));
                    }
                    self.changes.insert(item.uri, tracks);
                    self.stamp.playlist += 1;
                    self.feedback = Some("Playlist updated".into());
                }
            }
            "device" => {
                if let Some(device) = self.devices.iter().find(|device| device.id == value) {
                    self.playback.device.clone_from(&device.name);
                    for device in &mut self.devices {
                        device.active = device.id == value;
                    }
                    for row in &mut self.queue {
                        row.removable = value != "local";
                    }
                }
            }
            "logout" => {
                self.signed_in = false;
                self.stamp.account += 1;
            }
            _ => {}
        }
    }

    pub fn snapshot(&self, route: &Route, query: &str) -> Snapshot {
        if !self.signed_in {
            return Snapshot {
                stamp: self.stamp,
                phase: "signedOut".into(),
                status: "Connect to Spotify Premium".into(),
                ..Snapshot::default()
            };
        }
        let mut snapshot = Snapshot {
            phase: "ready".into(),
            status: "Demo".into(),
            account: "Mara Vale".into(),
            catalog_ready: true,
            stamp: self.stamp,
            library: self.library(),
            library_loaded: true,
            edit_targets: self
                .playlists
                .iter()
                .filter(|item| item.owner.as_deref() == Some("spotify:user:demo"))
                .cloned()
                .collect(),
            queue: self.queue.clone(),
            history: self.history.clone(),
            devices: self.devices.clone(),
            playback: self.playback.clone(),
            feedback: self.feedback.clone(),
            ..Snapshot::default()
        };
        snapshot.tracks = self.tracks(route, query);
        let section = |title: &str, items: Vec<Item>| Section {
            title: title.into(),
            items,
        };
        match route {
            Route::Home => {
                snapshot.title = "Good afternoon".into();
                snapshot.sections = vec![
                    section("Recently played", self.playlists[..8].to_vec()),
                    section("Made for you", self.playlists[8..16].to_vec()),
                    section("Albums", self.albums[..8].to_vec()),
                ];
            }
            Route::Search => {
                snapshot.title = "Search".into();
                if !query.trim().is_empty() {
                    let query = query.trim().to_lowercase();
                    let matches = |item: &&Item| {
                        [&item.title, &item.subtitle, &item.description]
                            .iter()
                            .any(|field| field.to_lowercase().contains(&query))
                    };
                    for (title, group) in [
                        ("Albums", &self.albums),
                        ("Artists", &self.artists),
                        ("Playlists", &self.playlists),
                    ] {
                        let items = group.iter().filter(matches).cloned().collect::<Vec<_>>();
                        if !items.is_empty() {
                            snapshot.sections.push(section(title, items));
                        }
                    }
                }
            }
            Route::Library => {
                snapshot.title = "Your Library".into();
                snapshot.sections = vec![
                    section("Albums", self.albums.clone()),
                    section("Artists", self.artists.clone()),
                    section("Playlists", self.playlists.clone()),
                ];
            }
            Route::Likes => snapshot.title = "Liked Songs".into(),
            Route::Detail(uri) => {
                if let Some(item) = self.item(uri) {
                    snapshot.title.clone_from(&item.title);
                    snapshot.subtitle.clone_from(&item.subtitle);
                    snapshot.description.clone_from(&item.description);
                    snapshot.artwork.clone_from(&item.artwork);
                    snapshot.editable = item.owner.as_deref() == Some("spotify:user:demo");
                    snapshot.context_playable = true;
                    if item.kind == "Artist" {
                        snapshot.sections = vec![
                            section("Discography", self.albums[..6].to_vec()),
                            section("Featuring", self.playlists[..3].to_vec()),
                        ];
                        snapshot.artist_about = Some(format!(
                            "{} is part of Spotty’s synthetic catalog.",
                            item.title
                        ));
                    }
                    snapshot.details = Some(item);
                }
            }
            Route::Discography(uri) => {
                snapshot.title = self
                    .item(uri)
                    .map_or_else(|| "Discography".into(), |item| item.title);
                snapshot.sections = vec![section("", self.albums.clone())];
                for album in &self.albums {
                    if self.requested_releases.contains(&album.uri) {
                        let mut rows = self.tracks(&Route::Detail(album.uri.clone()), "");
                        for row in &mut rows {
                            row.album_item = Some(album.clone());
                            row.album.clone_from(&album.title);
                        }
                        snapshot.set_release_tracks(&album.uri, rows);
                    }
                }
            }
        }
        snapshot.stamp.playlist = self.stamp.playlist;
        snapshot
    }

    pub fn reference(&mut self) {
        self.route = Route::Detail(REFERENCE_URI.into());
        self.playback.context.clear();
    }
}
