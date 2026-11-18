mod audio;
mod auth;
mod catalog;
mod intent;
#[cfg(target_os = "macos")]
mod media;
mod playback_thread;
#[cfg(target_os = "macos")]
pub use media::Media;
#[cfg(target_os = "macos")]
mod power;
#[cfg(target_os = "macos")]
pub use power::PowerObserver;

use crate::model::*;
use crate::playback::client as engine;
use audio::Audio;
use auth::{Failure, Grant, Result, Session, Storage};
use catalog::{Catalog, Page};
use intent::{Match, Occurrence, Pending, ResumeTarget};
use playback_thread::PlaybackThread;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::{
    sync::mpsc,
    task::{AbortHandle, JoinSet},
};

pub struct Live {
    send: mpsc::UnboundedSender<Input>,
    share: Arc<Mutex<Updates>>,
}

#[derive(Default)]
pub struct Updates {
    pub snapshot: Option<Snapshot>,
    pub timing: Option<(u64, String, f64)>,
    pub artwork: Vec<(u64, String, Option<Artwork>)>,
}

impl Live {
    pub fn start(waker: rune::Waker) -> Self {
        let (send, receive) = mpsc::unbounded_channel();
        let share = Arc::new(Mutex::new(Updates::default()));
        let output = Publisher {
            data: Arc::clone(&share),
            waker,
        };
        let inbox = send.clone();
        let failure = output.clone();
        let spawned = std::thread::Builder::new()
            .name("Spotty session".into())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(4)
                    .enable_all()
                    .build();
                let result = runtime
                    .map_err(|_| Failure::Network)
                    .and_then(|runtime| runtime.block_on(run(inbox, receive, output)));
                if let Err(error) = result {
                    failure.snapshot(Snapshot {
                        phase: "unavailable".into(),
                        status: error.to_string(),
                        ..Snapshot::default()
                    });
                }
            });
        if spawned.is_err()
            && let Ok(mut updates) = share.lock()
        {
            updates.snapshot = Some(Snapshot {
                phase: "unavailable".into(),
                status: "Spotty couldn’t start.".into(),
                ..Snapshot::default()
            });
        }
        Self { send, share }
    }

    pub fn updates(&self) -> Updates {
        self.share
            .lock()
            .map(|mut updates| std::mem::take(&mut *updates))
            .unwrap_or_default()
    }

    pub fn command(&self, request: &Request<'_>) {
        let _ = self.send.send(Input::Command(Command {
            action: request.action.into(),
            value: request.value.map(str::to_owned),
            target: request.target.map(str::to_owned),
            number: request.number,
            stamp: request.stamp,
        }));
    }

    pub fn artwork(&self, account: u64, address: String) {
        let _ = self.send.send(Input::Artwork(account, address));
    }

    #[cfg(target_os = "macos")]
    pub fn observe_power(&self) -> PowerObserver {
        let send = self.send.clone();
        PowerObserver::new(move |event| {
            let _ = send.send(Input::Power(event));
        })
    }

    pub fn shutdown(&self) {
        let (done, wait) = std::sync::mpsc::sync_channel(1);
        if self.send.send(Input::Shutdown(done)).is_ok() {
            let _ = wait.recv_timeout(Duration::from_secs(10));
        }
    }
}

#[derive(Clone)]
struct Publisher {
    data: Arc<Mutex<Updates>>,
    waker: rune::Waker,
}

impl Publisher {
    fn snapshot(&self, snapshot: Snapshot) {
        if let Ok(mut shared) = self.data.lock() {
            shared.snapshot = Some(snapshot);
            shared.timing = None;
        }
        (self.waker)();
    }
    fn timing(&self, account: u64, uri: &str, position: f64) {
        if let Ok(mut shared) = self.data.lock() {
            shared.timing = Some((account, uri.into(), position));
        }
        (self.waker)();
    }
    fn artwork(&self, account: u64, url: String, bytes: Option<Artwork>) {
        if let Ok(mut shared) = self.data.lock() {
            shared.artwork.push((account, url, bytes));
        }
        (self.waker)();
    }
}

struct Command {
    action: String,
    value: Option<String>,
    target: Option<String>,
    number: Option<f64>,
    stamp: Stamp,
}
enum Input {
    Command(Command),
    Observe(engine::Observation),
    #[cfg(target_os = "macos")]
    Power(power::Event),
    Artwork(u64, String),
    #[cfg(target_os = "macos")]
    Media(media::MediaInput),
    Shutdown(std::sync::mpsc::SyncSender<()>),
}

pub struct Artwork {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    pub tint: [u8; 3],
}

enum Work {
    Grant(u64, Result<Grant>),
    PreparedGrant(u64, Result<Grant>),
    Engine(u64, StartResult),
    #[cfg(target_os = "macos")]
    Wake(u64, std::result::Result<(), engine::CommandError>),
    Page(u64, u64, Route, Result<Page>),
    Release(u64, u64, String, Result<Page>),
    Library(u64, Result<Vec<Item>>),
    Profile(u64, Result<(String, String)>),
    Track(u64, String, Result<Track>),
    QueueFallback(u64, Result<Vec<Track>>),
    Action(u64, u64, Result<ActionReceipt>),
    PlaylistEdit(u64, String, Result<()>),
    Art(u64, String, Option<Artwork>),
    Retired(u64, Retirement, Result<()>),
}

#[derive(Default)]
struct ActionReceipt {
    notice: Option<String>,
    sent_partial: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Retirement {
    Reauthenticate,
    SignOut,
}

enum StartResult {
    Started,
    NeedsSignIn,
    Failed(Failure),
}

impl StartResult {
    fn from_playback(result: std::result::Result<(), engine::CommandError>) -> Self {
        match result {
            Ok(()) => Self::Started,
            Err(engine::CommandError::CredentialsRejected) => Self::NeedsSignIn,
            Err(engine::CommandError::Superseded) => Self::Failed(Failure::Retired),
            Err(_) => Self::Failed(Failure::Network),
        }
    }
}

/// A restored AP session can fail transiently during wake or network attachment. Wait
/// off the command lane; each attempt still validates its account on that lane.
async fn initialize_with_retry<F, Fut>(
    restored: bool,
    mut initialize: F,
) -> std::result::Result<(), engine::CommandError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = std::result::Result<(), engine::CommandError>>,
{
    let mut result = initialize().await;
    if restored {
        for delay in [1, 3] {
            if result != Err(engine::CommandError::Failed) {
                break;
            }
            tokio::time::sleep(Duration::from_secs(delay)).await;
            result = initialize().await;
        }
    }
    result
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
enum Owner {
    Local,
    Remote(String),
    #[default]
    Unknown,
}

struct CachedPage {
    page: Page,
    loaded: Option<Instant>,
}

impl CachedPage {
    fn for_view(&mut self, reload: bool) -> (Page, bool) {
        let stale = reload
            || self
                .loaded
                .is_none_or(|loaded| loaded.elapsed() >= Duration::from_secs(300));
        if stale {
            self.loaded = None;
        }
        (self.page.clone(), stale)
    }
}

struct Worker {
    http: reqwest::Client,
    files: Arc<Storage>,
    device: String,
    session: Option<Arc<Session>>,
    publish: Publisher,
    audio: Arc<Audio>,
    playback_thread: PlaybackThread,
    authority: Arc<AtomicU64>,
    queue_authority: Arc<AtomicU64>,
    playlist_authority: Arc<AtomicU64>,
    epoch: Arc<AtomicU64>,
    changes: JoinSet<Work>,
    authorization: Option<AbortHandle>,
    loading: Option<AbortHandle>,
    page_load: u64,
    route: Route,
    search: String,
    saved_search: Option<(String, Page)>,
    release_jobs: HashMap<String, AbortHandle>,
    release_order: VecDeque<String>,
    release_slots: Arc<tokio::sync::Semaphore>,
    known_routes: VecDeque<Route>,
    pages: HashMap<Route, CachedPage>,
    snapshot: Snapshot,
    profile: Option<String>,
    profile_pending: bool,
    library_fresh: bool,
    metadata: HashMap<String, Track>,
    metadata_jobs: HashSet<String>,
    metadata_failed: HashMap<String, Instant>,
    artwork_jobs: HashSet<String>,
    postponed_art: VecDeque<(u64, String)>,
    minimum_engine: u64,
    playback_sequence: u64,
    connection_sequence: u64,
    cluster_sequence: u64,
    anchored_position: f64,
    anchored_at: Instant,
    engine_ready: bool,
    #[cfg(target_os = "macos")]
    sleep: Option<tokio::sync::oneshot::Receiver<Option<engine::SuspendedPlayback>>>,
    repeat: engine::RepeatFlags,
    active: Option<String>,
    local: Option<String>,
    local_active: bool,
    local_listed: bool,
    owner: Owner,
    last_remote: Option<String>,
    queue: Option<engine::Queue>,
    queue_from_dealer: bool,
    queue_fallback: Vec<Track>,
    queue_fallback_started: bool,
    history_started: bool,
    action: u64,
    pending: Option<Pending>,
    refused_resume: Option<ResumeTarget>,
    edit_pending: bool,
    unloading: bool,
    retirement: Option<Retirement>,
    retirement_recorded: bool,
    feedback_until: Option<Instant>,
}

async fn run(
    inbox: mpsc::UnboundedSender<Input>,
    mut input: mpsc::UnboundedReceiver<Input>,
    publish: Publisher,
) -> Result<()> {
    let http = auth::http()?;
    let files = Arc::new(Storage::new()?);
    let device = files.device_id()?;
    let playback_thread = PlaybackThread::start()?;
    #[cfg(target_os = "macos")]
    playback_thread
        .call(|| engine::set_device_name(&power::connect_name()))
        .await?;
    let audio = Audio::open();
    engine::install(
        move |notice| {
            let _ = inbox.send(Input::Observe(notice));
        },
        {
            let audio = Arc::clone(&audio);
            move |samples| audio.write(samples)
        },
        {
            let audio = Arc::clone(&audio);
            move |state| audio.control(state)
        },
    );
    let snapshot = Snapshot {
        phase: "connecting".into(),
        status: "Restoring your Spotify session…".into(),
        stamp: Stamp {
            account: 1,
            ..Stamp::default()
        },
        ..Snapshot::default()
    };
    let mut w = Worker {
        http,
        files,
        device,
        session: None,
        publish,
        audio,
        playback_thread,
        epoch: Arc::new(AtomicU64::new(1)),
        authority: Arc::new(AtomicU64::new(0)),
        queue_authority: Arc::new(AtomicU64::new(0)),
        playlist_authority: Arc::new(AtomicU64::new(0)),
        changes: JoinSet::new(),
        authorization: None,
        loading: None,
        page_load: 0,
        route: Route::Home,
        search: String::new(),
        saved_search: None,
        release_jobs: HashMap::new(),
        release_order: VecDeque::new(),
        release_slots: Arc::new(tokio::sync::Semaphore::new(4)),
        known_routes: VecDeque::new(),
        pages: HashMap::new(),
        snapshot,
        profile: None,
        profile_pending: false,
        library_fresh: false,
        metadata: HashMap::new(),
        metadata_jobs: HashSet::new(),
        metadata_failed: HashMap::new(),
        artwork_jobs: HashSet::new(),
        postponed_art: VecDeque::new(),
        minimum_engine: engine::generation(),
        playback_sequence: 0,
        connection_sequence: 0,
        cluster_sequence: 0,
        anchored_position: 0.0,
        anchored_at: Instant::now(),
        engine_ready: false,
        #[cfg(target_os = "macos")]
        sleep: None,
        repeat: engine::RepeatFlags::default(),
        active: None,
        local: None,
        local_active: false,
        local_listed: false,
        owner: Owner::Unknown,
        last_remote: None,
        queue: None,
        queue_from_dealer: false,
        queue_fallback: Vec::new(),
        queue_fallback_started: false,
        history_started: false,
        action: 0,
        pending: None,
        refused_resume: None,
        edit_pending: false,
        unloading: false,
        retirement: None,
        retirement_recorded: false,
        feedback_until: None,
    };
    match w.files.restore() {
        Ok(auth::StoredAccount::Retiring(intent)) => {
            w.reset();
            w.retirement = Some(intent);
            w.retirement_recorded = true;
            w.finish_retirement();
        }
        Ok(auth::StoredAccount::Grant(Some(grant))) if grant.requires_reauthentication => {
            w.phase("failed", "Sign in to Spotify again.", true)
        }
        Ok(auth::StoredAccount::Grant(Some(grant))) => w.adopt(grant, false),
        Ok(auth::StoredAccount::Grant(None)) => {
            w.phase("signedOut", "Connect to Spotify Premium", false)
        }
        Err(error) => w.phase("failed", &error.to_string(), true),
    };
    w.publish.snapshot(w.snapshot.clone());
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        let refresh = tokio::select! {
            change = w.changes.join_next(), if !w.changes.is_empty() => {
                if let Some(Ok(change)) = change {
                    let publish = !matches!(change, Work::Art(..));
                    w.settle(change);
                    publish
                } else { false }
            }
            command = input.recv() => match command {
                Some(Input::Command(command)) => { w.command(command); true }
                #[cfg(target_os = "macos")]
                Some(Input::Media(event)) => { w.media(event); true }
                #[cfg(target_os = "macos")]
                Some(Input::Power(event)) => { w.power(event); true }
                Some(Input::Observe(observation)) => { w.observe(observation); true }
                Some(Input::Artwork(account, url)) => { w.request_art(account, url); false }
                Some(Input::Shutdown(done)) => {
                    w.stop().await;
                    let _ = done.send(());
                    return Ok(());
                }
                None => { w.stop().await; return Ok(()); }
            },
            _ = tick.tick() => {
                let position = w.snapshot.playback.position;
                let feedback = w.snapshot.feedback.clone();
                let pending = w.pending.is_some();
                let initial_audio = w.snapshot.playback.can_start;
                w.advance();
                w.update_controls();
                if position != w.snapshot.playback.position {
                    w.publish.timing(w.account(), &w.snapshot.playback.uri, w.snapshot.playback.position);
                }
                initial_audio != w.snapshot.playback.can_start || feedback != w.snapshot.feedback || pending != w.pending.is_some()
            }
        };
        if refresh {
            w.update_controls();
            w.publish.snapshot(w.snapshot.clone());
        }
    }
}

impl Worker {
    fn account(&self) -> u64 {
        self.snapshot.stamp.account
    }

    fn phase(&mut self, phase: &str, status: &str, reauthenticate: bool) {
        self.snapshot.phase = phase.into();
        self.snapshot.status = status.into();
        self.snapshot.reauthenticate = reauthenticate;
    }

    fn report(&mut self, message: impl Into<String>) {
        self.snapshot.feedback = Some(message.into());
        self.feedback_until = Some(Instant::now() + Duration::from_secs(4));
    }

    fn catalog(&self) -> Option<Catalog> {
        self.session.clone().map(Catalog)
    }

    fn adopt(&mut self, grant: Grant, fresh: bool) {
        let session = Arc::new(Session::new(
            self.http.clone(),
            Arc::clone(&self.files),
            self.device.clone(),
            grant,
        ));
        self.session = Some(Arc::clone(&session));
        self.phase("connecting", "Starting Spotty Connect…", false);
        self.start_engine(session, fresh);
    }

    fn prepare_grant(&mut self, account: u64, grant: Grant) {
        self.phase("connecting", "Preparing Spotify Connect…", false);
        let playback = self.playback_thread.clone();
        let epoch = Arc::clone(&self.epoch);
        self.changes.spawn(async move {
            let result = playback
                .call(move || {
                    if epoch.load(Ordering::Acquire) != account {
                        return Err(Failure::Retired);
                    }
                    // A restart or retry may use cached AP credentials. Clear the old account's
                    // cache before the new OAuth grant becomes durable.
                    engine::shutdown();
                    engine::forget_credentials().map_err(|_| Failure::Storage)?;
                    Ok(grant)
                })
                .await
                .unwrap_or(Err(Failure::Network));
            Work::PreparedGrant(account, result)
        });
    }

    fn start_engine(&mut self, session: Arc<Session>, fresh: bool) {
        let id = self.account();
        let epoch = Arc::clone(&self.epoch);
        let playback = self.playback_thread.clone();
        let device = self.device.clone();
        self.changes.spawn(async move {
            let initialize = || {
                let epoch = Arc::clone(&epoch);
                let device = device.clone();
                let playback = &playback;
                async move {
                    playback
                        .call(move || {
                            if epoch.load(Ordering::Acquire) != id {
                                return Err(engine::CommandError::Superseded);
                            }
                            engine::set_device_id(&device)?;
                            engine::initialize()
                        })
                        .await
                        .unwrap_or(Err(engine::CommandError::Failed))
                }
            };
            if !fresh {
                match initialize_with_retry(true, initialize).await {
                    Err(engine::CommandError::Failed) => {}
                    other => return Work::Engine(id, StartResult::from_playback(other)),
                }
            }
            let token = match session.access(None).await {
                Ok(token) => token,
                Err(Failure::Revoked) => return Work::Engine(id, StartResult::NeedsSignIn),
                Err(error) => return Work::Engine(id, StartResult::Failed(error)),
            };
            let auth_epoch = Arc::clone(&epoch);
            let auth_device = device.clone();
            let authorized = playback
                .call(move || {
                    if auth_epoch.load(Ordering::Acquire) != id {
                        return Err(engine::CommandError::Superseded);
                    }
                    engine::set_device_id(&auth_device)?;
                    engine::authorize(&token)
                })
                .await
                .unwrap_or(Err(engine::CommandError::Failed));
            let result = match authorized {
                Ok(()) => {
                    StartResult::from_playback(initialize_with_retry(!fresh, initialize).await)
                }
                Err(error) => StartResult::from_playback(Err(error)),
            };
            Work::Engine(id, result)
        });
    }

    fn restore_catalog(&mut self) {
        let Some(catalog) = self.catalog() else {
            return;
        };
        let account = self.account();
        self.snapshot.library_loading = true;
        self.snapshot.library_error = None;
        self.load_profile();
        self.changes
            .spawn(async move { Work::Library(account, catalog.playlists().await) });
        self.load_route(false);
    }

    fn load_profile(&mut self) {
        if self.profile.is_some() || self.profile_pending {
            return;
        }
        if let Some(catalog) = self.catalog() {
            let account = self.account();
            self.profile_pending = true;
            self.snapshot.profile_error = None;
            self.changes
                .spawn(async move { Work::Profile(account, catalog.profile().await) });
        }
    }

    fn load_route(&mut self, force: bool) {
        self.reset_releases();
        if let Some(load) = self.loading.take() {
            load.abort();
        }
        self.page_load = self.page_load.wrapping_add(1);
        self.snapshot.loading = false;
        let route = self.route.clone();
        let search = self.search.clone();
        let fallback = match &route {
            Route::Home => "Home".into(),
            Route::Search => "Search".into(),
            Route::Likes => "Liked Songs".into(),
            Route::Library => "Your Library".into(),
            Route::Discography(_) => "Discography".into(),
            Route::Detail(uri) => self
                .find_item(uri)
                .map(|item| item.title.clone())
                .unwrap_or_default(),
        };
        if route != Route::Search {
            if let Some(cached) = self.pages.get_mut(&route) {
                let (page, stale) = cached.for_view(force);
                self.apply_page(page, stale);
                if !stale {
                    return;
                }
            } else {
                self.apply_page(
                    Page {
                        title: fallback,
                        item: match &route {
                            Route::Detail(uri) => self.find_item(uri).cloned(),
                            _ => None,
                        },
                        ..Page::default()
                    },
                    false,
                );
            }
        } else if let Some((_, page)) = self
            .saved_search
            .as_ref()
            .filter(|(term, _)| term == &search)
        {
            let previous = page.clone();
            self.apply_page(previous, false);
            if !force {
                self.snapshot.loading = false;
                return;
            }
        } else {
            self.saved_search = None;
            self.apply_page(
                Page {
                    title: fallback,
                    ..Page::default()
                },
                false,
            );
            if search.is_empty() {
                self.snapshot.loading = false;
                return;
            }
        }
        let Some(catalog) = self.catalog() else {
            return;
        };
        self.snapshot.loading = true;
        self.snapshot.error = None;
        self.update_editability();
        let account = self.account();
        let load = self.page_load;
        self.loading = Some(self.changes.spawn(async move {
            if route == Route::Search && !force {
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
            let response = catalog.read(&route, &search).await;
            Work::Page(account, load, route, response)
        }));
    }

    fn reset_releases(&mut self) {
        for (_, job) in self.release_jobs.drain() {
            job.abort();
        }
        self.release_order.clear();
        self.snapshot.release_loads.clear();
    }

    fn load_release(&mut self, uri: &str, retry: bool) {
        if !matches!(self.route, Route::Discography(_))
            || !self
                .snapshot
                .sections
                .iter()
                .flat_map(|s| &s.items)
                .any(|item| item.uri == uri && item.kind == "Album")
            || self
                .snapshot
                .release_loads
                .get(uri)
                .is_some_and(|state| !(retry && matches!(state, ReleaseLoad::Failed(_))))
        {
            return;
        }
        self.release_order.retain(|old| old != uri);
        self.release_order.push_back(uri.into());
        let route = Route::Detail(uri.to_owned());
        if let Some(page) = self.pages.get(&route)
            && page
                .loaded
                .is_some_and(|date| date.elapsed() < Duration::from_secs(300))
        {
            self.snapshot
                .set_release_tracks(uri, page.page.tracks.clone());
            self.trim_releases();
            return;
        }
        let Some(catalog) = self.catalog() else {
            return;
        };
        let account = self.account();
        let view = self.snapshot.stamp.view;
        let slots = Arc::clone(&self.release_slots);
        self.snapshot
            .release_loads
            .insert(uri.to_owned(), ReleaseLoad::Loading);
        let album = uri.to_owned();
        let job = self.changes.spawn(async move {
            let response = match slots.acquire_owned().await {
                Ok(_slot) => catalog.read(&route, "").await,
                Err(_) => Err(Failure::Retired),
            };
            Work::Release(account, view, album, response)
        });
        self.release_jobs.insert(uri.to_owned(), job);
        self.trim_releases();
    }

    fn trim_releases(&mut self) {
        while self.release_order.len() > 1
            && (self.release_order.len() > 20 || self.snapshot.tracks.len() > 20_000)
        {
            let Some(old) = self.release_order.pop_front() else {
                break;
            };
            if let Some(job) = self.release_jobs.remove(&old) {
                job.abort();
            }
            self.snapshot.release_loads.remove(&old);
            self.snapshot
                .tracks
                .retain(|row| row.album_item.as_ref().is_none_or(|album| album.uri != old));
            self.snapshot.stamp.playlist = self.snapshot.stamp.playlist.wrapping_add(1);
        }
    }

    fn apply_page(&mut self, page: Page, cached: bool) {
        self.snapshot.title = page.title;
        self.snapshot.cached = cached;
        self.snapshot.sections = page.sections;
        self.snapshot.search_errors = page.search_errors;
        if matches!(self.route, Route::Discography(_)) {
            let albums: HashSet<_> = self
                .snapshot
                .sections
                .iter()
                .flat_map(|section| &section.items)
                .map(|album| album.uri.as_str())
                .collect();
            self.snapshot.tracks.retain(|row| {
                row.album_item
                    .as_ref()
                    .is_some_and(|album| albums.contains(album.uri.as_str()))
            });
            self.snapshot
                .release_loads
                .retain(|album, _| albums.contains(album.as_str()));
            self.release_jobs.retain(|album, job| {
                if albums.contains(album.as_str()) {
                    true
                } else {
                    job.abort();
                    false
                }
            });
        } else {
            self.snapshot.tracks = page.tracks;
        }
        self.snapshot.details = page.item;
        self.snapshot.artist_about = page.about;
        if let Some(item) = &self.snapshot.details {
            self.snapshot.subtitle.clone_from(&item.subtitle);
            self.snapshot.description.clone_from(&item.description);
            self.snapshot.artwork.clone_from(&item.artwork);
        } else {
            self.snapshot.subtitle.clear();
            self.snapshot.description.clear();
            self.snapshot.artwork = None;
        }
        self.snapshot.context_playable =
            matches!(self.route, Route::Detail(_)) && self.snapshot.details.is_some();
        self.snapshot.stamp.playlist = self.snapshot.stamp.playlist.wrapping_add(1);
        self.playlist_authority.fetch_add(1, Ordering::AcqRel);
        self.snapshot.error = None;
        for row in &self.snapshot.tracks {
            self.metadata.insert(row.uri.clone(), row.clone());
        }
        if self.metadata.len() > 4096 {
            let retained = self
                .snapshot
                .tracks
                .iter()
                .map(|track| track.uri.as_str())
                .chain(
                    self.snapshot
                        .queue
                        .iter()
                        .chain(&self.snapshot.history)
                        .map(|track| track.uri.as_str()),
                )
                .collect::<HashSet<_>>();
            self.metadata.retain(|uri, _| {
                retained.contains(uri.as_str()) || *uri == self.snapshot.playback.uri
            });
        }
        self.update_editability();
        self.update_labels();
    }

    fn find_item(&self, uri: &str) -> Option<&Item> {
        fn find<'a>(items: &'a [Item], uri: &str) -> Option<&'a Item> {
            items.iter().find_map(|item| {
                if item.uri == uri {
                    Some(item)
                } else {
                    find(&item.children, uri)
                }
            })
        }
        find(&self.snapshot.library, uri)
            .or_else(|| {
                self.snapshot
                    .sections
                    .iter()
                    .find_map(|section| find(&section.items, uri))
            })
            .or_else(|| {
                self.pages.values().find_map(|p| {
                    p.page
                        .item
                        .as_ref()
                        .filter(|item| item.uri == uri)
                        .or_else(|| {
                            p.page
                                .sections
                                .iter()
                                .find_map(|section| find(&section.items, uri))
                        })
                })
            })
    }

    fn update_editability(&mut self) {
        let owner = self.profile.as_deref();
        self.snapshot.editable = !self.snapshot.cached
            && !self.snapshot.loading
            && self.snapshot.details.as_ref().is_some_and(|item| {
                item.kind == "Playlist" && owner.is_some() && item.owner.as_deref() == owner
            });
        for track in &mut self.snapshot.tracks {
            track.removable = self.snapshot.editable && track.occurrence.is_some();
        }
        fn editable(items: &[Item], owner: &str, targets: &mut Vec<Item>) {
            for item in items {
                if item.kind == "Playlist" && item.owner.as_deref() == Some(owner) {
                    targets.push(item.clone());
                }
                editable(&item.children, owner, targets);
            }
        }
        self.snapshot.edit_targets.clear();
        if self.library_fresh
            && let Some(owner) = owner
        {
            editable(
                &self.snapshot.library,
                owner,
                &mut self.snapshot.edit_targets,
            );
        }
    }

    fn update_controls(&mut self) {
        let playback = &mut self.snapshot.playback;
        let audio_ready = self.owner != Owner::Local || self.audio.available();
        playback.can_start = self.engine_ready
            && self.pending.is_none()
            && self.owner != Owner::Unknown
            && audio_ready;
        playback.can_transfer = self.engine_ready && self.pending.is_none();
        playback.can_skip = playback.can_start && !playback.uri.is_empty();
        let resume_blocked = self.refused_resume.as_ref().is_some_and(|target| {
            target.track == playback.uri && target.context == playback.context
        });
        playback.can_toggle = playback.can_skip && (playback.playing || !resume_blocked);
    }

    fn advance(&mut self) {
        if self.pending.as_ref().is_some_and(Pending::expired) {
            let target = self
                .pending
                .take()
                .and_then(|pending| pending.resume_target());
            if let Some(target) = target {
                self.refuse_resume(target);
            } else {
                self.report(Failure::Uncertain.to_string());
            }
        }
        if self.snapshot.playback.playing {
            let playback = &mut self.snapshot.playback;
            let position = self.anchored_position + self.anchored_at.elapsed().as_secs_f64();
            playback.position = if playback.duration > 0.0 {
                position.min(playback.duration)
            } else {
                position
            };
        }
        if self
            .feedback_until
            .is_some_and(|deadline| Instant::now() >= deadline)
        {
            self.feedback_until = None;
            self.snapshot.feedback = None;
        }
    }

    fn settle(&mut self, task: Work) {
        match task {
            Work::Grant(id, result)
                if id == self.account() && self.snapshot.phase == "authorizing" =>
            {
                self.authorization = None;
                match result {
                    Ok(grant) => self.prepare_grant(id, grant),
                    Err(error) => self.phase("failed", &error.to_string(), true),
                }
            }
            Work::PreparedGrant(id, result) if id == self.account() => {
                match result.and_then(|grant| {
                    self.files.publish(&grant)?;
                    Ok(grant)
                }) {
                    Ok(grant) => self.adopt(grant, true),
                    Err(error) => self.phase("failed", &error.to_string(), true),
                };
            }
            Work::Engine(id, state) if id == self.account() => match state {
                StartResult::Started => {
                    self.snapshot.catalog_ready = true;
                    self.snapshot.stamp.catalog = self.snapshot.stamp.catalog.wrapping_add(1);
                    self.phase("ready", "Spotty Connect is ready", false);
                    self.restore_catalog();
                }
                StartResult::NeedsSignIn => self.request_reauth(),
                StartResult::Failed(error) => self.phase("failed", &error.to_string(), false),
            },
            #[cfg(target_os = "macos")]
            Work::Wake(id, result) if id == self.account() => match result {
                Ok(()) => {}
                Err(engine::CommandError::CredentialsRejected) => self.request_reauth(),
                Err(_) => self.phase(
                    "failed",
                    "Couldn’t restore Spotify Connect after sleep.",
                    false,
                ),
            },
            Work::Page(id, revision, route, response)
                if id == self.account() && revision == self.page_load && route == self.route =>
            {
                self.loading = None;
                self.snapshot.loading = false;
                match response {
                    Ok(mut page) => {
                        if route == Route::Search {
                            if let Some((_, previous)) = self
                                .saved_search
                                .as_ref()
                                .filter(|(term, _)| term == &self.search)
                            {
                                page.retain_failed_search_categories(previous);
                            }
                            self.saved_search = Some((self.search.clone(), page.clone()));
                        } else {
                            self.retain(route, page.clone(), Some(Instant::now()));
                        }
                        self.apply_page(page, false);
                    }
                    Err(Failure::Revoked) => self.request_reauth(),
                    Err(error) => {
                        if matches!(error, Failure::Status(401 | 403)) && route == Route::Search {
                            self.saved_search = None;
                            self.apply_page(
                                Page {
                                    title: "Search".into(),
                                    ..Page::default()
                                },
                                false,
                            );
                        }
                        self.snapshot.error = Some(error.to_string());
                    }
                }
                self.update_editability();
            }
            Work::Release(id, view, album, response)
                if id == self.account()
                    && view == self.snapshot.stamp.view
                    && self.release_jobs.remove(&album).is_some() =>
            {
                match response {
                    Ok(page) => {
                        self.snapshot
                            .set_release_tracks(&album, page.tracks.clone());
                        self.retain(Route::Detail(album), page, Some(Instant::now()));
                        self.trim_releases();
                    }
                    Err(Failure::Revoked) => self.request_reauth(),
                    Err(error) => {
                        self.snapshot
                            .release_loads
                            .insert(album, ReleaseLoad::Failed(error.to_string()));
                    }
                }
            }
            Work::Profile(id, result) if id == self.account() => {
                self.profile_pending = false;
                match result {
                    Ok((uri, name)) => {
                        self.snapshot.account = name;
                        self.profile = Some(uri);
                        if self.library_fresh {
                            self.save("library", &self.snapshot.library);
                        }
                        for (route, page) in &self.pages {
                            if page.loaded.is_some()
                                && let Some(key) = cache_key(route)
                            {
                                self.save(&key, &page.page);
                            }
                        }
                        self.load_saved();
                        self.update_editability();
                    }
                    Err(Failure::Revoked) => self.request_reauth(),
                    Err(error) => {
                        self.snapshot.profile_error =
                            Some(format!("Couldn’t verify the active account. {error}"));
                    }
                }
            }
            Work::Library(id, result) if id == self.account() => {
                self.snapshot.library_loading = false;
                match result {
                    Ok(library) => {
                        self.snapshot.library = library;
                        self.snapshot.library_loaded = true;
                        self.snapshot.library_error = None;
                        self.library_fresh = true;
                        self.save("library", &self.snapshot.library);
                    }
                    Err(Failure::Revoked) => self.request_reauth(),
                    Err(error) => self.snapshot.library_error = Some(error.to_string()),
                }
                self.update_editability();
            }
            Work::QueueFallback(id, Err(Failure::Revoked)) if id == self.account() => {
                self.request_reauth();
            }
            Work::QueueFallback(id, result) if id == self.account() => {
                self.queue_fallback_started = false;
                if let Ok(tracks) = result {
                    for track in &tracks {
                        self.metadata
                            .entry(track.uri.clone())
                            .or_insert_with(|| track.clone());
                    }
                    self.queue_fallback = tracks;
                    self.update_labels();
                }
                self.hydrate();
            }
            Work::Track(id, _, Err(Failure::Revoked)) if id == self.account() => {
                self.request_reauth();
            }
            Work::Track(id, uri, result) if id == self.account() => {
                self.metadata_jobs.remove(&uri);
                if let Ok(track) = result {
                    self.metadata.insert(uri, track);
                } else {
                    self.metadata_failed.insert(uri, Instant::now());
                }
                self.update_labels();
                self.hydrate();
            }
            Work::Action(id, _, Err(Failure::Revoked)) if id == self.account() => {
                self.request_reauth();
            }
            Work::Action(id, command, result) if id == self.account() && command == self.action => {
                let Some(pending) = self.pending.as_mut() else {
                    return;
                };
                match result {
                    Ok(receipt) => {
                        if pending.acknowledge() || receipt.sent_partial {
                            self.pending = None;
                        }
                        if let Some(message) = receipt.notice {
                            self.report(message);
                        }
                    }
                    Err(error) => {
                        let observed = pending.observed();
                        let resume = pending.resume_target();
                        self.pending = None;
                        if !observed && !matches!(error, Failure::Retired) {
                            if let Some(target) = resume {
                                self.refuse_resume(target);
                            } else {
                                self.report(error.to_string());
                            }
                        }
                    }
                }
            }
            Work::PlaylistEdit(id, uri, result) if id == self.account() => {
                self.edit_pending = false;
                if matches!(result, Err(Failure::Retired)) {
                    return;
                }
                let route = Route::Detail(uri);
                if let Some(cached) = self.pages.get_mut(&route) {
                    cached.loaded = None;
                }
                if self.route == route {
                    self.load_route(true);
                }
                match result {
                    Ok(()) => self.report("Playlist updated"),
                    Err(Failure::Revoked) => self.request_reauth(),
                    Err(error) => self.report(error.to_string()),
                }
            }
            Work::Art(id, url, bytes) if id == self.account() => {
                self.artwork_jobs.remove(&url);
                self.publish.artwork(id, url, bytes);
                if let Some((next_id, next)) = self.postponed_art.pop_front() {
                    self.start_art(next_id, next);
                }
            }
            Work::Retired(id, applied, result) if id == self.account() => {
                self.unloading = false;
                if self.retirement == Some(Retirement::SignOut) && applied != Retirement::SignOut {
                    self.finish_retirement();
                    return;
                }
                match result {
                    Ok(()) => {
                        self.retirement = None;
                        self.retirement_recorded = false;
                        match applied {
                            Retirement::SignOut => {
                                self.phase("signedOut", "Connect to Spotify Premium", false);
                            }
                            Retirement::Reauthenticate => {
                                self.phase("failed", "Sign in to Spotify again.", true);
                            }
                        }
                    }
                    Err(error) => self.phase("failed", &error.to_string(), false),
                }
            }
            _ => {}
        }
    }

    fn request_reauth(&mut self) {
        self.retire_account(Retirement::Reauthenticate);
    }

    fn reset(&mut self) {
        if let Some(session) = self.session.take() {
            session.retire();
        }
        self.changes.abort_all();
        self.loading = None;
        self.authorization = None;
        self.authority.fetch_add(1, Ordering::AcqRel);
        self.queue_authority.fetch_add(1, Ordering::AcqRel);
        self.playlist_authority.fetch_add(1, Ordering::AcqRel);
        let account = self.epoch.fetch_add(1, Ordering::AcqRel) + 1;
        self.snapshot = Snapshot {
            stamp: Stamp {
                account,
                ..Stamp::default()
            },
            ..Snapshot::default()
        };
        self.route = Route::Home;
        self.reset_releases();
        self.search.clear();
        self.saved_search = None;
        self.pages.clear();
        self.known_routes.clear();
        self.profile = None;
        self.profile_pending = false;
        self.library_fresh = false;
        self.queue = None;
        self.queue_from_dealer = false;
        self.queue_fallback.clear();
        self.queue_fallback_started = false;
        self.active = None;
        self.local = None;
        self.local_active = false;
        self.local_listed = false;
        self.owner = Owner::Unknown;
        self.last_remote = None;
        self.engine_ready = false;
        #[cfg(target_os = "macos")]
        {
            self.sleep = None;
        }
        self.repeat = engine::RepeatFlags::default();
        self.minimum_engine = engine::generation().saturating_add(1);
        self.pending = None;
        self.refused_resume = None;
        self.edit_pending = false;
        self.metadata.clear();
        self.metadata_jobs.clear();
        self.metadata_failed.clear();
        self.artwork_jobs.clear();
        self.postponed_art.clear();
        self.history_started = false;
        self.feedback_until = None;
    }

    fn logout(&mut self) {
        self.retire_account(Retirement::SignOut);
    }

    fn retire_account(&mut self, intent: Retirement) {
        if self.retirement.is_none() {
            self.reset();
            self.retirement = Some(intent);
        } else if intent == Retirement::SignOut && self.retirement != Some(intent) {
            self.retirement = Some(intent);
            self.retirement_recorded = false;
        } else if self.unloading {
            return;
        }
        self.finish_retirement();
    }

    fn record_retirement(&mut self, requested: Retirement) -> Result<Retirement> {
        if self.retirement_recorded {
            return Ok(requested);
        }
        let recorded = self.files.begin_retirement(requested)?;
        self.retirement_recorded = true;
        Ok(recorded)
    }

    fn finish_retirement(&mut self) {
        let Some(requested) = self.retirement else {
            return;
        };
        let durable = self.record_retirement(requested);
        let intent = durable.as_ref().copied().unwrap_or(requested);
        self.retirement = Some(intent);
        if self.unloading {
            return;
        }
        self.unloading = true;
        let status = match intent {
            Retirement::SignOut => "Signing out…",
            Retirement::Reauthenticate => "Ending the expired Spotify session…",
        };
        self.phase("connecting", status, false);
        let files = Arc::clone(&self.files);
        let playback = self.playback_thread.clone();
        let id = self.account();
        self.changes.spawn(async move {
            let result = playback
                .call(move || retire_from_disk(&files, intent))
                .await
                .unwrap_or(Err(Failure::Storage));
            let completed = durable.and(result);
            Work::Retired(id, completed.unwrap_or(intent), completed.map(drop))
        });
    }

    async fn stop(&mut self) {
        // Retire admission first. Preserve an explicitly requested retirement even when its
        // asynchronous reply is cancelled by reset or a stronger request is still pending.
        // The playback lane may already have cleaned a recorded intent while its
        // reply is pending. Re-recording it here could erase a newer account.
        let retirement = self
            .retirement
            .and_then(|intent| self.record_retirement(intent).ok());
        self.reset();
        let audio = Arc::clone(&self.audio);
        let files = Arc::clone(&self.files);
        let playback = self.playback_thread.clone();
        let _ = playback
            .call(move || {
                if let Some(intent) = retirement {
                    let _ = retire_from_disk(&files, intent);
                } else {
                    engine::shutdown();
                }
            })
            .await;
        let _ = tokio::task::spawn_blocking(move || audio.shutdown()).await;
    }

    fn retain(&mut self, route: Route, page: Page, fresh: Option<Instant>) {
        self.known_routes.retain(|known| known != &route);
        self.known_routes.push_back(route.clone());
        if self.known_routes.len() > 16
            && let Some(old) = self.known_routes.pop_front()
        {
            self.pages.remove(&old);
        }
        if fresh.is_some()
            && let Some(key) = cache_key(&route)
        {
            self.save(&key, &page);
        }
        self.pages.insert(
            route,
            CachedPage {
                page,
                loaded: fresh,
            },
        );
    }

    fn cache_directory(&self) -> Option<PathBuf> {
        let account = self.profile.as_ref()?;
        let id = hex(Sha256::digest(account.as_bytes()).as_slice());
        Some(self.files.root().join("RuneCatalog").join(id))
    }

    fn save(&self, name: &str, payload: &impl serde::Serialize) {
        if let Some(session) = &self.session
            && let Some(path) = self.cache_directory()
            && let Ok(bytes) = serde_json::to_vec(payload)
            && bytes.len() < 16 * 1024 * 1024
        {
            let _ = session.write_catalog(&path.join(format!("{name}.json")), &bytes);
        }
    }

    fn load_saved(&mut self) {
        let Some(path) = self.cache_directory() else {
            return;
        };
        if !self.library_fresh
            && let Ok(Some(bytes)) =
                auth::read_private(&path.join("library.json"), 16 * 1024 * 1024)
            && let Ok(library) = serde_json::from_slice(&bytes)
        {
            self.snapshot.library = library;
            self.snapshot.library_loaded = true;
        }
        if self.last_remote.is_none() {
            if let Ok(Some(bytes)) = auth::read_private(&path.join("last-remote-device.json"), 1024)
                && let Ok(device) = serde_json::from_slice::<String>(&bytes)
                && !device.is_empty()
            {
                self.last_remote = Some(device);
                self.resolve_owner();
            }
        } else if let Some(device) = &self.last_remote {
            self.save("last-remote-device", device);
        }
        if let Ok(Some(bytes)) = auth::read_private(&path.join("history.json"), 1024 * 1024)
            && let Ok(history) = serde_json::from_slice::<Vec<Track>>(&bytes)
        {
            let mut known: HashSet<_> = self
                .snapshot
                .history
                .iter()
                .map(|row| row.uri.clone())
                .collect();
            self.snapshot.history.extend(
                history
                    .into_iter()
                    .filter(|row| known.insert(row.uri.clone())),
            );
            self.snapshot.history.truncate(10);
        }
        self.restore_route_cache();
    }

    fn restore_route_cache(&mut self) {
        if self.pages.contains_key(&self.route) {
            return;
        }
        let Some(path) = self.cache_directory() else {
            return;
        };
        let Some(key) = cache_key(&self.route) else {
            return;
        };
        if let Ok(Some(bytes)) =
            auth::read_private(&path.join(format!("{key}.json")), 16 * 1024 * 1024)
            && let Ok(page) = serde_json::from_slice::<Page>(&bytes)
        {
            self.retain(self.route.clone(), page.clone(), None);
            self.apply_page(page, true);
        }
    }

    #[cfg(target_os = "macos")]
    fn power(&mut self, event: power::Event) {
        if self.session.is_none() {
            return;
        }
        let account = self.account();
        let epoch = Arc::clone(&self.epoch);
        match event {
            power::Event::Sleep if self.sleep.is_none() && self.engine_ready => {
                self.engine_ready = false;
                self.bump_route();
                self.finish_observation(Match::Superseded);
                self.phase(
                    "recovering",
                    "Spotify Connect will resume after sleep.",
                    false,
                );
                self.sleep = self
                    .playback_thread
                    .submit(move || {
                        (epoch.load(Ordering::Acquire) == account).then(engine::suspend)
                    })
                    .ok();
            }
            power::Event::Wake if self.sleep.is_some() || self.engine_ready => {
                self.engine_ready = false;
                self.bump_route();
                self.finish_observation(Match::Superseded);
                self.phase("recovering", "Restoring Spotify Connect…", false);
                let saved = self.sleep.take();
                let playback = self.playback_thread.clone();
                self.changes.spawn(async move {
                    let interrupted = match saved {
                        Some(result) => result.await.ok().flatten(),
                        None => None,
                    };
                    let result = playback
                        .call(move || {
                            if epoch.load(Ordering::Acquire) != account {
                                return Err(engine::CommandError::NotConnected);
                            }
                            engine::wake(interrupted)
                        })
                        .await
                        .unwrap_or(Err(engine::CommandError::Failed));
                    Work::Wake(account, result)
                });
            }
            _ => {}
        }
    }

    fn observe(&mut self, event: engine::Observation) {
        if self.session.is_none() {
            return;
        }
        let generation = match &event {
            engine::Observation::Cluster(event) => event.generation,
            engine::Observation::Connection(event) => event.generation,
            engine::Observation::Playback(event) => event.generation,
        };
        if generation < self.minimum_engine || generation < self.snapshot.stamp.engine {
            return;
        }
        let connection = match &event {
            engine::Observation::Cluster(event) => Some(&event.connection),
            engine::Observation::Connection(event) => Some(event),
            engine::Observation::Playback(_) => None,
        };
        if connection.is_some_and(|connection| {
            connection.credentials_rejected
                && (generation > self.snapshot.stamp.engine
                    || connection.sequence > self.connection_sequence)
        }) {
            self.request_reauth();
            return;
        }
        if generation != self.snapshot.stamp.engine {
            self.finish_observation(Match::Superseded);
            self.bump_route();
            self.snapshot.stamp.engine = generation;
            self.playback_sequence = 0;
            self.connection_sequence = 0;
            self.local_active = false;
            self.local_listed = false;
            self.cluster_sequence = 0;
            self.engine_ready = false;
            self.queue = None;
            self.queue_from_dealer = false;
        }
        match event {
            engine::Observation::Cluster(snapshot) if snapshot.sequence > self.cluster_sequence => {
                self.cluster_sequence = snapshot.sequence;
                let stale_owner = snapshot.connection.sequence < self.connection_sequence
                    && snapshot.connection.local != self.local_active;
                if !stale_owner {
                    self.local = snapshot.local.or_else(|| self.local.clone());
                    self.active = snapshot.active;
                    if let Some(id) = &self.active
                        && self.local.as_ref().is_some_and(|local| local != id)
                        && Some(id) != self.last_remote.as_ref()
                    {
                        self.last_remote = Some(id.clone());
                        self.save("last-remote-device", id);
                    }
                }
                self.snapshot.devices = snapshot
                    .devices
                    .into_iter()
                    .map(|device| Device {
                        active: self.active.as_ref() == Some(&device.id),
                        name: if self.local.as_ref() == Some(&device.id) {
                            "This computer".into()
                        } else {
                            device.name
                        },
                        id: device.id,
                        detail: device.kind,
                    })
                    .collect();
                self.local_listed = self
                    .local
                    .as_ref()
                    .is_some_and(|id| self.snapshot.devices.iter().any(|device| &device.id == id));
                if let Some(id) = &self.local
                    && !self.local_listed
                {
                    self.snapshot.devices.insert(
                        0,
                        Device {
                            id: id.clone(),
                            name: "This computer".into(),
                            detail: "Computer".into(),
                            active: self.active.as_ref() == Some(id),
                        },
                    );
                }
                if stale_owner {
                    // A newer direct connection observation owns playback and queue.
                    // The cluster still supplies the newest device membership.
                    self.resolve_owner();
                    self.rebuild_queue();
                    return;
                }
                self.apply_connection(snapshot.connection);
                self.resolve_owner();
                if let Some(playback) = snapshot.playback {
                    self.apply_playback(playback, true);
                } else if let Some(pending) = self.pending.as_ref() {
                    let matched =
                        pending.owner_without_playback(snapshot.sequence, self.active.as_deref());
                    self.finish_observation(matched);
                }
                if let Some(queue) = snapshot.queue {
                    if self.queue_from_dealer
                        != (snapshot.source == engine::ClusterOrigin::PushedUpdate)
                    {
                        self.queue_authority.fetch_add(1, Ordering::AcqRel);
                    }
                    self.queue_from_dealer = snapshot.source == engine::ClusterOrigin::PushedUpdate;
                    if self.queue.as_ref().is_none_or(|old| {
                        old.revision != queue.revision || !same_queue(old, &queue)
                    }) {
                        self.snapshot.stamp.queue = queue.sequence;
                        self.queue_authority.fetch_add(1, Ordering::AcqRel);
                    }
                    if self.queue_from_dealer
                        && let Some(pending) = self.pending.as_ref()
                    {
                        let matched = pending.queue(&queue, &self.snapshot.playback, &self.owner);
                        self.finish_observation(matched);
                    }
                    self.queue = Some(queue);
                }
                self.resolve_owner();
                self.rebuild_queue();
            }
            engine::Observation::Connection(snapshot) => {
                self.apply_connection(snapshot);
                self.resolve_owner();
                self.rebuild_queue();
            }
            engine::Observation::Playback(snapshot) => {
                // Direct player callbacks never supersede an active remote member.
                if snapshot.local && self.owner == Owner::Local {
                    self.apply_playback(snapshot, false);
                }
            }
            _ => {}
        }
        self.hydrate();
    }

    fn apply_connection(&mut self, connection: engine::Connection) {
        if connection.sequence <= self.connection_sequence {
            return;
        }
        self.connection_sequence = connection.sequence;
        if let Some(id) = connection.id {
            self.local = Some(id);
        }
        self.local_active = connection.local;
        if connection.local {
            self.active.clone_from(&self.local);
        } else if self.active == self.local {
            self.active = None;
        }
        let ready = connection.ready && connection.connected && !connection.resume_pending;
        if self.engine_ready != ready {
            self.bump_route();
        }
        self.engine_ready = ready;
        #[cfg(target_os = "macos")]
        if self.sleep.is_some() {
            self.engine_ready = false;
            return;
        }
        if (!connection.connected || connection.resume_pending) && self.snapshot.catalog_ready {
            self.phase("recovering", "Restoring Spotify Connect…", false);
        } else if self.engine_ready && self.snapshot.catalog_ready {
            self.phase("ready", "Spotty Connect is ready", false);
        } else if let Some(error) = connection.error
            && !self.snapshot.catalog_ready
        {
            self.snapshot.status = error;
        }
    }

    fn resolve_owner(&mut self) {
        for device in &mut self.snapshot.devices {
            device.active = self.active.as_ref() == Some(&device.id);
        }
        let next = if self.local_active {
            Owner::Local
        } else if let Some(active) = &self.active {
            if self.local.is_some() {
                Owner::Remote(active.clone())
            } else {
                Owner::Unknown
            }
        } else if let Some(last) = &self.last_remote
            && self
                .snapshot
                .devices
                .iter()
                .any(|device| &device.id == last)
            && self.local.is_some()
        {
            Owner::Remote(last.clone())
        } else if self.local_listed
            && self.engine_ready
            && !self.snapshot.playback.playing
            && (self.snapshot.playback.uri.is_empty() || self.last_remote.is_none())
        {
            Owner::Local
        } else {
            Owner::Unknown
        };
        if self.owner != next {
            self.owner = next;
            self.bump_route();
        }
        self.snapshot.playback.device = match &self.owner {
            Owner::Local if self.local_active => "This computer".into(),
            Owner::Remote(id) => self
                .snapshot
                .devices
                .iter()
                .find(|device| &device.id == id)
                .map(|device| device.name.clone())
                .unwrap_or_default(),
            _ => String::new(),
        };
    }

    fn bump_route(&mut self) {
        self.snapshot.stamp.route = self.snapshot.stamp.route.wrapping_add(1);
        self.authority.fetch_add(1, Ordering::AcqRel);
    }

    fn refuse_resume(&mut self, target: ResumeTarget) {
        self.refused_resume = Some(target);
        self.snapshot.feedback =
            Some("Couldn’t resume this track. Choose a track or playlist to play.".into());
        self.feedback_until = None;
    }

    fn finish_observation(&mut self, outcome: Match) {
        if self
            .pending
            .as_mut()
            .is_some_and(|pending| pending.record(outcome))
        {
            self.pending = None;
        }
    }

    fn apply_playback(&mut self, observation: engine::Playback, protocol: bool) {
        if observation.sequence <= self.playback_sequence {
            return;
        }
        self.playback_sequence = observation.sequence;
        if let Some(pending) = self.pending.as_ref() {
            let outcome =
                pending.playback(&observation, &self.owner, self.active.as_deref(), protocol);
            let requested = pending.resume_target();
            if outcome == Match::Confirmed && pending.is_selection() {
                self.refused_resume = None;
                if self.feedback_until.is_none() {
                    self.snapshot.feedback = None;
                }
            }
            self.finish_observation(outcome);
            if let Some(target) = requested {
                if outcome == Match::Rejected {
                    self.refuse_resume(target);
                    return;
                }
                if outcome == Match::Awaiting
                    && (!protocol
                        || observation.track.is_empty()
                        || observation.track == target.track)
                {
                    return;
                }
            }
        }
        if observation.unavailable {
            self.report(if observation.rejected {
                "Spotify refused audio for this track."
            } else {
                "This track is unavailable."
            });
            return;
        }
        let playback = &mut self.snapshot.playback;
        let track_changed = playback.uri != observation.track;
        if track_changed {
            self.queue_authority.fetch_add(1, Ordering::AcqRel);
            playback.uri = observation.track;
            playback.title = if playback.uri.is_empty() {
                "Nothing playing"
            } else {
                "Unknown track"
            }
            .into();
            playback.artist.clear();
            playback.artwork = None;
        }
        if let Some(context) = observation.context
            && playback.context != context
        {
            self.queue_authority.fetch_add(1, Ordering::AcqRel);
            playback.context = context;
        }
        if playback.uri.is_empty() {
            playback.context.clear();
        }
        let record = observation.playing
            && !playback.uri.is_empty()
            && (track_changed || !playback.playing)
            && self.history_started
            && self.snapshot.phase != "recovering";
        self.history_started = true;
        playback.playing = observation.playing && !playback.uri.is_empty();
        playback.duration = f64::from(observation.duration_ms) / 1000.0;
        let protocol_elapsed = if playback.playing && observation.timestamp_ms > 0 {
            (chrono::Utc::now().timestamp_millis() - observation.timestamp_ms).clamp(0, 15_000)
                as f64
                / 1000.0
        } else {
            0.0
        };
        let anchored = f64::from(observation.position_ms) / 1000.0 + protocol_elapsed;
        self.anchored_position = if playback.duration > 0.0 {
            anchored.min(playback.duration)
        } else {
            anchored
        };
        self.anchored_at = Instant::now();
        playback.position = self.anchored_position;
        playback.shuffle = observation.shuffle;
        self.repeat = engine::RepeatFlags {
            context: observation.repeat_context,
            track: observation.repeat_track,
        };
        playback.repeat = if observation.repeat_track {
            "track"
        } else if observation.repeat_context {
            "context"
        } else {
            "off"
        }
        .into();
        if record {
            let uri = playback.uri.clone();
            let mut track = self.metadata.get(&uri).cloned().unwrap_or_else(|| Track {
                id: uri.clone(),
                uri: uri.clone(),
                title: "Unknown track".into(),
                ..Track::default()
            });
            track.added = chrono::Utc::now().to_rfc3339();
            self.snapshot.history.retain(|row| row.uri != uri);
            self.snapshot.history.insert(0, track);
            self.snapshot.history.truncate(10);
            self.save("history", &self.snapshot.history);
        }
        self.update_labels();
    }

    fn update_labels(&mut self) {
        let playback = &mut self.snapshot.playback;
        if let Some(track) = self.metadata.get(&playback.uri) {
            playback.title.clone_from(&track.title);
            playback.artist.clone_from(&track.artist);
            playback.artwork.clone_from(&track.artwork);
            if playback.duration == 0.0 {
                playback.duration = track.duration;
            }
        }
        for row in &mut self.snapshot.history {
            if let Some(metadata) = self.metadata.get(&row.uri) {
                let date = row.added.clone();
                *row = Track {
                    id: row.uri.clone(),
                    added: date,
                    ..metadata.clone()
                };
            }
        }
        self.rebuild_queue();
    }

    fn rebuild_queue(&mut self) {
        let Some(queue) = self.queue.as_ref() else {
            self.snapshot.queue.clone_from(&self.queue_fallback);
            return;
        };
        let proof = self.queue_from_dealer
            && matches!(self.owner, Owner::Remote(_))
            && self.engine_ready
            && queue_editable(queue, &self.snapshot);
        let rows = upcoming(queue);
        let mut ids = HashMap::new();
        for (index, item) in &rows {
            *ids.entry(queue_id(*index, item)).or_insert(0) += 1;
        }
        self.snapshot.queue = rows
            .into_iter()
            .map(|(index, item)| {
                let mut track = self
                    .metadata
                    .get(&item.uri)
                    .cloned()
                    .unwrap_or_else(|| Track {
                        uri: item.uri.clone(),
                        title: item
                            .metadata
                            .get("title")
                            .cloned()
                            .unwrap_or_else(|| "Unknown track".into()),
                        artist: item
                            .metadata
                            .get("artist")
                            .cloned()
                            .unwrap_or_else(|| "From the current context".into()),
                        ..Track::default()
                    });
                let key = queue_id(index, item);
                track.id = if ids[&key] > 1 {
                    format!("ambiguous-{index}-{key}")
                } else {
                    key
                };
                track.removable = proof;
                track
            })
            .collect();
    }

    fn hydrate(&mut self) {
        let Some(catalog) = self.catalog() else {
            return;
        };
        let id = self.account();
        let urls = std::iter::once(&self.snapshot.playback.uri).chain(
            self.snapshot
                .queue
                .iter()
                .chain(&self.snapshot.history)
                .map(|track| &track.uri),
        );
        for uri in urls {
            if self.metadata_jobs.len() >= 4 {
                break;
            }
            if uri.starts_with("spotify:track:")
                && !self.metadata.contains_key(uri)
                && self
                    .metadata_failed
                    .get(uri)
                    .is_none_or(|attempt| attempt.elapsed() > Duration::from_secs(60))
                && self.metadata_jobs.insert(uri.clone())
            {
                let catalog = catalog.clone();
                let uri = uri.clone();
                self.changes.spawn(async move {
                    let response = catalog.metadata(&uri).await;
                    Work::Track(id, uri, response)
                });
            }
        }
    }

    #[cfg(target_os = "macos")]
    fn media(&mut self, input: media::MediaInput) {
        let playback = &self.snapshot.playback;
        let stamp = self.snapshot.stamp;
        if input.stamp.account != stamp.account
            || input.stamp.engine != stamp.engine
            || input.stamp.route != stamp.route
            || input.track != playback.uri
            || self.snapshot.phase != "ready"
        {
            return;
        }
        use media::Action::*;
        let (action, number) = match input.action {
            Play if !playback.playing => ("toggle", None),
            Pause if playback.playing => ("toggle", None),
            Toggle => ("toggle", None),
            Next => ("next", None),
            Previous => ("previous", None),
            Seek if playback.duration > 0.0 => (
                "seek",
                input
                    .seconds
                    .map(|at| (at / playback.duration).clamp(0.0, 1.0)),
            ),
            _ => return,
        };
        self.command(Command {
            action: action.into(),
            value: Some(input.track),
            target: None,
            number,
            stamp: input.stamp,
        });
    }

    fn request_art(&mut self, account: u64, url: String) {
        if account != self.account() || self.session.is_none() {
            return;
        }
        if !self.artwork_jobs.insert(url.clone()) {
            return;
        }
        if self.artwork_jobs.len() <= 8 {
            self.start_art(account, url);
        } else if self.postponed_art.len() < 192 {
            self.postponed_art.push_back((account, url));
        } else {
            self.artwork_jobs.remove(&url);
            self.publish.artwork(account, url, None);
        }
    }

    fn start_art(&mut self, account: u64, address: String) {
        let http = self.http.clone();
        self.changes.spawn(async move {
            let result = async {
                let url = artwork_url(&address)?;
                let response = http.get(url).send().await.ok()?.error_for_status().ok()?;
                let bytes = auth::bounded(response, 8 * 1024 * 1024).await.ok()?;
                tokio::task::spawn_blocking(move || decode_artwork(bytes))
                    .await
                    .ok()?
            }
            .await;
            Work::Art(account, address, result)
        });
    }
}

fn retire_from_disk(files: &Storage, intent: Retirement) -> Result<Retirement> {
    engine::shutdown();
    files.complete_retirement(intent, |intent| {
        let streaming = engine::forget_credentials().map_err(|_| Failure::Storage);
        let catalog = files.purge_account_data(intent == Retirement::SignOut);
        streaming.and(catalog)
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|value| format!("{value:02x}")).collect()
}

fn cache_key(route: &Route) -> Option<String> {
    match route {
        Route::Home => Some("home".into()),
        Route::Likes => Some("likes".into()),
        Route::Detail(uri)
            if uri.starts_with("spotify:playlist:") || uri.starts_with("spotify:album:") =>
        {
            Some(hex(Sha256::digest(uri.as_bytes()).as_slice()))
        }
        _ => None,
    }
}

fn upcoming(queue: &engine::Queue) -> Vec<(usize, &engine::QueueTrack)> {
    queue
        .next
        .iter()
        .enumerate()
        .take_while(|(_, track)| track.uri != "spotify:delimiter")
        .filter(|(_, track)| track.uri.starts_with("spotify:track:"))
        .collect()
}

fn queue_id(index: usize, item: &engine::QueueTrack) -> String {
    if item.uid.is_empty() {
        format!("{index}-{}-{}", item.provider, item.uri)
    } else {
        format!("uid-{}-{}-{}", item.uid, item.provider, item.uri)
    }
}

fn same_queue(a: &engine::Queue, b: &engine::Queue) -> bool {
    a.generation == b.generation
        && a.track == b.track
        && a.context == b.context
        && a.removal_disallowed == b.removal_disallowed
        && a.next == b.next
        && a.previous == b.previous
}

fn queue_editable(queue: &engine::Queue, snap: &Snapshot) -> bool {
    if queue.removal_disallowed
        || queue.generation != snap.stamp.engine
        || queue.revision.is_none()
        || queue.track != snap.playback.uri
        || queue.context != snap.playback.context
        || queue.track.is_empty()
    {
        return false;
    }
    let rows = upcoming(queue);
    let mut identities = HashSet::new();
    let mut uris = HashMap::new();
    for (_, track) in &rows {
        if !track.uid.is_empty() && !identities.insert(&track.uid) {
            return false;
        }
        *uris.entry(&track.uri).or_insert(0) += 1;
    }
    rows.iter()
        .all(|(_, track)| !track.uid.is_empty() || uris[&track.uri] == 1)
}

fn selected(value: &str) -> Vec<String> {
    if value.starts_with('[') {
        serde_json::from_str::<Vec<String>>(value).unwrap_or_default()
    } else if value.is_empty() {
        Vec::new()
    } else {
        vec![value.into()]
    }
}

#[derive(Clone)]
enum Intent {
    Toggle {
        playing: bool,
        track: String,
        context: String,
        position: u32,
    },
    Previous,
    Next,
    Seek(u32),
    Shuffle(bool),
    Repeat {
        previous: engine::RepeatFlags,
        target: engine::RepeatFlags,
    },
    Play(String),
    PlayTracks(Vec<String>),
    Transfer {
        to: String,
        local: bool,
    },
    Add(Vec<String>),
    Replace {
        payload: Value,
        remaining: Vec<Occurrence>,
    },
}

impl Worker {
    fn command(&mut self, request: Command) {
        let stamp = self.snapshot.stamp;
        if request.stamp.account != stamp.account {
            return;
        }
        let value = request.value.as_deref().unwrap_or_default();
        let target = request.target.as_deref().unwrap_or_default();
        let current_view =
            request.stamp.view == stamp.view && request.stamp.catalog == stamp.catalog;
        let current_route =
            request.stamp.route == stamp.route && request.stamp.engine == stamp.engine;
        match request.action.as_str() {
            "connect" if !self.unloading && self.authorization.is_none() => {
                if self.retirement.is_some() {
                    self.finish_retirement();
                } else if self.snapshot.phase == "failed"
                    && !self.snapshot.reauthenticate
                    && let Some(session) = self.session.clone()
                {
                    self.phase("connecting", "Starting Spotty Connect…", false);
                    self.start_engine(session, false);
                } else if matches!(self.snapshot.phase.as_str(), "failed" | "signedOut") {
                    if self.session.is_some() {
                        self.reset();
                    }
                    let account = self.account();
                    let http = self.http.clone();
                    self.phase("authorizing", "Waiting for Spotify…", false);
                    self.authorization =
                        Some(self.changes.spawn(async move {
                            Work::Grant(account, auth::authorize(http).await)
                        }));
                }
            }
            "cancelConnect" => {
                if let Some(auth) = self.authorization.take() {
                    auth.abort();
                    self.phase("signedOut", "Connect to Spotify Premium", false);
                }
            }
            "logout" => self.logout(),
            "route" if self.snapshot.catalog_ready && request.stamp.catalog == stamp.catalog => {
                let route = match value {
                    "home" => Route::Home,
                    "search" => Route::Search,
                    "library" => Route::Library,
                    "likes" => Route::Likes,
                    "detail" if valid_catalog_uri(target) => Route::Detail(target.to_owned()),
                    "discography"
                        if target.starts_with("spotify:artist:") && valid_catalog_uri(target) =>
                    {
                        Route::Discography(target.to_owned())
                    }
                    _ => return,
                };
                if self.route != route {
                    self.route = route;
                    self.snapshot.stamp.view = stamp.view.wrapping_add(1);
                    self.restore_route_cache();
                    self.load_route(false);
                }
            }
            "search"
                if self.snapshot.catalog_ready
                    && self.route == Route::Search
                    && request.stamp.catalog == stamp.catalog =>
            {
                let text = value.trim().chars().take(256).collect::<String>();
                if text != self.search {
                    self.search = text;
                    self.snapshot.stamp.view = stamp.view.wrapping_add(1);
                    self.load_route(false);
                }
            }
            "releaseTracks" | "retryRelease" if current_view && self.snapshot.catalog_ready => {
                self.load_release(value, request.action == "retryRelease");
            }
            "retry" if current_view && self.snapshot.catalog_ready => {
                self.load_profile();
                self.load_route(true);
            }
            "retryLibrary" if self.snapshot.catalog_ready && !self.snapshot.library_loading => {
                self.load_profile();
                if (!self.library_fresh || self.snapshot.library_error.is_some())
                    && let Some(catalog) = self.catalog()
                {
                    self.snapshot.library_loading = true;
                    self.snapshot.library_error = None;
                    let account = self.account();
                    self.changes
                        .spawn(async move { Work::Library(account, catalog.playlists().await) });
                }
            }
            "inspectQueue" => {
                self.hydrate();
                if self.queue.is_none()
                    && !self.queue_fallback_started
                    && let Some(catalog) = self.catalog()
                {
                    self.queue_fallback_started = true;
                    let account = self.account();
                    self.changes.spawn(async move {
                        Work::QueueFallback(account, catalog.web_queue().await)
                    });
                }
            }
            "addPlaylist" if current_view => {
                if !self
                    .snapshot
                    .edit_targets
                    .iter()
                    .any(|item| item.uri == target)
                {
                    return;
                }
                let uris: Vec<_> = self
                    .tracks(value)
                    .into_iter()
                    .map(|row| row.uri.clone())
                    .collect();
                if !uris.is_empty() {
                    self.edit_playlist(target, uris, Vec::new());
                }
            }
            "removePlaylist" if current_view && request.stamp.playlist == stamp.playlist => {
                if !self.snapshot.editable
                    || self
                        .snapshot
                        .details
                        .as_ref()
                        .is_none_or(|item| item.uri != target)
                {
                    return;
                }
                let rows = self.tracks(value);
                let occurrences = rows
                    .iter()
                    .filter_map(|row| row.occurrence.clone())
                    .collect::<Vec<_>>();
                if !occurrences.is_empty() && occurrences.len() == rows.len() {
                    self.edit_playlist(target, Vec::new(), occurrences);
                }
            }
            _ if current_route && self.engine_ready && self.pending.is_none() => {
                self.transport(request, current_view)
            }
            _ => {}
        }
    }

    fn tracks(&self, value: &str) -> Vec<&Track> {
        let ids: HashSet<_> = selected(value).into_iter().collect();
        self.snapshot
            .tracks
            .iter()
            .filter(|row| ids.contains(&row.id))
            .collect()
    }

    fn edit_playlist(&mut self, uri: &str, added: Vec<String>, removed: Vec<String>) {
        if self.edit_pending {
            return;
        }
        let Some(catalog) = self.catalog() else {
            return;
        };
        let account = self.account();
        let uri = uri.to_owned();
        self.edit_pending = true;
        let gate = Arc::clone(&self.playlist_authority);
        let scope = gate.load(Ordering::Acquire);
        self.changes.spawn(async move {
            let admit = || removed.is_empty() || gate.load(Ordering::Acquire) == scope;
            let response = catalog.edit_playlist(&uri, &added, &removed, &admit).await;
            Work::PlaylistEdit(account, uri, response)
        });
    }

    fn transport(&mut self, request: Command, current_view: bool) {
        let value = request.value.as_deref().unwrap_or_default();
        let pb = &self.snapshot.playback;
        let toggle = || Intent::Toggle {
            playing: pb.playing,
            track: pb.uri.clone(),
            context: pb.context.clone(),
            position: (pb.position * 1000.0) as u32,
        };
        let intent = match request.action.as_str() {
            "device"
                if self
                    .snapshot
                    .devices
                    .iter()
                    .any(|device| device.id == value && !device.active) =>
            {
                let local = self.local.as_deref() == Some(value);
                if local && !self.audio.available() {
                    self.report("No audio output is available.");
                    return;
                }
                Intent::Transfer {
                    to: value.into(),
                    local,
                }
            }
            _ if !pb.can_start => return,
            "toggle" if pb.can_toggle && (value.is_empty() || value == pb.uri) => toggle(),
            "previous" if pb.can_skip => Intent::Previous,
            "next" if pb.can_skip => Intent::Next,
            "seek" if value == pb.uri && pb.duration > 0.0 => {
                let Some(fraction) = request.number.filter(|v| (0.0..=1.0).contains(v)) else {
                    return;
                };
                Intent::Seek((fraction * pb.duration * 1000.0) as u32)
            }
            "shuffle" => Intent::Shuffle(!pb.shuffle),
            "repeat" => Intent::Repeat {
                previous: self.repeat,
                target: match pb.repeat.as_str() {
                    "context" => engine::RepeatFlags {
                        context: false,
                        track: true,
                    },
                    "track" => engine::RepeatFlags::default(),
                    _ => engine::RepeatFlags {
                        context: true,
                        track: false,
                    },
                },
            },
            "playItem" if current_view && self.find_item(value).is_some() => {
                if (value == pb.uri || value == pb.context) && pb.can_toggle {
                    toggle()
                } else {
                    Intent::Play(value.into())
                }
            }
            "playContext"
                if current_view
                    && self
                        .snapshot
                        .details
                        .as_ref()
                        .is_some_and(|item| item.uri == value) =>
            {
                if pb.shuffle
                    && value.starts_with("spotify:playlist:")
                    && !self.snapshot.cached
                    && !self.snapshot.tracks.is_empty()
                {
                    use rand::seq::SliceRandom;
                    let mut uris: Vec<_> = self
                        .snapshot
                        .tracks
                        .iter()
                        .map(|track| track.uri.clone())
                        .collect();
                    uris.shuffle(&mut rand::rng());
                    let recent =
                        |uri: &String| self.snapshot.history.iter().any(|row| row.uri == *uri);
                    uris.sort_by_key(recent);
                    Intent::PlayTracks(uris)
                } else {
                    Intent::Play(value.into())
                }
            }
            "playTrack" | "startTrack" if current_view => {
                let Some(track) = self.snapshot.tracks.iter().find(|row| row.id == value) else {
                    return;
                };
                if request.action == "playTrack"
                    && track.uri == pb.uri
                    && pb.can_toggle
                    && (!track.unavailable || pb.playing)
                {
                    toggle()
                } else if track.unavailable {
                    return;
                } else {
                    Intent::Play(track.uri.clone())
                }
            }
            "playQueue" if request.stamp.queue == self.snapshot.stamp.queue => {
                let Some(track) = self.snapshot.queue.iter().find(|row| row.id == value) else {
                    return;
                };
                Intent::Play(track.uri.clone())
            }
            "playHistory" => {
                let Some(track) = self.snapshot.history.iter().find(|row| row.id == value) else {
                    return;
                };
                Intent::Play(track.uri.clone())
            }
            "queueTrack"
                if current_view && request.stamp.playlist == self.snapshot.stamp.playlist =>
            {
                let uris = ordered_tracks(&self.snapshot.tracks, &selected(value))
                    .into_iter()
                    .map(|track| track.uri.clone())
                    .collect::<Vec<_>>();
                if uris.is_empty() {
                    return;
                }
                Intent::Add(uris)
            }
            "removeQueue"
                if request.stamp.queue == self.snapshot.stamp.queue
                    && matches!(self.owner, Owner::Remote(_)) =>
            {
                let Some(queue) = self.queue.as_ref() else {
                    return;
                };
                if !self.queue_from_dealer || !queue_editable(queue, &self.snapshot) {
                    self.report("The queue isn’t complete enough to edit safely.");
                    return;
                }
                let ids: HashSet<_> = selected(value).into_iter().collect();
                if ids.is_empty() {
                    return;
                }
                let indices: HashSet<_> = upcoming(queue)
                    .into_iter()
                    .filter_map(|(index, track)| {
                        ids.contains(&queue_id(index, track)).then_some(index)
                    })
                    .collect();
                if ids.len() != indices.len() {
                    self.report("That queue selection is no longer current.");
                    return;
                }
                let next: Vec<_> = queue
                    .next
                    .iter()
                    .enumerate()
                    .filter_map(|(i, row)| (!indices.contains(&i)).then_some(row))
                    .collect();
                Intent::Replace {
                    payload: json!({"endpoint": "set_queue", "next_tracks": next, "prev_tracks": queue.previous, "queue_revision": queue.revision}),
                    remaining: next.into_iter().map(Occurrence::of).collect(),
                }
            }
            _ => return,
        };
        self.dispatch(intent);
    }

    fn dispatch(&mut self, intent: Intent) {
        let Some(catalog) = self.catalog() else {
            return;
        };
        let account = self.account();
        let generation = self.snapshot.stamp.engine;
        let owner = self.owner.clone();
        let local = self.local.clone();
        let authority = Arc::clone(&self.authority);
        let observed = authority.load(Ordering::Acquire);
        let replacing = matches!(intent, Intent::Replace { .. });
        let queue_gate = Arc::clone(&self.queue_authority);
        let queue_stamp = queue_gate.load(Ordering::Acquire);
        let playback = self.playback_thread.clone();
        self.action = self.action.wrapping_add(1);
        let number = self.action;
        let queue = self.queue.as_ref().filter(|queue| {
            self.queue_from_dealer
                && queue.revision.is_some()
                && queue.track == self.snapshot.playback.uri
                && queue.context == self.snapshot.playback.context
        });
        let pending = Pending::new(
            intent.clone(),
            &self.snapshot.playback,
            owner.clone(),
            queue,
        );
        let dispatch = Arc::clone(&pending.dispatch);
        self.pending = Some(pending);
        self.changes.spawn(async move {
            let admit = move || {
                authority.load(Ordering::Acquire) == observed
                    && (!replacing || queue_gate.load(Ordering::Acquire) == queue_stamp)
                    && dispatch.begin()
            };
            let result = match (&owner, &intent) {
                (_, Intent::Transfer { .. }) | (Owner::Local, _) => playback
                    .call(move || {
                        if !admit() {
                            return Err(Failure::Retired);
                        }
                        local_command(generation, &intent)
                    })
                    .await
                    .unwrap_or(Err(Failure::Network)),
                (Owner::Remote(device), _) => {
                    if let Some(local) = local {
                        remote_command(catalog, &local, device, &intent, &admit).await
                    } else {
                        Err(Failure::Retired)
                    }
                }
                _ => Err(Failure::Retired),
            };
            Work::Action(account, number, result)
        });
    }
}

fn local_command(generation: u64, intent: &Intent) -> Result<ActionReceipt> {
    let send = |command| engine::command(generation, command);
    let result = match intent {
        Intent::Toggle { playing: true, .. } => send(engine::Command::Pause),
        Intent::Toggle {
            track,
            context,
            position,
            ..
        } => send(engine::Command::Resume {
            track,
            context: (!context.is_empty()).then_some(context.as_str()),
            position: *position,
        }),
        Intent::Previous => send(engine::Command::Previous),
        Intent::Next => send(engine::Command::Next),
        Intent::Seek(position) => send(engine::Command::Seek(*position)),
        Intent::Shuffle(enabled) => send(engine::Command::Shuffle(*enabled)),
        Intent::Repeat { target, .. } => send(engine::Command::Repeat(*target)),
        Intent::Play(uri) => send(engine::Command::Play(uri)),
        Intent::PlayTracks(tracks) => send(engine::Command::PlayTracks(tracks)),
        Intent::Transfer { to, local } => {
            send(engine::Command::Transfer((!*local).then_some(to.as_str())))
        }
        Intent::Add(tracks) => {
            let done = tracks
                .iter()
                .take_while(|track| send(engine::Command::Add(track)).is_ok())
                .count();
            return queue_feedback(tracks.len(), done);
        }
        Intent::Replace { .. } => return Err(Failure::Uncertain),
    };
    match result {
        Ok(()) => Ok(ActionReceipt::default()),
        Err(engine::CommandError::CredentialsRejected) => Err(Failure::Revoked),
        Err(engine::CommandError::NeedsReinitialization) => {
            engine::reconnect();
            Err(Failure::Uncertain)
        }
        Err(_) => Err(Failure::Uncertain),
    }
}

async fn remote_command(
    catalog: Catalog,
    source: &str,
    target: &str,
    intent: &Intent,
    admit: &(impl Fn() -> bool + Sync),
) -> Result<ActionReceipt> {
    let command = match intent {
        Intent::Toggle { playing, .. } => {
            json!({"endpoint": if *playing { "pause" } else { "resume" }})
        }
        Intent::Previous => json!({"endpoint":"skip_prev"}),
        Intent::Next => json!({"endpoint":"skip_next"}),
        Intent::Seek(ms) => json!({"endpoint":"seek_to","value":ms}),
        Intent::Shuffle(enabled) => json!({"endpoint":"set_shuffling_context","value":enabled}),
        Intent::Repeat {
            previous,
            target: flags,
        } => {
            let repeat_payload = |change| match change {
                engine::RepeatChange::Context(value) => {
                    json!({"endpoint": "set_repeating_context", "value": value})
                }
                engine::RepeatChange::Track(value) => {
                    json!({"endpoint": "set_repeating_track", "value": value})
                }
            };
            for (index, change) in previous.changes(*flags).enumerate() {
                let result = catalog
                    .connect(source, target, repeat_payload(change), admit)
                    .await;
                if let Err(error) = result {
                    if index > 0 {
                        let restore = engine::RepeatChange::Context(previous.context);
                        let _ = catalog
                            .connect(source, target, repeat_payload(restore), admit)
                            .await;
                    }
                    return Err(error);
                }
            }
            return Ok(ActionReceipt::default());
        }
        Intent::Play(uri) => {
            let mut context = json!({"uri":uri,"url":format!("context://{uri}")});
            let mut command = json!({"endpoint":"play"});
            if uri.starts_with("spotify:track:") {
                let options = json!({"skip_to":{"track_uri":uri}});
                context["options"] = options.clone();
                command["options"] = options;
            }
            command["context"] = context;
            command
        }
        Intent::PlayTracks(tracks) => json!({"endpoint":"play","context":{
            "uri":"","url":"","pages":[{"tracks":tracks.iter().map(|uri| json!({"uri":uri})).collect::<Vec<_>>()}]
        }}),
        Intent::Add(tracks) => {
            let mut done = 0;
            for uri in tracks {
                let result = catalog.connect(source, target, json!({"endpoint":"add_to_queue","track":{"uri":uri,"uid":"","metadata":{}}}), admit).await;
                if matches!(result, Err(Failure::Revoked | Failure::Retired)) {
                    return result.map(|()| ActionReceipt::default());
                }
                if result.is_err() {
                    break;
                }
                done += 1;
            }
            return queue_feedback(tracks.len(), done);
        }
        Intent::Replace { payload, .. } => payload.clone(),
        Intent::Transfer { .. } => return Err(Failure::Uncertain),
    };
    catalog.connect(source, target, command, admit).await?;
    Ok(ActionReceipt::default())
}

fn queue_feedback(total: usize, done: usize) -> Result<ActionReceipt> {
    if done == 0 {
        return Err(Failure::Uncertain);
    }
    let notice = if total == 1 {
        "Queue request sent".into()
    } else if total == done {
        format!("Queue requests sent for {done} songs")
    } else {
        format!("Queue requests sent for {done} of {total} songs")
    };
    Ok(ActionReceipt {
        notice: Some(notice),
        sent_partial: total != done,
    })
}

pub fn valid_catalog_uri(uri: &str) -> bool {
    uri.strip_prefix("spotify:")
        .and_then(|uri| uri.split_once(':'))
        .is_some_and(|(kind, id)| {
            matches!(kind, "playlist" | "album" | "artist")
                && !id.is_empty()
                && id.len() <= 64
                && id.bytes().all(|c| c.is_ascii_alphanumeric())
        })
}

pub fn artwork_url(address: &str) -> Option<reqwest::Url> {
    let url = reqwest::Url::parse(address).ok()?;
    let host = url.host_str()?;
    if url.scheme() != "https"
        || !(host.ends_with(".scdn.co") || host.ends_with(".spotifycdn.com"))
        || url.port().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    Some(url)
}

fn decode_artwork(bytes: Vec<u8>) -> Option<Artwork> {
    let mut reader = image::ImageReader::new(std::io::Cursor::new(bytes))
        .with_guessed_format()
        .ok()?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(4096);
    limits.max_image_height = Some(4096);
    limits.max_alloc = Some(64 * 1024 * 1024);
    reader.limits(limits);
    let image = reader.decode().ok()?;
    let image = image.thumbnail(512, 512).into_rgba8();
    let (width, height) = image.dimensions();
    let mut tint = [0.0; 3];
    let mut weight = 0.0;
    for pixel in image.pixels().step_by(13) {
        let [r, g, b, alpha] = pixel.0;
        let chroma = (r.max(g).max(b) - r.min(g).min(b)) as f32 / 255.0;
        let score = chroma * f32::from(alpha) / 255.0;
        for (channel, component) in tint.iter_mut().zip([r, g, b]) {
            *channel += f32::from(component) * score;
        }
        weight += score;
    }
    let tint = tint.map(|channel| (20.0 + 0.23 * channel / weight.max(1.0)).round() as u8);
    Some(Artwork {
        width,
        height,
        rgba: image.into_raw(),
        tint,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_forced_refresh_retires_saved_playlist_authority_until_success() {
        let mut retained = CachedPage {
            loaded: Some(Instant::now()),
            page: Page {
                title: "Retained playlist".into(),
                ..Page::default()
            },
        };
        assert!(!retained.for_view(false).1);
        let (page, stale) = retained.for_view(true);
        assert_eq!(page.title, "Retained playlist");
        assert!(stale);
        assert!(retained.for_view(false).1);
    }

    fn row(id: &str, uid: &str) -> engine::QueueTrack {
        engine::QueueTrack {
            uri: id.into(),
            uid: uid.into(),
            provider: "queue".into(),
            metadata: [("is_queued".into(), "true".into())].into_iter().collect(),
            removed: Vec::new(),
            blocked: Vec::new(),
            restrictions: Default::default(),
            album_uri: String::new(),
            disallow_reasons: Vec::new(),
            artist_uri: String::new(),
        }
    }

    #[test]
    fn queue_admission_requires_current_protocol_occurrences() {
        let mut state = Snapshot {
            stamp: Stamp {
                engine: 3,
                ..Stamp::default()
            },
            ..Snapshot::default()
        };
        state.playback.uri = "spotify:track:playing".into();
        let mut queue = engine::Queue {
            sequence: 1,
            generation: 3,
            revision: Some("r".into()),
            track: state.playback.uri.clone(),
            context: String::new(),
            next: vec![
                row("spotify:track:duplicate", "one"),
                row("spotify:track:duplicate", "two"),
                row("spotify:delimiter", ""),
                row("spotify:track:autoplay", ""),
            ],
            previous: vec![row("spotify:track:previous", "before")],
            removal_disallowed: false,
        };
        assert_eq!(upcoming(&queue).len(), 2);
        assert!(queue_editable(&queue, &state));
        state.playback.context = "spotify:playlist:new".into();
        assert!(!queue_editable(&queue, &state));
        state.playback.context.clear();
        queue.next[1].uid = "one".into();
        assert!(!queue_editable(&queue, &state));
        queue.next[1].uid.clear();
        assert!(!queue_editable(&queue, &state));
        queue.next[1].uid = "two".into();
        queue.revision = None;
        assert!(!queue_editable(&queue, &state));
    }

    #[tokio::test(start_paused = true)]
    async fn restored_startup_uses_bounded_delays_and_stops_on_retirement_or_refusal() {
        let start = tokio::time::Instant::now();
        let mut attempts = Vec::new();
        let result = initialize_with_retry(true, || {
            attempts.push(start.elapsed().as_secs());
            std::future::ready(if attempts.len() == 3 {
                Ok(())
            } else {
                Err(engine::CommandError::Failed)
            })
        })
        .await;
        assert_eq!(result, Ok(()));
        assert_eq!(attempts, [0, 1, 4]);

        for (restored, error) in [
            (true, engine::CommandError::Superseded),
            (true, engine::CommandError::CredentialsRejected),
            (false, engine::CommandError::Failed),
        ] {
            let mut count = 0;
            let result = initialize_with_retry(restored, || {
                count += 1;
                std::future::ready(Err(error))
            })
            .await;
            assert_eq!(result, Err(error));
            assert_eq!(count, 1);
        }
    }

    #[test]
    fn terminal_streaming_refusal_prompts_for_sign_in() {
        assert!(matches!(
            StartResult::from_playback(Err(engine::CommandError::CredentialsRejected)),
            StartResult::NeedsSignIn
        ));
        assert!(matches!(
            StartResult::from_playback(Err(engine::CommandError::Failed)),
            StartResult::Failed(Failure::Network)
        ));
        assert!(matches!(
            StartResult::from_playback(Err(engine::CommandError::Superseded)),
            StartResult::Failed(Failure::Retired)
        ));
    }

    #[test]
    fn service_links_accept_only_expected_origins() {
        assert!(artwork_url("https://i.scdn.co/image/sample").is_some());
        assert!(artwork_url("https://i.scdn.co.example.com/image/sample").is_none());
        assert!(artwork_url("http://i.scdn.co/image/sample").is_none());
        assert!(valid_catalog_uri("spotify:playlist:123abc"));
        assert!(!valid_catalog_uri("spotify:playlist:123/abc"));
    }
}
