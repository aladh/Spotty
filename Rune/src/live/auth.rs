mod retirement;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use librespot_protocol::clienttoken_http::{
    ClientTokenRequest, ClientTokenRequestType, ClientTokenResponse,
};
use protobuf::Message;
use reqwest::{Client, Url};
use rustix::fs::{self as unix, AtFlags, Mode, OFlags};
use rustix::io::Errno;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::OsStr,
    fs::{File, Permissions},
    io::{self, Read, Write},
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::Mutex as AsyncMutex,
    time::{Instant, timeout, timeout_at},
};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

pub const CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
pub const APP_VERSION: &str = "1.2.84.476.ga1ff6607";
const TOKEN_URL: &str = "https://accounts.spotify.com/api/token";
const SCOPES: &str = concat!(
    "app-remote-control playlist-modify playlist-modify-private playlist-modify-public ",
    "playlist-read playlist-read-collaborative playlist-read-private streaming ugc-image-upload ",
    "user-follow-modify user-follow-read user-library-modify user-library-read user-modify ",
    "user-modify-playback-state user-modify-private user-personalized user-read-birthdate ",
    "user-read-currently-playing user-read-email user-read-play-history user-read-playback-position ",
    "user-read-playback-state user-read-private user-read-recently-played user-top-read"
);

#[derive(Clone, Copy, Debug, thiserror::Error)]
pub enum Failure {
    #[error("Spotify could not be reached.")]
    Network,
    #[error("Spotify rejected the request (HTTP {0}).")]
    Status(u16),
    #[error("Spotify returned an incomplete response.")]
    Response,
    #[error("The session expired. Sign in to Spotify again.")]
    Revoked,
    #[error("Couldn’t open the Spotify sign-in page.")]
    Browser,
    #[error("Couldn’t start the Spotify sign-in callback.")]
    Listener,
    #[error("Spotify sign-in timed out.")]
    Timeout,
    #[error("Spotify sign-in was declined.")]
    Declined,
    #[error("Spotty couldn’t access its private storage.")]
    Storage,
    #[error("Permission to read or write the saved Spotify session was denied.")]
    StorageDenied,
    #[error("The saved Spotify session is invalid. Sign in again.")]
    InvalidGrant,
    #[error("The Spotify session changed.")]
    Retired,
    #[error("Spotify could not confirm the change.")]
    Uncertain,
    #[error("Spotty could not verify playlist ownership or the selected occurrences.")]
    PlaylistAuthority,
}

pub type Result<T> = std::result::Result<T, Failure>;

#[derive(Clone, Deserialize, Serialize, ZeroizeOnDrop)]
#[serde(rename_all = "camelCase")]
pub struct Grant {
    #[serde(default = "schema")]
    pub schema_version: u32,
    pub access_token: String,
    refresh_token: String,
    // Foundation's Codable Date stores seconds since 2001-01-01. Existing grants use this value.
    expires_at: f64,
    #[serde(default)]
    username: String,
    #[serde(default)]
    pub requires_reauthentication: bool,
}

impl Grant {
    fn fingerprint(&self) -> [u8; 32] {
        let mut digest = Sha256::new();
        digest.update(self.access_token.len().to_be_bytes());
        digest.update(self.access_token.as_bytes());
        digest.update(self.refresh_token.as_bytes());
        digest.finalize().into()
    }
}

fn schema() -> u32 {
    1
}

fn now() -> f64 {
    chrono::Utc::now().timestamp() as f64 - 978_307_200.0
}

pub struct Storage {
    root: PathBuf,
    session: PathBuf,
    gate: Mutex<()>,
}

pub(super) enum StoredAccount {
    Grant(Option<Grant>),
    Retiring(super::Retirement),
}

const GRANT_LIMIT: u64 = 65_536;

impl Storage {
    pub fn new() -> Result<Self> {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .ok_or(Failure::Storage)?;
        #[cfg(target_os = "macos")]
        let root = home.join("Library/Application Support/Spotty");
        #[cfg(not(target_os = "macos"))]
        let root = std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home.join(".local/share"))
            .join("Spotty");
        let storage = Self::at(root)?;
        #[cfg(target_os = "macos")]
        {
            use objc2_foundation::{NSString, NSUserDefaults};
            let defaults = NSUserDefaults::standardUserDefaults();
            defaults.removeObjectForKey(&NSString::from_str("keymaster.tokens.v1"));
            let key = NSString::from_str("keymasterDeviceId");
            let existing = defaults.stringForKey(&key).map(|id| id.to_string());
            if let Some(id) = existing.filter(|id| valid_device_id(id)) {
                write_private(&storage.session.join("device"), id.as_bytes())?;
            } else {
                let id = NSString::from_str(&storage.device_id()?);
                // NSString is a supported UserDefaults property-list value.
                unsafe { defaults.setObject_forKey(Some(&id), &key) };
            }
        }
        Ok(storage)
    }

    fn at(root: PathBuf) -> Result<Self> {
        secure_dir(&root)?;
        let session = root.join("Session");
        secure_dir(&session)?;
        Ok(Self {
            root,
            session,
            gate: Mutex::default(),
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub(super) fn restore(&self) -> Result<StoredAccount> {
        let parent = self.lock_session()?;
        if let Some(intent) = Self::retirement_at(&parent)? {
            return Ok(StoredAccount::Retiring(intent));
        }
        Self::read_grant(&parent).map(StoredAccount::Grant)
    }

    #[cfg(test)]
    fn load(&self) -> Result<Option<Grant>> {
        match self.restore()? {
            StoredAccount::Grant(grant) => Ok(grant),
            StoredAccount::Retiring(_) => Err(Failure::Retired),
        }
    }

    fn read_grant(parent: &File) -> Result<Option<Grant>> {
        let Some(data) = read_at(parent, OsStr::new("session.json"), GRANT_LIMIT)? else {
            return Ok(None);
        };
        let grant: Grant = serde_json::from_slice(&data).map_err(|_| Failure::InvalidGrant)?;
        if grant.schema_version != schema()
            || grant.refresh_token.is_empty()
            || grant.access_token.is_empty()
            || !grant.expires_at.is_finite()
        {
            return Err(Failure::InvalidGrant);
        }
        Ok(Some(grant))
    }

    // Use the same directory flock and staging name as the Swift store.
    fn lock_session(&self) -> Result<File> {
        let parent = lock_dir(&self.session)?;
        let mut reclaimed = unlink_file(&parent, ".session.pending")?;
        reclaimed |= unlink_file(&parent, ".retirement.pending")?;
        // Earlier Rune builds used a random suffix; reclaim only that exact format.
        for entry in unix::Dir::read_from(&parent).map_err(io_failure)? {
            let entry = entry.map_err(io_failure)?;
            let name = entry.file_name();
            if let Some(suffix) = name.to_bytes().strip_prefix(b".session.json.")
                && let Some(nonce) = suffix.strip_suffix(b".pending")
                && nonce.len() == 16
                && nonce.iter().all(u8::is_ascii_hexdigit)
            {
                reclaimed |= unlink_file(&parent, name)?;
            }
        }
        if reclaimed {
            parent.sync_all().map_err(io_failure)?;
        }
        Ok(parent)
    }

    fn write_grant(&self, grant: &Grant, previous: Option<&Grant>) -> Result<()> {
        let parent = self.lock_session()?;
        if Self::retirement_at(&parent)?.is_some() {
            return Err(Failure::Retired);
        }
        if let Some(previous) = previous {
            let saved = Self::read_grant(&parent)?.ok_or(Failure::Retired)?;
            let same_tokens = |other: &Grant| {
                saved.access_token == other.access_token
                    && saved.refresh_token == other.refresh_token
            };
            // A failed directory sync can leave the new pair visible. Accept that retry,
            // but never let a late refresh recreate or replace a retired account.
            if saved.requires_reauthentication || !(same_tokens(previous) || same_tokens(grant)) {
                return Err(Failure::Retired);
            }
        }
        Self::write_grant_at(&parent, grant)
    }

    fn write_grant_at(parent: &File, grant: &Grant) -> Result<()> {
        let bytes = Zeroizing::new(serde_json::to_vec(grant).map_err(|_| Failure::Storage)?);
        if bytes.len() as u64 > GRANT_LIMIT {
            return Err(Failure::InvalidGrant);
        }
        write_at(
            parent,
            OsStr::new("session.json"),
            OsStr::new(".session.pending"),
            &bytes,
        )
    }

    pub fn publish(&self, grant: &Grant) -> Result<()> {
        let _guard = self.gate.lock().map_err(|_| Failure::Storage)?;
        self.write_grant(grant, None)
    }

    #[cfg(test)]
    fn clear(&self) -> Result<()> {
        self.begin_retirement(super::Retirement::SignOut)?;
        self.complete_retirement(super::Retirement::SignOut, |_| Ok(()))
            .map(drop)
    }

    pub fn device_id(&self) -> Result<String> {
        let directory = lock_dir(&self.session)?;
        let name = OsStr::new("device");
        if let Some(data) = read_at(&directory, name, 64)?
            && let Ok(text) = std::str::from_utf8(&data)
            && valid_device_id(text)
        {
            return Ok(text.to_owned());
        }
        let random: [u8; 20] = rand::random();
        let id: String = random.iter().map(|value| format!("{value:02x}")).collect();
        write_at(
            &directory,
            name,
            OsStr::new(".device.pending"),
            id.as_bytes(),
        )?;
        Ok(id)
    }
}

fn valid_device_id(id: &str) -> bool {
    id.len() == 40 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn io_failure(error: impl Into<io::Error>) -> Failure {
    if error.into().kind() == io::ErrorKind::PermissionDenied {
        Failure::StorageDenied
    } else {
        Failure::Storage
    }
}

// Resolve every component relative to its open parent. Neither permission changes nor
// credential reads/writes follow a symlink installed in place of an ancestor.
fn private_dir(path: &Path, create: bool) -> Result<File> {
    if !path.is_absolute() || path.parent().is_none() {
        return Err(Failure::Storage);
    }
    let mut parent = File::open("/").map_err(io_failure)?;
    let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    for component in path.components().skip(1) {
        let Component::Normal(name) = component else {
            return Err(Failure::Storage);
        };
        let child = match unix::openat(&parent, name, flags, Mode::empty()) {
            Err(Errno::NOENT) if create => {
                match unix::mkdirat(&parent, name, Mode::RWXU) {
                    Ok(()) | Err(Errno::EXIST) => {}
                    Err(error) => return Err(io_failure(error)),
                }
                unix::openat(&parent, name, flags, Mode::empty())
            }
            result => result,
        }
        .map_err(io_failure)?;
        parent = File::from(child);
    }
    if parent.metadata().map_err(io_failure)?.uid() != rustix::process::geteuid().as_raw() {
        return Err(Failure::StorageDenied);
    }
    parent
        .set_permissions(Permissions::from_mode(0o700))
        .map_err(io_failure)?;
    Ok(parent)
}

pub fn secure_dir(path: &Path) -> Result<()> {
    private_dir(path, true).map(drop)
}

fn lock_dir(path: &Path) -> Result<File> {
    let parent = private_dir(path, false)?;
    parent.lock().map_err(io_failure)?;
    Ok(parent)
}

fn read_at(parent: &File, name: &OsStr, limit: u64) -> Result<Option<Zeroizing<Vec<u8>>>> {
    let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC;
    let file = match unix::openat(parent, name, flags, Mode::empty()) {
        Ok(fd) => File::from(fd),
        Err(Errno::NOENT) => return Ok(None),
        Err(error) => return Err(io_failure(error)),
    };
    let meta = file.metadata().map_err(io_failure)?;
    if !meta.is_file() || meta.len() > limit || meta.nlink() != 1 {
        return Err(Failure::Storage);
    }
    if meta.uid() != rustix::process::geteuid().as_raw() {
        return Err(Failure::StorageDenied);
    }
    file.set_permissions(Permissions::from_mode(0o600))
        .map_err(io_failure)?;
    let mut bytes = Zeroizing::new(Vec::new());
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(io_failure)?;
    if bytes.len() as u64 > limit {
        return Err(Failure::Storage);
    }
    Ok(Some(bytes))
}

pub fn read_private(path: &Path, limit: u64) -> Result<Option<Zeroizing<Vec<u8>>>> {
    let parent = lock_dir(path.parent().ok_or(Failure::Storage)?)?;
    read_at(&parent, path.file_name().ok_or(Failure::Storage)?, limit)
}

fn unlink_file(parent: &File, name: impl rustix::path::Arg) -> Result<bool> {
    match unix::unlinkat(parent, name, AtFlags::empty()) {
        Ok(()) => Ok(true),
        Err(Errno::NOENT) => Ok(false),
        Err(error) => Err(io_failure(error)),
    }
}

fn write_at(parent: &File, name: &OsStr, temporary: &OsStr, bytes: &[u8]) -> Result<()> {
    unlink_file(parent, temporary)?;
    let flags = OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let mut file = File::from(
        unix::openat(parent, temporary, flags, Mode::RUSR | Mode::WUSR).map_err(io_failure)?,
    );
    let result = (|| -> Result<()> {
        file.set_permissions(Permissions::from_mode(0o600))
            .map_err(io_failure)?;
        file.write_all(bytes).map_err(io_failure)?;
        file.sync_all().map_err(io_failure)?;
        unix::renameat(parent, temporary, parent, name).map_err(io_failure)?;
        parent.sync_all().map_err(io_failure)
    })();
    if result.is_err() {
        let _ = unlink_file(parent, temporary);
    }
    result
}

#[cfg(target_os = "macos")]
fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = lock_dir(path.parent().ok_or(Failure::Storage)?)?;
    let name = path.file_name().ok_or(Failure::Storage)?;
    let mut stage = std::ffi::OsString::from(".");
    stage.push(name);
    stage.push(".pending");
    write_at(&parent, name, &stage, bytes)
}

struct SessionGrant {
    value: Grant,
    previous: Option<Grant>,
}

pub struct Session {
    pub http: Client,
    pub storage: Arc<Storage>,
    pub device: String,
    grant: AsyncMutex<SessionGrant>,
    committed_grant: Mutex<[u8; 32]>,
    client_token: AsyncMutex<Option<(String, Instant)>>,
    retired: std::sync::atomic::AtomicBool,
}

impl Session {
    pub fn new(http: Client, storage: Arc<Storage>, device: String, grant: Grant) -> Self {
        let committed_grant = Mutex::new(grant.fingerprint());
        Self {
            http,
            storage,
            device,
            grant: AsyncMutex::new(SessionGrant {
                value: grant,
                previous: None,
            }),
            committed_grant,
            client_token: AsyncMutex::new(None),
            retired: false.into(),
        }
    }

    pub fn check(&self) -> Result<()> {
        if self.retired.load(std::sync::atomic::Ordering::Acquire) {
            Err(Failure::Retired)
        } else {
            Ok(())
        }
    }

    pub fn retire(&self) {
        let _lock = self.storage.gate.lock().ok();
        self.retired
            .store(true, std::sync::atomic::Ordering::Release);
    }

    pub fn write_catalog(&self, path: &Path, bytes: &[u8]) -> Result<()> {
        let _guard = self.storage.gate.lock().map_err(|_| Failure::Storage)?;
        self.check()?;
        let committed = self.committed_grant.lock().map_err(|_| Failure::Storage)?;
        self.storage.write_catalog(&committed, path, bytes)
    }

    fn save_pending(&self, grant: &mut SessionGrant) -> Result<()> {
        let _guard = self.storage.gate.lock().map_err(|_| Failure::Storage)?;
        self.check()?;
        if let Some(previous) = &grant.previous {
            let result = self.storage.write_grant(&grant.value, Some(previous));
            if matches!(result, Err(Failure::Retired)) {
                self.retired
                    .store(true, std::sync::atomic::Ordering::Release);
            }
            result?;
            *self.committed_grant.lock().map_err(|_| Failure::Storage)? = grant.value.fingerprint();
            grant.previous = None;
        }
        Ok(())
    }

    pub async fn access(&self, rejected: Option<&str>) -> Result<Zeroizing<String>> {
        self.access_from(TOKEN_URL, rejected).await
    }

    async fn access_from(
        &self,
        endpoint: &str,
        rejected: Option<&str>,
    ) -> Result<Zeroizing<String>> {
        let mut grant = self.grant.lock().await;
        self.save_pending(&mut grant)?;
        let current = &grant.value;
        if current.requires_reauthentication {
            return Err(Failure::Revoked);
        }
        if current.expires_at - now() > 300.0 && rejected != Some(current.access_token.as_str()) {
            return Ok(Zeroizing::new(current.access_token.clone()));
        }
        let body = [
            ("grant_type", "refresh_token"),
            ("refresh_token", &current.refresh_token),
            ("client_id", CLIENT_ID),
        ];
        let mut next = exchange(&self.http, endpoint, &body, Some(&current.refresh_token)).await?;
        if next.username.is_empty() {
            next.username.clone_from(&current.username);
        }
        // The service may have spent the previous refresh token. Keep the full
        // rotation even when storage fails; its access token stays private until saved.
        grant.previous = Some(std::mem::replace(&mut grant.value, next));
        self.save_pending(&mut grant)?;
        Ok(Zeroizing::new(grant.value.access_token.clone()))
    }

    pub async fn client_token(&self, rejected: Option<&str>) -> Result<String> {
        let mut cached = self.client_token.lock().await;
        self.check()?;
        if let Some((token, expiry)) = &*cached
            && *expiry > Instant::now() + Duration::from_secs(30)
            && rejected != Some(token.as_str())
        {
            return Ok(token.clone());
        }
        let mut message = ClientTokenRequest::new();
        message.request_type = ClientTokenRequestType::REQUEST_CLIENT_DATA_REQUEST.into();
        let data = message.mut_client_data();
        data.client_id = CLIENT_ID.into();
        data.client_version = APP_VERSION.into();
        let connectivity = data.mut_connectivity_sdk_data();
        connectivity.device_id.clone_from(&self.device);
        connectivity
            .platform_specific_data
            .mut_or_insert_default()
            .mut_desktop_macos();
        let bytes = message.write_to_bytes().map_err(|_| Failure::Response)?;
        let response = self
            .http
            .post("https://clienttoken.spotify.com/v1/clienttoken")
            .header("Content-Type", "application/x-protobuf")
            .header("Accept", "application/x-protobuf")
            .header("Spotify-App-Version", APP_VERSION)
            .body(bytes)
            .send()
            .await
            .map_err(|_| Failure::Network)?;
        let status = response.status();
        if !status.is_success() {
            return Err(Failure::Status(status.as_u16()));
        }
        let data = bounded(response, 65_536).await?;
        let answer = ClientTokenResponse::parse_from_bytes(&data).map_err(|_| Failure::Response)?;
        let token = answer.granted_token();
        if token.token.is_empty() {
            return Err(Failure::Response);
        }
        self.check()?;
        let expires = if token.expires_after_seconds > 0 {
            token.expires_after_seconds as u64
        } else {
            3600
        };
        *cached = Some((
            token.token.clone(),
            Instant::now() + Duration::from_secs(expires),
        ));
        Ok(token.token.clone())
    }
}

pub fn http() -> Result<Client> {
    Client::builder()
        .timeout(Duration::from_secs(20))
        .connect_timeout(Duration::from_secs(8))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| Failure::Network)
}

pub async fn bounded(mut response: reqwest::Response, limit: usize) -> Result<Vec<u8>> {
    if response
        .content_length()
        .is_some_and(|size| size > limit as u64)
    {
        return Err(Failure::Response);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| Failure::Network)? {
        if bytes.len().saturating_add(chunk.len()) > limit {
            return Err(Failure::Response);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

#[derive(Deserialize, ZeroizeOnDrop)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: f64,
    username: Option<String>,
}

async fn exchange(
    http: &Client,
    endpoint: &str,
    fields: &[(&str, &str)],
    fallback: Option<&str>,
) -> Result<Grant> {
    let response = http
        .post(endpoint)
        .form(fields)
        .send()
        .await
        .map_err(|_| Failure::Network)?;
    let status = response.status();
    let mut bytes = Zeroizing::new(bounded(response, 65_536).await?);
    if !status.is_success() {
        #[derive(Deserialize)]
        struct TokenError {
            error: String,
        }
        return if serde_json::from_slice::<TokenError>(&bytes)
            .is_ok_and(|error| error.error == "invalid_grant")
        {
            Err(Failure::Revoked)
        } else {
            Err(Failure::Status(status.as_u16()))
        };
    }
    let mut answer: TokenResponse =
        serde_json::from_slice(&bytes).map_err(|_| Failure::Response)?;
    bytes.zeroize();
    let refresh = answer
        .refresh_token
        .take()
        .or_else(|| fallback.map(str::to_owned))
        .filter(|token| !token.is_empty())
        .ok_or(Failure::Response)?;
    if answer.access_token.is_empty() || !answer.expires_in.is_finite() || answer.expires_in <= 0.0
    {
        return Err(Failure::Response);
    }
    Ok(Grant {
        schema_version: schema(),
        access_token: std::mem::take(&mut answer.access_token),
        refresh_token: refresh,
        expires_at: now() + answer.expires_in,
        username: answer.username.take().unwrap_or_default(),
        requires_reauthentication: false,
    })
}

pub async fn authorize(http: Client) -> Result<Grant> {
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|_| Failure::Listener)?;
    let port = listener.local_addr().map_err(|_| Failure::Listener)?.port();
    let redirect = format!("http://127.0.0.1:{port}/login");
    let verifier = Zeroizing::new(URL_SAFE_NO_PAD.encode(rand::random::<[u8; 48]>()));
    let state = Zeroizing::new(URL_SAFE_NO_PAD.encode(rand::random::<[u8; 32]>()));
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let mut url =
        Url::parse("https://accounts.spotify.com/authorize").map_err(|_| Failure::Browser)?;
    url.query_pairs_mut().extend_pairs([
        ("client_id", CLIENT_ID),
        ("response_type", "code"),
        ("redirect_uri", &redirect),
        ("scope", SCOPES),
        ("state", &*state),
        ("code_challenge_method", "S256"),
        ("code_challenge", &challenge),
    ]);
    open::that_detached(url.as_str()).map_err(|_| Failure::Browser)?;

    let deadline = Instant::now() + Duration::from_secs(180);
    let code = loop {
        let (mut socket, _) = timeout_at(deadline, listener.accept())
            .await
            .map_err(|_| Failure::Timeout)?
            .map_err(|_| Failure::Listener)?;
        let mut buffer = Zeroizing::new(Vec::new());
        let read_request = async {
            while buffer.len() < 8192 && !buffer.ends_with(b"\r\n\r\n") {
                let mut chunk = [0; 1024];
                let size = socket.read(&mut chunk).await?;
                if size == 0 {
                    break;
                }
                buffer.extend_from_slice(&chunk[..size]);
                if buffer.windows(4).any(|part| part == b"\r\n\r\n") {
                    break;
                }
            }
            std::io::Result::Ok(())
        };
        if !matches!(
            timeout(Duration::from_secs(2), read_request).await,
            Ok(Ok(()))
        ) {
            continue;
        }
        let result = callback(&buffer, &state);
        let (status, message) = match result {
            Some(Ok(_)) => (
                "200 OK",
                "Signed in. You can close this tab and return to Spotty.",
            ),
            Some(Err(_)) => (
                "200 OK",
                "Spotify sign-in was cancelled. You can close this tab.",
            ),
            None => (
                "400 Bad Request",
                "This request does not match the active Spotify sign-in.",
            ),
        };
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{message}",
            message.len()
        );
        let _ = timeout(
            Duration::from_millis(250),
            socket.write_all(response.as_bytes()),
        )
        .await;
        if let Some(result) = result {
            break Zeroizing::new(result?);
        }
    };
    drop(listener);
    exchange(
        &http,
        TOKEN_URL,
        &[
            ("grant_type", "authorization_code"),
            ("code", &code),
            ("redirect_uri", &redirect),
            ("client_id", CLIENT_ID),
            ("code_verifier", &verifier),
        ],
        None,
    )
    .await
}

fn callback(bytes: &[u8], expected: &str) -> Option<Result<String>> {
    let line = std::str::from_utf8(bytes).ok()?.split_once("\r\n")?.0;
    let mut fields = line.split_whitespace();
    if fields.next()? != "GET" {
        return None;
    }
    let target = fields.next()?;
    if !target.starts_with("/login?")
        || !matches!(fields.next()?, "HTTP/1.1" | "HTTP/1.0")
        || fields.next().is_some()
    {
        return None;
    }
    let parsed = Url::parse(&format!("http://127.0.0.1{target}")).ok()?;
    let mut state = None;
    let mut code = None;
    let mut denied = false;
    for (key, value) in parsed.query_pairs() {
        match key.as_ref() {
            "state" if state.is_none() => state = Some(value),
            "code" if code.is_none() => code = Some(value.into_owned()),
            "state" | "code" => return None,
            "error" => denied = true,
            _ => {}
        }
    }
    if state.as_deref() != Some(expected) {
        return None;
    }
    if denied {
        return Some(Err(Failure::Declined));
    }
    Some(
        code.filter(|code| !code.is_empty())
            .ok_or(Failure::Response),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, Arc<Storage>) {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap().join("Spotty");
        let storage = Arc::new(Storage::at(root).unwrap());
        (directory, storage)
    }

    #[test]
    fn a_retired_grant_cannot_restart_catalog_writes_after_another_login() {
        let (_directory, storage) = fixture();
        let saved = grant();
        storage.publish(&saved).unwrap();
        let account = storage.root().join("RuneCatalog").join("a".repeat(64));
        let path = account.join("home.json");
        let stale = Session::new(Client::new(), Arc::clone(&storage), "device".into(), saved);
        let in_flight_refresh = stale.grant.try_lock().unwrap();
        stale.write_catalog(&path, b"before").unwrap();
        drop(in_flight_refresh);
        storage.clear().unwrap();
        std::fs::remove_file(&path).unwrap();
        assert!(matches!(
            stale.write_catalog(&path, b"after"),
            Err(Failure::Retired)
        ));
        let mut replacement = grant();
        replacement.access_token = "replacement".into();
        storage.publish(&replacement).unwrap();
        assert!(matches!(
            stale.write_catalog(&path, b"after"),
            Err(Failure::Retired)
        ));
        assert!(!path.exists());
    }

    fn grant() -> Grant {
        Grant {
            schema_version: 1,
            access_token: "old-access".into(),
            refresh_token: "old-refresh".into(),
            expires_at: now() - 100.0,
            username: "fixture".into(),
            requires_reauthentication: false,
        }
    }

    #[test]
    fn grant_restores_swift_format_and_reclaims_only_private_staging_files() {
        let (_fixture, storage) = fixture();
        let dir = &storage.session;
        let old = br#"{"accessToken":"fixture","refreshToken":"fixture","expiresAt":1234.5,"username":"fixture"}"#;
        std::fs::write(dir.join("session.json"), old).unwrap();
        for name in [
            ".session.pending",
            ".session.json.0123456789abcdef.pending",
            "keep.pending",
        ] {
            std::fs::write(dir.join(name), b"synthetic").unwrap();
        }
        let grant = storage.load().unwrap().unwrap();
        assert!(!grant.requires_reauthentication);
        assert_eq!(grant.expires_at, 1234.5);
        assert!(!dir.join(".session.pending").exists());
        assert!(!dir.join(".session.json.0123456789abcdef.pending").exists());
        assert!(dir.join("keep.pending").exists());
        let guard = storage.lock_session().unwrap();
        assert!(File::open(dir).unwrap().try_lock().is_err());
        drop(guard);
        assert_eq!(dir.metadata().unwrap().mode() & 0o777, 0o700);
        assert_eq!(
            dir.join("session.json").metadata().unwrap().mode() & 0o777,
            0o600
        );
        std::fs::write(dir.join("session.json"), b"{}").unwrap();
        assert!(matches!(storage.load(), Err(Failure::InvalidGrant)));
        storage.clear().unwrap();
        assert!(storage.load().unwrap().is_none());
    }

    #[test]
    fn grant_store_refuses_linked_directories_and_credentials() {
        use std::os::unix::fs::symlink;
        let (fixture, storage) = fixture();
        let base = fixture.path().canonicalize().unwrap();
        symlink(storage.root(), base.join("link")).unwrap();
        assert!(Storage::at(base.join("link/child")).is_err());
        assert!(!storage.root().join("child").exists());
        let other = base.join("unrelated");
        std::fs::write(&other, b"synthetic").unwrap();
        let path = storage.session.join("session.json");
        symlink(&other, &path).unwrap();
        assert!(storage.load().is_err());
        storage.clear().unwrap();
        std::fs::hard_link(&other, &path).unwrap();
        assert!(storage.load().is_err());
        assert_eq!(std::fs::read(other).unwrap(), b"synthetic");
    }

    #[test]
    fn explicit_signout_recovers_an_unreadable_retirement_value() {
        let (_fixture, storage) = fixture();
        storage.publish(&grant()).unwrap();
        std::fs::write(storage.session.join("retirement"), b"incomplete").unwrap();
        assert!(storage.restore().is_err());
        storage.clear().unwrap();
        assert!(matches!(storage.restore(), Ok(StoredAccount::Grant(None))));
    }

    #[test]
    fn failed_logout_retries_deletion_before_restoring_a_grant() {
        let (_fixture, storage) = fixture();
        let grant_path = storage.session.join("session.json");
        std::fs::create_dir(&grant_path).unwrap();
        assert!(storage.clear().is_err());
        std::fs::remove_dir(&grant_path).unwrap();
        std::fs::write(&grant_path, serde_json::to_vec(&grant()).unwrap()).unwrap();
        let reopened = Storage::at(storage.root.clone()).unwrap();
        assert!(matches!(
            reopened.restore(),
            Ok(StoredAccount::Retiring(super::super::Retirement::SignOut))
        ));
        assert!(matches!(reopened.publish(&grant()), Err(Failure::Retired)));
        reopened.clear().unwrap();
        assert!(reopened.load().unwrap().is_none());
        assert!(!grant_path.exists());
        storage.publish(&grant()).unwrap();
        assert!(storage.load().unwrap().is_some());
    }

    #[test]
    fn interrupted_retirement_preserves_the_strongest_intent_until_cleanup_succeeds() {
        use crate::live::Retirement::{Reauthenticate, SignOut};
        let (_fixture, storage) = fixture();
        storage.publish(&grant()).unwrap();
        storage.begin_retirement(Reauthenticate).unwrap();
        assert!(
            Storage::read_grant(&storage.lock_session().unwrap())
                .unwrap()
                .unwrap()
                .requires_reauthentication
        );
        let reopened = Storage::at(storage.root.clone()).unwrap();
        assert!(matches!(
            reopened.restore(),
            Ok(StoredAccount::Retiring(Reauthenticate))
        ));
        let mut cleanups = Vec::new();
        let result = reopened.complete_retirement(Reauthenticate, |intent| {
            cleanups.push(intent);
            if intent == Reauthenticate {
                // A second instance escalates while the first owns cleanup.
                storage.begin_retirement(SignOut)?;
                Ok(())
            } else {
                Err(Failure::Storage)
            }
        });
        assert!(matches!(result, Err(Failure::Storage)));
        assert_eq!(cleanups, [Reauthenticate, SignOut]);
        assert!(!storage.session.join("session.json").exists());
        assert!(matches!(
            storage.restore(),
            Ok(StoredAccount::Retiring(SignOut))
        ));
        assert!(matches!(storage.publish(&grant()), Err(Failure::Retired)));
        assert!(
            reopened
                .complete_retirement(SignOut, |_| Err(Failure::Storage))
                .is_err()
        );
        assert!(matches!(
            storage.restore(),
            Ok(StoredAccount::Retiring(SignOut))
        ));
        reopened.complete_retirement(SignOut, |_| Ok(())).unwrap();
        assert!(matches!(storage.restore(), Ok(StoredAccount::Grant(None))));
        storage.publish(&grant()).unwrap();
        reopened
            .complete_retirement(SignOut, |_| panic!("stale cleanup reached a new account"))
            .unwrap();
        assert!(storage.load().unwrap().is_some());
    }

    #[test]
    fn late_token_rotation_cannot_recreate_or_replace_a_retired_grant() {
        let (_fixture, storage) = fixture();
        let other = Storage::at(storage.root.clone()).unwrap();
        let previous = grant();
        storage.publish(&previous).unwrap();
        let mut rotated = previous.clone();
        rotated.access_token = "rotated".into();
        other.clear().unwrap();
        assert!(matches!(
            storage.write_grant(&rotated, Some(&previous)),
            Err(Failure::Retired)
        ));
        let mut replacement = grant();
        replacement.refresh_token = "new-login".into();
        other.publish(&replacement).unwrap();
        assert!(matches!(
            storage.write_grant(&rotated, Some(&previous)),
            Err(Failure::Retired)
        ));
        assert_eq!(other.load().unwrap().unwrap().refresh_token, "new-login");
        // The account that still owns the on-disk grant can persist and replay its rotation.
        storage.write_grant(&rotated, Some(&replacement)).unwrap();
        storage.write_grant(&rotated, Some(&replacement)).unwrap();
    }

    #[tokio::test]
    async fn rotated_refresh_token_survives_save_failure_without_another_exchange() {
        let (_fixture, storage) = fixture();
        let original = grant();
        storage.publish(&original).unwrap();
        let session = Session::new(
            Client::builder().no_proxy().build().unwrap(),
            Arc::clone(&storage),
            "fixture".into(),
            original,
        );
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let endpoint = format!("http://{}/token", listener.local_addr().unwrap());
        let exchange = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            drop(listener); // Any replay reaches a closed loopback endpoint.
            let mut request = [0; 2048];
            let size = socket.read(&mut request).await.unwrap();
            assert!(request[..size].starts_with(b"POST /token "));
            let body = r#"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            socket.write_all(response.as_bytes()).await.unwrap();
        });
        let staging = storage.session.join(".session.pending");
        std::fs::create_dir(&staging).unwrap();
        // Removing a directory without AT_REMOVEDIR gives EISDIR on Linux and
        // EPERM on macOS. Either storage failure must preserve the new token pair.
        assert!(matches!(
            session.access_from(&endpoint, None).await,
            Err(Failure::Storage | Failure::StorageDenied)
        ));
        exchange.await.unwrap();
        std::fs::remove_dir(&staging).unwrap();
        assert_eq!(
            storage.load().unwrap().unwrap().refresh_token,
            "old-refresh"
        );
        assert_eq!(
            session.access_from(&endpoint, None).await.unwrap().as_str(),
            "rotated-access"
        );
        let saved = storage.load().unwrap().unwrap();
        assert_eq!(saved.refresh_token, "rotated-refresh");
        assert_eq!(saved.username, "fixture");
        session.retire();
        assert!(matches!(
            session.access_from(&endpoint, None).await,
            Err(Failure::Retired)
        ));
    }

    #[test]
    fn callback_validates_state_before_accepting_code_or_denial() {
        assert!(callback(b"GET /login?error=access_denied HTTP/1.1\r\n\r\n", "valid").is_none());
        assert!(
            callback(
                b"GET /login?state=valid&state=duplicate&code=x HTTP/1.1\r\n\r\n",
                "valid"
            )
            .is_none()
        );
        assert_eq!(
            callback(
                b"GET /login?state=valid&code=abcd HTTP/1.1\r\n\r\n",
                "valid"
            )
            .unwrap()
            .unwrap(),
            "abcd"
        );
    }
}
