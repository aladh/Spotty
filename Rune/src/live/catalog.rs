use super::auth::{APP_VERSION, Failure, Result, Session, bounded};
use crate::model::{Item, Route, Section, Track};
use reqwest::{Method, Url};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::task::JoinSet;

// Persisted query documents from Spotty main. The response shape is pinned with each hash.
const SEARCH_TRACKS: (&str, &str) = (
    "searchTracks",
    "59ee4a659c32e9ad894a71308207594a65ba67bb6b632b183abe97303a51fa55",
);
const SEARCH_ALBUMS: (&str, &str) = (
    "searchAlbums",
    "5e7d2724fbef31a25f714844bf1313ffc748ebd4bd199eaad50628a4f246a7ab",
);
const SEARCH_ARTISTS: (&str, &str) = (
    "searchArtists",
    "72c8c7c1e789a9f11e261c4f9ae35a9465bbb90137c584428989573617b6c08d",
);
const SEARCH_PLAYLISTS: (&str, &str) = (
    "searchPlaylists",
    "af1730623dc1248b75a61a18bad1f47f1fc7eff802fb0676683de88815c958d8",
);
const GET_ALBUM: (&str, &str) = (
    "getAlbum",
    "b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10",
);
const QUERY_ARTIST_OVERVIEW: (&str, &str) = (
    "queryArtistOverview",
    "ae0e2958a4ab645b35ca19ac04d0495ae12d9c5d7b7286217674801a9aab281a",
);
const QUERY_ARTIST_DISCOGRAPHY_ALL: (&str, &str) = (
    "queryArtistDiscographyAll",
    "5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599",
);
const FETCH_PLAYLIST: (&str, &str) = (
    "fetchPlaylist",
    "86dde7b9d9356e2369414647cf6950cfed96e778e129cfdfc99aea6c1613b3b0",
);
const LIBRARY_V3: (&str, &str) = (
    "libraryV3",
    "390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455",
);
const FETCH_LIBRARY_TRACKS: (&str, &str) = (
    "fetchLibraryTracks",
    "087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240",
);
const HOME: (&str, &str) = (
    "home",
    "23e37f2e58d82d567f27080101d36609009d8c3676457b1086cb0acc55b72a5d",
);
const PROFILE_ATTRIBUTES: (&str, &str) = (
    "profileAttributes",
    "08ffb4730af3746e04a8301396f20875dbbce10c75243803091a9274eacc8ac0",
);
const ADD_TO_PLAYLIST: (&str, &str) = (
    "addToPlaylist",
    "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990",
);
const REMOVE_FROM_PLAYLIST: (&str, &str) = (
    "removeFromPlaylist",
    "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990",
);

const PARTNER: &str = "https://api-partner.spotify.com/pathfinder/v2/query";
const CONNECT: &str = "https://spclient.wg.spotify.com";
const ORIGIN: &str = "https://xpui.app.spotify.com";
const MAX_PAGES: usize = 500;
const MAX_LIBRARY_NODES: usize = 10_000;

#[derive(Clone, Default, Deserialize, Serialize, PartialEq)]
pub struct Page {
    pub title: String,
    pub item: Option<Item>,
    pub sections: Vec<Section>,
    pub tracks: Vec<Track>,
    pub about: Option<String>,
    #[serde(default)]
    pub search_errors: std::collections::BTreeMap<String, String>,
}

impl Page {
    pub fn retain_failed_search_categories(&mut self, previous: &Page) {
        if self.search_errors.contains_key("Songs") {
            self.tracks.clone_from(&previous.tracks);
        }
        for section in &previous.sections {
            if self.search_errors.contains_key(&section.title) {
                self.sections.push(section.clone());
            }
        }
    }
}

#[derive(Clone)]
pub struct Catalog(pub Arc<Session>);

impl Catalog {
    pub async fn read(&self, route: &Route, term: &str) -> Result<Page> {
        match route {
            Route::Home => self.home().await,
            Route::Search => self.search(term).await,
            Route::Library => self.library().await,
            Route::Likes => self.likes().await,
            Route::Detail(uri) => self.detail(uri).await,
            Route::Discography(uri) => self.discography(uri).await,
        }
    }

    pub async fn profile(&self) -> Result<(String, String)> {
        let data = self.query(PROFILE_ATTRIBUTES, json!({}), false).await?;
        let profile = entity(&data["me"]["profile"]);
        let owner = user_uri(profile).ok_or(Failure::Response)?;
        let name = string(profile, "/name")
            .or_else(|| string(profile, "/displayName"))
            .unwrap_or("Spotify")
            .to_owned();
        Ok((owner, name))
    }

    pub async fn playlists(&self) -> Result<Vec<Item>> {
        // Each traversal shares a global page and entry budget. Four requests can run at once.
        let pages = Arc::new(AtomicUsize::new(0));
        let nodes = Arc::new(AtomicUsize::new(0));
        let mut frontier = VecDeque::from([(String::new(), 0)]);
        let mut seen = HashSet::new();
        let mut children = HashMap::new();
        let mut work = JoinSet::new();
        loop {
            while work.len() < 4 {
                let Some((folder, depth)) = frontier.pop_front() else {
                    break;
                };
                let catalog = self.clone();
                let pages = Arc::clone(&pages);
                let nodes = Arc::clone(&nodes);
                work.spawn(async move {
                    let rows = catalog
                        .library_rows("Playlists", Some(folder.as_str()), &pages)
                        .await?;
                    if nodes.fetch_add(rows.len(), Ordering::Relaxed) + rows.len()
                        > MAX_LIBRARY_NODES
                    {
                        return Err(Failure::Response);
                    }
                    let items = rows
                        .iter()
                        .filter_map(|row| {
                            let entity = entity(&row["item"]);
                            item(entity).or_else(|| folder_item(entity))
                        })
                        .collect::<Vec<_>>();
                    Ok((folder, depth, items))
                });
            }
            let Some(done) = work.join_next().await else {
                break;
            };
            let (folder, depth, items) = done.map_err(|_| Failure::Response)??;
            for item in items.iter().filter(|item| item.kind == "Folder") {
                if depth >= 32 || !seen.insert(item.uri.clone()) {
                    return Err(Failure::Response);
                }
                frontier.push_back((item.uri.clone(), depth + 1));
            }
            children.insert(folder, items);
        }
        fn assemble(key: &str, children: &mut HashMap<String, Vec<Item>>) -> Vec<Item> {
            children
                .remove(key)
                .unwrap_or_default()
                .into_iter()
                .map(|mut item| {
                    if item.kind == "Folder" {
                        item.children = assemble(&item.uri, children);
                    }
                    item
                })
                .collect()
        }
        Ok(assemble("", &mut children))
    }

    async fn library_rows(
        &self,
        filter: &str,
        folder: Option<&str>,
        pages: &AtomicUsize,
    ) -> Result<Vec<Value>> {
        let (_, rows) = collect(|offset| async move {
            if pages.fetch_add(1, Ordering::Relaxed) >= MAX_PAGES { return Err(Failure::Response); }
            let mut vars = json!({
                "filters": [filter], "offset": offset, "limit": if folder.is_some() { 200 } else { 50 },
                "textFilter": "", "flatten": folder.is_none(), "expandedFolders": [],
                "includeFoldersWhenFlattening": false
            });
            if let Some(folder) = folder {
                vars["order"] = json!("Custom Order");
                if !folder.is_empty() { vars["folderUri"] = json!(folder); }
            }
            let data = self.query(LIBRARY_V3, vars, false).await?;
            page(Value::Null, &data["me"]["libraryV3"])
        }).await?;
        Ok(rows)
    }

    async fn library(&self) -> Result<Page> {
        let pages = AtomicUsize::new(0);
        let (albums, artists) = tokio::try_join!(
            self.library_rows("Albums", None, &pages),
            self.library_rows("Artists", None, &pages),
        )?;
        let section = |title: &str, rows: Vec<Value>| Section {
            title: title.into(),
            items: rows
                .iter()
                .filter_map(|row| item(entity(&row["item"])))
                .collect(),
        };
        Ok(Page {
            title: "Your Library".into(),
            sections: vec![section("Albums", albums), section("Artists", artists)],
            ..Page::default()
        })
    }

    async fn likes(&self) -> Result<Page> {
        let (_, rows) = collect(|offset| async move {
            let data = self
                .query(
                    FETCH_LIBRARY_TRACKS,
                    json!({"offset": offset, "limit": 50}),
                    false,
                )
                .await?;
            page(Value::Null, &data["me"]["library"]["tracks"])
        })
        .await?;
        let tracks = rows
            .iter()
            .enumerate()
            .filter_map(|(i, row)| {
                let entry = &row["track"];
                let mut track = track(entity(entry), string(entry, "/_uri"))?;
                track.id = format!("{i}:{}", track.uri);
                track.added = string(row, "/addedAt/isoString").unwrap_or_default().into();
                Some(track)
            })
            .collect();
        Ok(Page {
            title: "Liked Songs".into(),
            tracks,
            ..Page::default()
        })
    }

    async fn home(&self) -> Result<Page> {
        let time_zone = std::env::var("TZ")
            .ok()
            .filter(|tz| !tz.is_empty())
            .unwrap_or_else(|| "UTC".into());
        let data = self.query(HOME, json!({
            "timeZone": time_zone, "homeEndUserIntegration": "INTEGRATION_WEB_PLAYER", "sp_t": self.0.device
        }), false).await?;
        home_page(&data["home"])
    }

    async fn search(&self, term: &str) -> Result<Page> {
        let vars = json!({
            "searchTerm": term, "offset": 0, "limit": 30, "numberOfTopResults": 30,
            "includePreReleases": true, "includeArtistHasConcertsField": false, "includeAudiobooks": true,
            "includeAuthors": true, "includeEpisodeContentRatingsV2": false
        });
        let (tracks, albums, artists, playlists) = tokio::join!(
            self.query(SEARCH_TRACKS, vars.clone(), false),
            self.query(SEARCH_ALBUMS, vars.clone(), false),
            self.query(SEARCH_ARTISTS, vars.clone(), false),
            self.query(SEARCH_PLAYLISTS, vars, false),
        );
        let mut response = Page {
            title: "Search".into(),
            ..Page::default()
        };
        for (key, title, answer) in [
            ("tracksV2", "Songs", tracks),
            ("albumsV2", "Albums", albums),
            ("artists", "Artists", artists),
            ("playlists", "Playlists", playlists),
        ] {
            match answer
                .and_then(|data| list(&data["searchV2"][key], "/items").map(|items| items.to_vec()))
            {
                Ok(rows) if key == "tracksV2" => {
                    response.tracks = rows
                        .iter()
                        .filter_map(|row| track(entity(row), None))
                        .collect()
                }
                Ok(rows) => response.sections.push(Section {
                    title: title.into(),
                    items: rows.iter().filter_map(|row| item(entity(row))).collect(),
                }),
                Err(error @ (Failure::Revoked | Failure::Retired | Failure::Status(401 | 403))) => {
                    return Err(error);
                }
                Err(error) => {
                    response
                        .search_errors
                        .insert(title.into(), error.to_string());
                }
            }
        }
        Ok(response)
    }

    async fn detail(&self, uri: &str) -> Result<Page> {
        match kind(uri) {
            Some("album") => {
                self.track_detail(uri, GET_ALBUM, "albumUnion", "tracksV2", "Album")
                    .await
            }
            Some("playlist") => {
                self.track_detail(uri, FETCH_PLAYLIST, "playlistV2", "content", "Playlist")
                    .await
            }
            Some("artist") => self.artist(uri).await,
            _ => Err(Failure::Response),
        }
    }

    async fn track_detail(
        &self,
        uri: &str,
        op: (&str, &str),
        key: &str,
        collection: &str,
        typename: &str,
    ) -> Result<Page> {
        let (header, rows) = collect(|offset| async move {
            let vars = if typename == "Playlist" {
                json!({ "uri": uri, "offset": offset, "limit": 300, "enableWatchFeedEntrypoint": false })
            } else { json!({"uri":uri, "locale":"", "offset":offset,"limit":300}) };
            let data = self.query(op, vars, false).await?;
            let union = verified(&data[key], uri, typename)?;
            let header = if offset == 0 { union.clone() } else { Value::Null };
            page(header, &union[collection])
        }).await?;
        let item = item(&header).ok_or(Failure::Response)?;
        let tracks = detail_tracks(&rows, &item, typename == "Playlist");
        Ok(Page {
            title: item.title.clone(),
            item: Some(item),
            tracks,
            ..Page::default()
        })
    }

    async fn artist(&self, uri: &str) -> Result<Page> {
        let data = self
            .query(
                QUERY_ARTIST_OVERVIEW,
                json!({"uri":uri, "locale":"", "offset":0, "limit":100}),
                false,
            )
            .await?;
        let artist = verified(&data["artistUnion"], uri, "Artist")?;
        let mut identity = item(artist).ok_or(Failure::Response)?;
        identity.artwork = picture(&artist["headerImage"]).or(identity.artwork);
        if let Some(listeners) = artist["stats"]["monthlyListeners"].as_u64() {
            identity.subtitle = format!("{} monthly listeners", grouped(listeners));
        }
        let discography = &artist["discography"];
        let release_rows = [
            "/popularReleasesAlbums/items",
            "/all/items",
            "/albums/items",
            "/singles/items",
            "/compilations/items",
        ]
        .into_iter()
        .flat_map(|key| list(discography, key).unwrap_or_default().iter());
        let mut sections = vec![Section {
            title: "Discography".into(),
            items: releases(release_rows),
        }];
        for (title, key) in [
            ("Featuring", "/relatedContent/featuringV2/items"),
            ("Discovered on", "/relatedContent/discoveredOnV2/items"),
            ("Artist Playlists", "/relatedContent/artistPlaylists/items"),
        ] {
            let items = list(artist, key)
                .unwrap_or_default()
                .iter()
                .filter_map(|row| item(entity(row)))
                .collect::<Vec<_>>();
            if !items.is_empty() {
                sections.push(Section {
                    title: title.into(),
                    items,
                });
            }
        }
        let tracks = list(artist, "/discography/topTracks/items")
            .unwrap_or_default()
            .iter()
            .filter_map(|row| {
                let record = entity(&row["track"]);
                let mut track = track(record, None)?;
                track.count = string(row, "/playcount")
                    .or_else(|| string(record, "/playcount"))
                    .and_then(|value| value.parse().ok());
                Some(track)
            })
            .collect();
        Ok(Page {
            title: identity.title.clone(),
            item: Some(identity),
            sections,
            tracks,
            about: string(artist, "/profile/biography/text").map(clean_description),
            ..Page::default()
        })
    }

    async fn discography(&self, uri: &str) -> Result<Page> {
        let (_, rows) = collect(|offset| async move {
            let data = self
                .query(
                    QUERY_ARTIST_DISCOGRAPHY_ALL,
                    json!({"uri":uri, "locale":"", "offset":offset, "limit":100}),
                    false,
                )
                .await?;
            let artist = verified(&data["artistUnion"], uri, "Artist")?;
            page(Value::Null, &artist["discography"]["all"])
        })
        .await?;
        Ok(Page {
            title: "Discography".into(),
            sections: vec![Section {
                title: String::new(),
                items: releases(rows.iter()),
            }],
            ..Page::default()
        })
    }

    pub async fn edit_playlist(
        &self,
        uri: &str,
        added: &[String],
        removed: &[String],
        admit: &(impl Fn() -> bool + Sync),
    ) -> Result<()> {
        if !admit() {
            return Err(Failure::Retired);
        }
        if kind(uri) != Some("playlist") {
            return Err(Failure::PlaylistAuthority);
        }
        let (op, vars, key, expected) = if !added.is_empty() && removed.is_empty() {
            if added.iter().any(|uri| kind(uri) != Some("track")) {
                return Err(Failure::PlaylistAuthority);
            }
            let playlist = self.query(
                FETCH_PLAYLIST,
                json!({"uri": uri, "offset": 0, "limit": 1, "enableWatchFeedEntrypoint": false}),
                false,
            );
            let ((account, _), data) = tokio::try_join!(self.profile(), playlist)?;
            let playlist = verified(&data["playlistV2"], uri, "Playlist")?;
            if user_uri(&playlist["ownerV2"]["data"]).as_deref() != Some(account.as_str()) {
                return Err(Failure::PlaylistAuthority);
            }
            (
                ADD_TO_PLAYLIST,
                json!({"playlistUri": uri, "playlistItemUris": added,
             "newPosition":{"moveType":"BOTTOM_OF_PLAYLIST"}}),
                "addItemsToPlaylist",
                "AddItemsToPlaylistPayload",
            )
        } else if added.is_empty() && !removed.is_empty() {
            let ((account, _), playlist) = tokio::try_join!(self.profile(), self.detail(uri))?;
            let owner = playlist
                .item
                .as_ref()
                .and_then(|item| item.owner.as_deref());
            if owner != Some(account.as_str()) || !current_occurrences(&playlist.tracks, removed) {
                return Err(Failure::PlaylistAuthority);
            }
            (
                REMOVE_FROM_PLAYLIST,
                json!({"playlistUri": uri, "uids": removed}),
                "removeItemsFromPlaylist",
                "RemoveItemsFromPlaylistPayload",
            )
        } else {
            return Err(Failure::Response);
        };
        let data = self.query_authorized(op, vars, true, admit).await?;
        if string(&data[key], "/__typename") == Some(expected) {
            Ok(())
        } else {
            Err(Failure::Uncertain)
        }
    }

    async fn query(&self, op: (&str, &str), variables: Value, mutation: bool) -> Result<Value> {
        self.query_authorized(op, variables, mutation, &|| true)
            .await
    }

    async fn query_authorized(
        &self,
        (operation, hash): (&str, &str),
        variables: Value,
        mutation: bool,
        admit: &(impl Fn() -> bool + Sync),
    ) -> Result<Value> {
        let response = self
            .signed(
                Method::POST,
                PARTNER,
                Some(json!({
                    "operationName": operation, "variables": variables,
                    "extensions": {"persistedQuery": {"version":1, "sha256Hash":hash}}
                })),
                !mutation,
                admit,
            )
            .await?;
        let mut json: Value = serde_json::from_slice(&response).map_err(|_| Failure::Response)?;
        if json["errors"]
            .as_array()
            .is_some_and(|errors| !errors.is_empty())
        {
            return Err(if mutation {
                Failure::Uncertain
            } else {
                Failure::Response
            });
        }
        json.get_mut("data")
            .map(Value::take)
            .filter(Value::is_object)
            .ok_or(Failure::Response)
    }

    pub async fn connect(
        &self,
        from: &str,
        to: &str,
        mut command: Value,
        admit: &(impl Fn() -> bool + Sync),
    ) -> Result<()> {
        let mut url = Url::parse(CONNECT).map_err(|_| Failure::Response)?;
        url.path_segments_mut()
            .map_err(|_| Failure::Response)?
            .extend([
                "connect-state",
                "v1",
                "player",
                "command",
                "from",
                from,
                "to",
                to,
            ]);
        let random_id = || format!("{:032x}", rand::random::<u128>());
        command["logging_params"] = json!({"command_id":random_id()});
        self.signed(
            Method::POST,
            url.as_str(),
            Some(json!({
                "command":command, "connection_type":"wlan", "intent_id":random_id()
            })),
            false,
            admit,
        )
        .await?;
        Ok(())
    }

    pub async fn web_queue(&self) -> Result<Vec<Track>> {
        let response = self
            .signed(
                Method::GET,
                "https://api.spotify.com/v1/me/player/queue",
                None,
                true,
                &|| true,
            )
            .await?;
        let data: Value = serde_json::from_slice(&response).map_err(|_| Failure::Response)?;
        let entries = list(&data, "/queue")?;
        Ok(entries
            .iter()
            .enumerate()
            .filter_map(|(index, entry)| {
                let uri = string(entry, "/uri")?;
                if kind(uri)? != "track" {
                    return None;
                }
                let artists = list(entry, "/artists")
                    .unwrap_or_default()
                    .iter()
                    .filter_map(|artist| string(artist, "/name"))
                    .collect::<Vec<_>>();
                let album = &entry["album"];
                let artwork = list(album, "/images")
                    .ok()
                    .and_then(|images| images.first())
                    .and_then(|image| string(image, "/url"));
                Some(Track {
                    id: format!("web-{index}-{uri}"),
                    uri: uri.into(),
                    title: string(entry, "/name")?.into(),
                    artist: artists.join(", "),
                    album: string(album, "/name").unwrap_or_default().into(),
                    artwork: artwork.map(str::to_owned),
                    duration: entry["duration_ms"].as_f64().unwrap_or_default() / 1000.0,
                    ..Track::default()
                })
            })
            .collect())
    }

    pub async fn metadata(&self, uri: &str) -> Result<Track> {
        let digits = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
        let id = uri
            .strip_prefix("spotify:track:")
            .ok_or(Failure::Response)?;
        let n = id
            .chars()
            .try_fold(0_u128, |n, c| {
                n.checked_mul(62)?.checked_add(digits.find(c)? as u128)
            })
            .ok_or(Failure::Response)?;
        let url = format!("{CONNECT}/metadata/4/track/{n:032x}?market=from_token");
        let response = self.signed(Method::GET, &url, None, true, &|| true).await?;
        let record: Value = serde_json::from_slice(&response).map_err(|_| Failure::Response)?;
        let title = string(&record, "/name")
            .ok_or(Failure::Response)?
            .to_owned();
        let artists: Vec<_> = list(&record, "/artist")
            .unwrap_or_default()
            .iter()
            .filter_map(|a| string(a, "/name"))
            .collect();
        let album = &record["album"];
        let artwork = list(album, "/cover_group/image")
            .or_else(|_| list(album, "/coverGroup/image"))
            .ok()
            .and_then(|images| {
                images
                    .iter()
                    .max_by_key(|i| i["width"].as_u64().unwrap_or(0))
            })
            .and_then(|image| string(image, "/file_id").or_else(|| string(image, "/fileId")))
            .filter(|id| id.bytes().all(|c| c.is_ascii_hexdigit()))
            .map(|id| format!("https://i.scdn.co/image/{id}"));
        Ok(Track {
            id: uri.into(),
            uri: uri.into(),
            title,
            artist: artists.join(", "),
            artwork,
            album: string(album, "/name").unwrap_or_default().into(),
            duration: record["duration"].as_f64().unwrap_or(0.0) / 1000.0,
            ..Track::default()
        })
    }

    async fn signed(
        &self,
        method: Method,
        url: &str,
        body: Option<Value>,
        read_only: bool,
        admit: &(impl Fn() -> bool + Sync),
    ) -> Result<Vec<u8>> {
        let (mut bearer, mut client) =
            tokio::try_join!(self.0.access(None), self.0.client_token(None))?;
        let mut renewed = false;
        for attempt in 0..3 {
            self.0.check()?;
            if !admit() {
                return Err(Failure::Retired);
            }
            let mut request = self
                .0
                .http
                .request(method.clone(), url)
                .bearer_auth(&*bearer)
                .header("Client-Token", &client)
                .header("App-Platform", "OSX_ARM64")
                .header("Spotify-App-Version", APP_VERSION)
                .header("User-Agent", format!("Spotify/{APP_VERSION} macOS"))
                .header("Origin", ORIGIN)
                .header("Referer", ORIGIN)
                .header("Accept", "application/json");
            if let Some(body) = &body {
                request = request.json(body);
            }
            let response = match request.send().await {
                Ok(response) => response,
                Err(_) if read_only && attempt < 2 => {
                    tokio::time::sleep(Duration::from_millis(200 * (attempt + 1))).await;
                    continue;
                }
                Err(_) => {
                    return Err(if read_only {
                        Failure::Network
                    } else {
                        Failure::Uncertain
                    });
                }
            };
            let status = response.status().as_u16();
            if status == 401 && !renewed && attempt < 2 {
                (bearer, client) = tokio::try_join!(
                    self.0.access(Some(&bearer)),
                    self.0.client_token(Some(&client))
                )?;
                renewed = true;
                continue;
            }
            if read_only && matches!(status, 429 | 500..=504) && attempt < 2 {
                let delay = response
                    .headers()
                    .get("Retry-After")
                    .and_then(|value| value.to_str().ok())
                    .and_then(|value| value.parse::<u64>().ok());
                if delay.is_some_and(|delay| delay > 3) {
                    return Err(Failure::Status(status));
                }
                tokio::time::sleep(
                    delay
                        .map(Duration::from_secs)
                        .unwrap_or(Duration::from_millis(250 * (attempt + 1))),
                )
                .await;
                continue;
            }
            self.0.check()?;
            if !(200..300).contains(&status) {
                return Err(Failure::Status(status));
            }
            let bytes = bounded(response, 16 * 1024 * 1024).await?;
            self.0.check()?;
            return Ok(bytes);
        }
        Err(Failure::Network)
    }
}

fn string<'a>(record: &'a Value, pointer: &str) -> Option<&'a str> {
    record.pointer(pointer)?.as_str().filter(|s| !s.is_empty())
}

fn list<'a>(record: &'a Value, pointer: &str) -> Result<&'a [Value]> {
    record
        .pointer(pointer)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .ok_or(Failure::Response)
}

fn entity(record: &Value) -> &Value {
    record
        .pointer("/item/data")
        .or_else(|| record.get("data"))
        .filter(|value| value.is_object())
        .unwrap_or(record)
}

fn kind(uri: &str) -> Option<&str> {
    let (kind, id) = uri.strip_prefix("spotify:")?.split_once(':')?;
    (!id.is_empty() && id.bytes().all(|c| c.is_ascii_alphanumeric())).then_some(kind)
}

fn user_uri(record: &Value) -> Option<String> {
    fn normalize(value: &str) -> Option<String> {
        let value = value.trim();
        let id = value.strip_prefix("spotify:user:").unwrap_or(value);
        (!id.is_empty() && !id.contains(':')).then(|| format!("spotify:user:{id}"))
    }
    string(record, "/uri")
        .and_then(normalize)
        .or_else(|| string(record, "/username").and_then(normalize))
}

fn current_occurrences(rows: &[Track], uids: &[String]) -> bool {
    let mut available: HashSet<_> = rows
        .iter()
        .filter_map(|row| row.occurrence.as_deref())
        .collect();
    uids.iter().all(|uid| available.remove(uid.as_str()))
}

fn picture(record: &Value) -> Option<String> {
    [
        "/sources",
        "/items/0/sources",
        "/image/sources",
        "/image/data/sources",
        "/data/sources",
    ]
    .into_iter()
    .filter_map(|key| list(record, key).ok())
    .flatten()
    .max_by_key(|source| {
        source["width"]
            .as_u64()
            .or(source["maxWidth"].as_u64())
            .unwrap_or(0)
    })
    .and_then(|source| string(source, "/url"))
    .map(str::to_owned)
}

fn folder_item(value: &Value) -> Option<Item> {
    let uri = string(value, "/uri")?;
    let parts: Vec<_> = uri.split(':').collect();
    let matches = matches!(
        parts.as_slice(),
        ["spotify", "folder", _] | ["spotify", "user", _, "folder", _]
    );
    if !matches || parts.iter().any(|part| part.is_empty()) {
        return None;
    }
    Some(Item {
        uri: uri.into(),
        title: string(value, "/name").unwrap_or("Folder").into(),
        kind: "Folder".into(),
        ..Item::default()
    })
}

fn item(value: &Value) -> Option<Item> {
    let uri = string(value, "/uri")?;
    let (kind, name, subtitle, art) = match kind(uri)? {
        "playlist" => (
            "Playlist",
            "/name",
            string(value, "/ownerV2/data/name").or_else(|| string(value, "/ownerV2/data/username")),
            picture(&value["images"]),
        ),
        "album" => (
            "Album",
            "/name",
            string(value, "/artists/items/0/profile/name"),
            picture(&value["coverArt"]),
        ),
        "artist" => (
            "Artist",
            "/profile/name",
            None,
            picture(&value["visuals"]["avatarImage"]),
        ),
        "track" => (
            "Track",
            "/name",
            string(value, "/artists/items/0/profile/name"),
            picture(&value["albumOfTrack"]["coverArt"]),
        ),
        _ => return None,
    };
    Some(Item {
        uri: uri.into(),
        title: string(value, name)
            .or_else(|| string(value, "/name"))?
            .into(),
        subtitle: subtitle.unwrap_or_default().into(),
        kind: kind.into(),
        artwork: art,
        owner: user_uri(&value["ownerV2"]["data"]),
        description: string(value, "/description")
            .map(clean_description)
            .unwrap_or_default(),
        date: date(value),
        category: string(value, "/type").unwrap_or_default().into(),
        ..Item::default()
    })
}

fn date(value: &Value) -> String {
    if let Some(date) = string(value, "/date/isoString") {
        return date.split('T').next().unwrap_or_default().into();
    }
    let date = &value["date"];
    match (
        date["year"].as_u64(),
        date["month"].as_u64(),
        date["day"].as_u64(),
    ) {
        (Some(y), Some(m), Some(d)) => format!("{y:04}-{m:02}-{d:02}"),
        (Some(y), _, _) => format!("{y:04}"),
        _ => String::new(),
    }
}

fn track(value: &Value, uri: Option<&str>) -> Option<Track> {
    let uri = uri.or_else(|| string(value, "/uri"))?;
    if kind(uri)? != "track" {
        return None;
    }
    let album = &value["albumOfTrack"];
    let artists = list(value, "/artists/items").unwrap_or_default();
    let names: Vec<_> = artists
        .iter()
        .filter_map(|a| string(a, "/profile/name"))
        .collect();
    Some(Track {
        id: uri.into(),
        uri: uri.into(),
        title: string(value, "/name")?.into(),
        artist: names.join(", "),
        album: string(album, "/name").unwrap_or_default().into(),
        artwork: picture(&album["coverArt"]),
        duration: value
            .pointer("/trackDuration/totalMilliseconds")
            .or_else(|| value.pointer("/duration/totalMilliseconds"))
            .and_then(Value::as_f64)
            .filter(|duration| *duration >= 0.0)
            .unwrap_or_default()
            / 1000.0,
        artists: artists.iter().filter_map(item).collect(),
        album_item: item(album),
        unavailable: value
            .pointer("/playability/playable")
            .and_then(Value::as_bool)
            == Some(false),
        ..Track::default()
    })
}

fn detail_tracks(rows: &[Value], item: &Item, playlist: bool) -> Vec<Track> {
    let mut counts = HashMap::new();
    if playlist {
        for uid in rows.iter().filter_map(|row| string(row, "/uid")) {
            *counts.entry(uid).or_insert(0) += 1;
        }
    }
    rows.iter()
        .enumerate()
        .filter_map(|(i, row)| {
            let record = if playlist {
                entity(&row["itemV2"])
            } else {
                &row["track"]
            };
            let mut track = track(record, None)?;
            let uid = string(row, "/uid").filter(|uid| {
                !uid.trim().is_empty() && *uid != track.uri && counts.get(uid) == Some(&1)
            });
            track.id = uid.map_or_else(|| format!("{i}:{}", track.uri), |uid| format!("uid:{uid}"));
            track.occurrence = uid.map(str::to_owned);
            track.added = string(row, "/addedAt/isoString").unwrap_or_default().into();
            if !playlist {
                track.album.clone_from(&item.title);
                track.album_item = Some(item.clone());
                track.artwork.clone_from(&item.artwork);
                track.count = string(record, "/playcount").and_then(|value| value.parse().ok());
            }
            Some(track)
        })
        .collect()
}

fn home_page(home: &Value) -> Result<Page> {
    if string(home, "/__typename") != Some("HomeResponsePayload") {
        return Err(Failure::Response);
    }
    let sections = list(home, "/sectionContainer/sections/items")?
        .iter()
        .map(|section| {
            let mut items = Vec::new();
            for entry in list(section, "/sectionItems/items").unwrap_or_default() {
                let content = &entry["content"];
                if let Some(item) = item(entity(content)) {
                    items.push(item);
                } else if string(content, "/__typename") == Some("ListResponseWrapper") {
                    items.extend(
                        list(entity(content), "/items/items")
                            .unwrap_or_default()
                            .iter()
                            .filter_map(|entry| {
                                let data = entity(&entry["entity"]);
                                let uri = string(data, "/uri")?;
                                let kind = match kind(uri)? {
                                    "album" => "Album",
                                    "artist" => "Artist",
                                    "playlist" => "Playlist",
                                    _ => return None,
                                };
                                Some(Item {
                                    uri: uri.into(),
                                    title: string(data, "/identityTrait/name")?.into(),
                                    kind: kind.into(),
                                    subtitle: string(
                                        data,
                                        "/identityTrait/contributors/items/0/name",
                                    )
                                    .unwrap_or_default()
                                    .into(),
                                    artwork: picture(
                                        &data["visualIdentityTrait"]["squareCoverImage"],
                                    ),
                                    ..Item::default()
                                })
                            }),
                    );
                }
            }
            Section {
                title: string(section, "/data/title/transformedLabel")
                    .unwrap_or_default()
                    .into(),
                items,
            }
        })
        .filter(|section| !section.items.is_empty())
        .collect();
    Ok(Page {
        title: string(home, "/greeting/transformedLabel")
            .unwrap_or("Home")
            .into(),
        sections,
        ..Page::default()
    })
}

fn releases<'a>(rows: impl Iterator<Item = &'a Value>) -> Vec<Item> {
    let mut seen = HashSet::new();
    rows.flat_map(|entry| {
        list(entry, "/releases/items")
            .unwrap_or_else(|_| std::slice::from_ref(entry))
            .iter()
    })
    .filter_map(item)
    .filter(|item| seen.insert(item.uri.clone()))
    .collect()
}

type PageParts = (Value, Vec<Value>, Option<usize>);

fn page(header: Value, value: &Value) -> Result<PageParts> {
    let rows = list(value, "/items")?;
    let total = match value.get("totalCount") {
        None | Some(Value::Null) => None,
        Some(count) => Some(
            count
                .as_u64()
                .and_then(|count| usize::try_from(count).ok())
                .ok_or(Failure::Response)?,
        ),
    };
    Ok((header, rows.to_vec(), total))
}

async fn collect<F: std::future::Future<Output = Result<PageParts>> + Send>(
    mut load: impl FnMut(usize) -> F + Send,
) -> Result<(Value, Vec<Value>)> {
    let mut header = Value::Null;
    let mut items = Vec::new();
    let mut expected = None;
    for index in 0..MAX_PAGES {
        let (metadata, mut rows, total) = load(items.len()).await?;
        if index == 0 {
            header = metadata;
            expected = total;
        }
        if total != expected {
            return Err(Failure::Response);
        }
        let empty = rows.is_empty();
        items.append(&mut rows);
        match expected {
            Some(total) if total == items.len() => return Ok((header, items)),
            Some(total) if total < items.len() || empty => return Err(Failure::Response),
            None if empty => return Ok((header, items)),
            _ => {}
        }
    }
    Err(Failure::Response)
}

fn verified<'a>(entity: &'a Value, uri: &str, typename: &str) -> Result<&'a Value> {
    if string(entity, "/__typename") != Some(typename)
        || entity
            .get("uri")
            .is_some_and(|value| !value.is_null() && value.as_str() != Some(uri))
    {
        return Err(Failure::Response);
    }
    Ok(entity)
}

fn clean_description(value: &str) -> String {
    let mut inside_tag = false;
    let mut plain = String::new();
    for c in value.chars() {
        match c {
            '<' => inside_tag = true,
            '>' if inside_tag => inside_tag = false,
            c if !inside_tag => plain.push(c),
            _ => {}
        }
    }
    plain
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn grouped(number: u64) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(text: &str) -> Value {
        serde_json::from_str(text).unwrap()
    }

    #[test]
    fn search_keeps_only_failed_categories_from_the_same_query() {
        let previous = Page {
            tracks: vec![Track::default()],
            sections: ["Artists", "Albums"]
                .map(|s| Section {
                    title: s.to_owned(),
                    items: vec![Item::default()],
                })
                .into(),
            ..Page::default()
        };
        let mut retry = Page {
            search_errors: [
                ("Songs".into(), "offline".into()),
                ("Albums".into(), "offline".into()),
            ]
            .into(),
            sections: vec![Section {
                title: "Artists".into(),
                items: Vec::new(),
            }],
            ..Page::default()
        };
        retry.retain_failed_search_categories(&previous);
        assert_eq!(retry.tracks.len(), 1);
        assert!(retry.sections[0].items.is_empty());
        assert_eq!(retry.sections[1].title, "Albums");
        assert_eq!(retry.sections[1].items.len(), 1);
    }

    #[test]
    fn decodes_main_fixtures_and_keeps_catalog_identity() {
        let data = fixture(include_str!(
            "../../../Tests/SpottyGatewayTests/Fixtures/home.json"
        ));
        let home = home_page(&data["data"]["home"]).unwrap();
        assert_eq!(home.title, "Good afternoon");
        assert!(!home.sections.is_empty());
        let data = fixture(include_str!(
            "../../../Tests/SpottyGatewayTests/Fixtures/search-tracks.json"
        ));
        let rows = list(&data["data"]["searchV2"]["tracksV2"], "/items").unwrap();
        let row = track(entity(&rows[0]), None).unwrap();
        assert_eq!(row.id, row.uri);
        let data = fixture(include_str!(
            "../../../Tests/SpottyGatewayTests/Fixtures/album.json"
        ));
        assert_eq!(
            item(&data["data"]["albumUnion"]).unwrap().title,
            "Fixture Album"
        );
    }

    #[test]
    fn playlist_removal_uids_are_proven_against_all_returned_rows() {
        let rows = json!([
            {"uid": "shared", "itemV2": {"data": {"uri": "spotify:track:A", "name": "A"}}},
            {"uid": "shared", "itemV2": {"data": {"uri": "spotify:episode:E", "name": "E"}}},
            {"uid": "unique", "itemV2": {"data": {"uri": "spotify:track:A", "name": "A"}}},
            {"uid": "spotify:track:B", "itemV2": {"data": {"uri": "spotify:track:B", "name": "B"}}},
            {"uid": " ", "itemV2": {"data": {"uri": "spotify:track:C", "name": "C", "playability": {"playable": false}}}}
        ]);
        let tracks = detail_tracks(rows.as_array().unwrap(), &Item::default(), true);
        assert_eq!(tracks.len(), 4);
        assert_eq!(tracks[0].uri, tracks[1].uri);
        assert_ne!(tracks[0].id, tracks[1].id);
        assert_eq!(tracks[0].occurrence, None);
        assert_eq!(tracks[1].occurrence.as_deref(), Some("unique"));
        assert_eq!(tracks[2].occurrence, None);
        assert_eq!(tracks[3].occurrence, None);
        assert!(tracks[3].unavailable);
        assert!(current_occurrences(&tracks, &["unique".into()]));
        assert!(!current_occurrences(&tracks, &["shared".into()]));
        assert!(!current_occurrences(
            &tracks,
            &["unique".into(), "unique".into()]
        ));
        assert_eq!(
            user_uri(&json!({"uri": "spotify:user:listener"})).as_deref(),
            Some("spotify:user:listener")
        );
        assert_eq!(
            user_uri(&json!({"uri": "spotify:playlist:unrelated"})),
            None
        );
    }

    #[test]
    fn collection_pages_reject_unknown_unions_and_malformed_counts() {
        let uri = "spotify:album:fixture";
        assert!(verified(&json!({"uri": uri}), uri, "Album").is_err());
        assert!(verified(&json!({"__typename": "Album", "uri": 12}), uri, "Album").is_err());
        assert!(verified(&json!({"__typename": "Album"}), uri, "Album").is_ok());
        assert!(page(Value::Null, &json!({"items": [], "totalCount": "unknown"})).is_err());
    }

    #[tokio::test]
    async fn pages_advance_by_observed_count_and_reject_partial_collections() {
        let result = collect(|offset| async move {
            match offset {
                0 => Ok((Value::Null, vec![json!(1), json!(2)], Some(3))),
                2 => Ok((Value::Null, vec![json!(3)], Some(3))),
                _ => unreachable!(),
            }
        })
        .await
        .unwrap();
        assert_eq!(result.1, [json!(1), json!(2), json!(3)]);
        assert!(
            collect(|_| async { Ok((Value::Null, vec![], Some(5))) })
                .await
                .is_err()
        );
    }
}
