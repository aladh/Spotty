use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct Snapshot {
    pub stamp: Stamp,
    pub account: String,
    pub phase: String,
    pub status: String,
    pub reauthenticate: bool,
    pub catalog_ready: bool,
    pub title: String,
    pub subtitle: String,
    pub artwork: Option<String>,
    pub context_playable: bool,
    pub loading: bool,
    pub cached: bool,
    pub error: Option<String>,
    pub feedback: Option<String>,
    pub sections: Vec<Section>,
    pub search_errors: std::collections::BTreeMap<String, String>,
    pub release_loads: std::collections::BTreeMap<String, ReleaseLoad>,
    pub details: Option<Item>,
    pub description: String,
    pub artist_about: Option<String>,
    pub library_loading: bool,
    pub library_error: Option<String>,
    pub profile_error: Option<String>,
    pub library_loaded: bool,
    pub history: Vec<Track>,
    pub editable: bool,
    pub library: Vec<Item>,
    pub edit_targets: Vec<Item>,
    pub tracks: Vec<Track>,
    pub queue: Vec<Track>,
    pub devices: Vec<Device>,
    pub playback: Playback,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub enum ReleaseLoad {
    Loading,
    Ready,
    Failed(String),
}

impl Snapshot {
    pub fn set_release_tracks(&mut self, album: &str, mut rows: Vec<Track>) {
        self.tracks
            .retain(|row| row.album_item.as_ref().is_none_or(|item| item.uri != album));
        for track in &mut rows {
            track.id = format!("{album}/{}", track.id);
        }
        self.tracks.extend(rows);
        self.release_loads.insert(album.into(), ReleaseLoad::Ready);
        self.stamp.playlist = self.stamp.playlist.wrapping_add(1);
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct Stamp {
    pub account: u64,
    pub engine: u64,
    pub catalog: u64,
    pub queue: u64,
    pub view: u64,
    pub playlist: u64,
    pub route: u64,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct Section {
    pub title: String,
    pub items: Vec<Item>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Item {
    pub uri: String,
    pub title: String,
    pub subtitle: String,
    pub kind: String,
    pub artwork: Option<String>,
    pub owner: Option<String>,
    pub description: String,
    pub date: String,
    pub category: String,
    pub children: Vec<Item>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Track {
    pub id: String,
    pub uri: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub artwork: Option<String>,
    pub duration: f64,
    pub removable: bool,
    pub unavailable: bool,
    pub occurrence: Option<String>,
    pub added: String,
    pub artists: Vec<Item>,
    pub album_item: Option<Item>,
    pub count: Option<u64>,
}

pub fn ordered_tracks<'a>(rows: &'a [Track], ids: &[String]) -> Vec<&'a Track> {
    let mut by_id = std::collections::HashMap::with_capacity(rows.len());
    for row in rows {
        by_id
            .entry(row.id.as_str())
            .and_modify(|entry| *entry = None)
            .or_insert(Some(row));
    }
    ids.iter()
        .filter_map(|id| by_id.remove(id.as_str()).flatten())
        .collect()
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub active: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(default, rename_all = "camelCase")]
pub struct Playback {
    pub uri: String,
    pub context: String,
    pub title: String,
    pub artist: String,
    pub artwork: Option<String>,
    pub duration: f64,
    pub position: f64,
    pub playing: bool,
    pub shuffle: bool,
    pub repeat: String,
    pub can_start: bool,
    pub can_toggle: bool,
    pub can_skip: bool,
    pub can_transfer: bool,
    pub device: String,
}

impl Default for Playback {
    fn default() -> Self {
        Self {
            uri: String::new(),
            context: String::new(),
            title: "Nothing playing".into(),
            artist: String::new(),
            artwork: None,
            duration: 0.0,
            position: 0.0,
            playing: false,
            shuffle: false,
            repeat: "off".into(),
            can_start: false,
            can_toggle: false,
            can_skip: false,
            can_transfer: false,
            device: String::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Route {
    Home,
    Search,
    Library,
    Likes,
    Detail(String),
    Discography(String),
}

impl Route {
    pub fn wire(&self) -> (&str, Option<&str>) {
        match self {
            Self::Home => ("home", None),
            Self::Search => ("search", None),
            Self::Library => ("library", None),
            Self::Likes => ("likes", None),
            Self::Detail(uri) => ("detail", Some(uri)),
            Self::Discography(uri) => ("discography", Some(uri)),
        }
    }
}

#[derive(Serialize)]
pub struct Request<'a> {
    pub action: &'a str,
    pub value: Option<&'a str>,
    pub target: Option<&'a str>,
    pub number: Option<f64>,
    pub stamp: Stamp,
}

pub fn grouped(number: u64) -> String {
    let digits = number.to_string();
    let mut text = String::new();
    for (index, ch) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            text.push(',');
        }
        text.push(ch);
    }
    text
}
