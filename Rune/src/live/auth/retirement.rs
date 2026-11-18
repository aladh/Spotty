use super::*;
use crate::live::Retirement;
use std::ffi::{CStr, CString};

const DATABASE_FILES: [&[u8]; 4] = [
    b"catalog.sqlite",
    b"catalog.sqlite-wal",
    b"catalog.sqlite-shm",
    b"catalog.sqlite-journal",
];

impl Storage {
    pub(super) fn retirement_at(parent: &File) -> Result<Option<Retirement>> {
        match read_at(parent, OsStr::new("retirement"), 32)?
            .as_deref()
            .map(Vec::as_slice)
        {
            Some(b"signout") => Ok(Some(Retirement::SignOut)),
            Some(b"reauthenticate") => Ok(Some(Retirement::Reauthenticate)),
            None => Ok(None),
            Some(_) => Err(Failure::Storage),
        }
    }

    /// Commit the intent and fence the Swift-compatible grant before waiting for playback.
    pub(in crate::live) fn begin_retirement(&self, requested: Retirement) -> Result<Retirement> {
        let _guard = self.gate.lock().map_err(|_| Failure::Storage)?;
        let parent = self.lock_session()?;
        let previous = match Self::retirement_at(&parent) {
            Ok(previous) => previous,
            // An explicit sign-out supersedes every marker value. Atomic replacement
            // touches only this private entry, even if an interrupted upgrade damaged it.
            Err(Failure::Storage) if requested == Retirement::SignOut => None,
            Err(error) => return Err(error),
        };
        let intent = if previous == Some(Retirement::SignOut) {
            Retirement::SignOut
        } else {
            requested
        };
        if previous != Some(intent) {
            let value: &[u8] = match intent {
                Retirement::SignOut => b"signout",
                Retirement::Reauthenticate => b"reauthenticate",
            };
            write_at(
                &parent,
                OsStr::new("retirement"),
                OsStr::new(".retirement.pending"),
                value,
            )?;
        }
        // Fence legacy readers immediately when possible. Completion retries this
        // under the lock and keeps the marker if the grant cannot be retired.
        let _ = Self::retire_grant_at(&parent, intent);
        Ok(intent)
    }

    fn retire_grant_at(parent: &File, intent: Retirement) -> Result<()> {
        match intent {
            Retirement::SignOut => {
                unlink_file(parent, "session.json")?;
                parent.sync_all().map_err(io_failure)
            }
            Retirement::Reauthenticate => {
                if let Some(mut grant) = Self::read_grant(parent)?
                    && !grant.requires_reauthentication
                {
                    grant.requires_reauthentication = true;
                    Self::write_grant_at(parent, &grant)?;
                }
                Ok(())
            }
        }
    }

    /// A second process may resume the same interrupted retirement. Serialize cleanup
    /// separately so an explicit sign-out can still upgrade a running reauthentication.
    pub(in crate::live) fn complete_retirement(
        &self,
        expected: Retirement,
        mut cleanup: impl FnMut(Retirement) -> Result<()>,
    ) -> Result<Retirement> {
        let session_dir = private_dir(&self.session, false)?;
        let _owner = catalog_lock(&session_dir, "retirement.lock")?;
        let mut applied = expected;
        loop {
            let grant = {
                let parent = self.lock_session()?;
                let Some(intent) = Self::retirement_at(&parent)? else {
                    return Ok(applied);
                };
                applied = intent;
                Self::retire_grant_at(&parent, intent)
            };
            grant.and(cleanup(applied))?;
            let parent = self.lock_session()?;
            if Self::retirement_at(&parent)? == Some(applied) {
                unlink_file(&parent, "retirement")?;
                parent.sync_all().map_err(io_failure)?;
                return Ok(applied);
            }
            // Another instance upgraded reauthentication to sign-out during cleanup.
        }
    }

    /// Fence stale writers against the same durable retirement marker used for grants.
    pub(super) fn write_catalog(&self, grant: &[u8; 32], path: &Path, bytes: &[u8]) -> Result<()> {
        let session = lock_dir(&self.session)?;
        if Self::retirement_at(&session)?.is_some()
            || Self::read_grant(&session)?.is_none_or(|saved| {
                saved.requires_reauthentication || &saved.fingerprint() != grant
            })
        {
            return Err(Failure::Retired);
        }
        let directory = path.parent().ok_or(Failure::Storage)?;
        let root = directory.parent().ok_or(Failure::Storage)?;
        let _root_lock = catalog_lock(&private_dir(root, true)?, "catalog-ownership.lock")?;
        let name = path.file_name().ok_or(Failure::Storage)?;
        secure_dir(directory)?;
        let parent = lock_dir(directory)?;
        write_bounded(&parent, name, bytes, 128, 64 * 1024 * 1024)
    }

    /// End both the current Rune catalog and the catalog of an upgraded Swift installation.
    pub fn purge_account_data(&self, sign_out: bool) -> Result<()> {
        let root = private_dir(&self.root, false)?;
        let rune = purge_catalog(&root, "RuneCatalog", false);
        let legacy = purge_catalog(&root, "Catalog", true);
        #[cfg(target_os = "macos")]
        clear_preferences_and_cookies(sign_out);
        #[cfg(not(target_os = "macos"))]
        let _ = sign_out;
        rune.and(legacy)
    }
}

fn account_hash(name: &[u8]) -> bool {
    name.len() == 64
        && name
            .iter()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(c))
}

fn rune_cache_file(mut filename: &[u8]) -> bool {
    if let Some(staging) = filename
        .strip_prefix(b".")
        .and_then(|value| value.strip_suffix(b".pending"))
    {
        filename = staging;
        // Older Rune builds appended a 16-digit hexadecimal nonce before ".pending".
        if let Some(dot) = filename.iter().rposition(|byte| *byte == b'.') {
            let nonce = &filename[dot + 1..];
            if nonce.len() == 16 && nonce.iter().all(u8::is_ascii_hexdigit) {
                filename = &filename[..dot];
            }
        }
    }
    filename.strip_suffix(b".json").is_some_and(|name| {
        matches!(
            name,
            b"home" | b"library" | b"history" | b"likes" | b"last-remote-device"
        ) || account_hash(name)
    })
}

fn write_bounded(
    parent: &File,
    name: &OsStr,
    bytes: &[u8],
    limit: usize,
    budget: u64,
) -> Result<()> {
    use std::os::unix::ffi::OsStrExt;
    if bytes.len() as u64 > budget
        || !rune_cache_file(name.as_bytes())
        || name.as_bytes().starts_with(b".")
    {
        return Err(Failure::Storage);
    }
    let mut entries: Vec<(bool, i64, CString, u64)> = Vec::new();
    let mut count = 1;
    let mut total = bytes.len() as u64;
    for entry in unix::Dir::read_from(parent).map_err(io_failure)? {
        let entry = entry.map_err(io_failure)?;
        let filename = entry.file_name();
        if !rune_cache_file(filename.to_bytes()) || filename.to_bytes() == name.as_bytes() {
            continue;
        }
        if filename.to_bytes().starts_with(b".") {
            // Every current writer owns the directory flock. Any earlier stage is abandoned.
            remove_regular(parent, filename)?;
            continue;
        }
        let meta = unix::statat(parent, filename, AtFlags::SYMLINK_NOFOLLOW).map_err(io_failure)?;
        if unix::FileType::from_raw_mode(meta.st_mode) != unix::FileType::RegularFile {
            return Err(Failure::Storage);
        }
        let size = u64::try_from(meta.st_size).map_err(|_| Failure::Storage)?;
        count += 1;
        total = total.saturating_add(size);
        if !matches!(
            filename.to_bytes(),
            b"history.json" | b"last-remote-device.json"
        ) {
            let shared = matches!(
                filename.to_bytes(),
                b"library.json" | b"home.json" | b"likes.json"
            );
            entries.push((shared, meta.st_mtime as i64, filename.to_owned(), size));
        }
    }
    // Prefer complete shared surfaces and history. Among routes, reclaim the oldest first.
    entries.sort_unstable();
    let mut evictions = Vec::new();
    for (_, _, candidate, size) in entries {
        if count <= limit && total <= budget {
            break;
        }
        evictions.push(candidate);
        total -= size;
        count -= 1;
    }
    if count > limit || total > budget {
        return Err(Failure::Storage);
    }
    let mut stage = std::ffi::OsString::from(".");
    stage.push(name);
    stage.push(".pending");
    write_at(parent, name, &stage, bytes)?;
    if evictions.is_empty() {
        return Ok(());
    }
    for candidate in evictions {
        remove_regular(parent, &candidate)?;
    }
    parent.sync_all().map_err(io_failure)
}

fn catalog_lock(parent: &File, name: &str) -> Result<File> {
    let flags =
        OFlags::RDWR | OFlags::CREATE | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC;
    let lock =
        File::from(unix::openat(parent, name, flags, Mode::RUSR | Mode::WUSR).map_err(io_failure)?);
    let meta = lock.metadata().map_err(io_failure)?;
    if !meta.is_file() || meta.nlink() != 1 || meta.uid() != rustix::process::geteuid().as_raw() {
        return Err(Failure::Storage);
    }
    lock.set_permissions(Permissions::from_mode(0o600))
        .map_err(io_failure)?;
    lock.try_lock().map_err(|_| Failure::Storage)?;
    Ok(lock)
}

fn purge_catalog(storage: &File, name: &str, sqlite: bool) -> Result<()> {
    let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let root = match unix::openat(storage, name, flags, Mode::empty()) {
        Ok(fd) => File::from(fd),
        Err(Errno::NOENT) => return Ok(()),
        Err(error) => return Err(io_failure(error)),
    };
    // Both writers and retirement use the root lock before touching account paths.
    let _root_lock = catalog_lock(&root, "catalog-ownership.lock")?;
    let mut result = Ok(());
    for entry in unix::Dir::read_from(&root).map_err(io_failure)? {
        let entry = entry.map_err(io_failure)?;
        let name = entry.file_name();
        if account_hash(name.to_bytes()) {
            let purged = (|| {
                let account = File::from(
                    unix::openat(&root, name, flags, Mode::empty()).map_err(io_failure)?,
                );
                if account.metadata().map_err(io_failure)?.uid()
                    != rustix::process::geteuid().as_raw()
                {
                    return Err(Failure::Storage);
                }
                let _account_lock = if sqlite {
                    Some(catalog_lock(&account, "ownership.lock")?)
                } else {
                    account.try_lock().map_err(|_| Failure::Storage)?;
                    None
                };
                purge_files(&account, sqlite)
            })();
            result = result.and(purged);
        }
    }
    result
}

fn purge_files(account: &File, sqlite: bool) -> Result<()> {
    let mut result = Ok(());
    for entry in unix::Dir::read_from(account).map_err(io_failure)? {
        let entry = entry.map_err(io_failure)?;
        let name = entry.file_name();
        let owned = if sqlite {
            DATABASE_FILES.contains(&name.to_bytes())
        } else {
            rune_cache_file(name.to_bytes())
        };
        if owned {
            result = result.and(remove_regular(account, name));
        }
    }
    account.sync_all().map_err(io_failure)?;
    result
}

fn remove_regular(directory: &File, name: &CStr) -> Result<()> {
    let meta = unix::statat(directory, name, AtFlags::SYMLINK_NOFOLLOW).map_err(io_failure)?;
    if unix::FileType::from_raw_mode(meta.st_mode) != unix::FileType::RegularFile
        || meta.st_uid != rustix::process::geteuid().as_raw()
        || meta.st_nlink != 1
    {
        return Err(Failure::Storage);
    }
    unlink_file(directory, name).map(drop)
}

#[cfg(target_os = "macos")]
fn clear_preferences_and_cookies(sign_out: bool) {
    use objc2_foundation::{NSHTTPCookieStorage, NSString, NSUserDefaults};
    let preferences = NSUserDefaults::standardUserDefaults();
    for key in [
        "playback.fewer-repeats.history",
        "playback.last-remote-device-id",
    ] {
        preferences.removeObjectForKey(&NSString::from_str(key));
    }
    if sign_out {
        let storage = NSHTTPCookieStorage::sharedHTTPCookieStorage();
        if let Some(cookies) = storage.cookies() {
            for index in 0..cookies.count() {
                let cookie = cookies.objectAtIndex(index);
                let domain = cookie.domain().to_string();
                let host = domain.trim().trim_start_matches('.').to_ascii_lowercase();
                if cookie.path().to_string().starts_with('/')
                    && (host == "spotify.com" || host.ends_with(".spotify.com"))
                {
                    storage.deleteCookie(&cookie);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_eviction_counts_owned_records_and_bytes_and_preserves_history() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().canonicalize().unwrap();
        let parent = lock_dir(&path).unwrap();
        std::fs::write(path.join("keep.txt"), b"unrelated").unwrap();
        let a = format!("{}.json", "a".repeat(64));
        let b = format!("{}.json", "b".repeat(64));
        let put = |name: &str, data: &[u8]| write_bounded(&parent, OsStr::new(name), data, 3, 10);
        put("history.json", b"123").unwrap();
        put("library.json", b"45").unwrap();
        put(&a, b"67").unwrap();
        put(&b, b"89").unwrap(); // File count first.
        assert!(!path.join(a).exists());
        put("home.json", b"abcde").unwrap(); // Byte count also applies when replacing.
        assert!(!path.join(b).exists());
        assert!(put("home.json", b"12345678901").is_err());
        assert_eq!(std::fs::read(path.join("home.json")).unwrap(), b"abcde");
        assert_eq!(std::fs::read(path.join("history.json")).unwrap(), b"123");
        assert_eq!(std::fs::read(path.join("keep.txt")).unwrap(), b"unrelated");
    }

    #[test]
    fn failed_catalog_publication_keeps_existing_entries() {
        let fixture = tempfile::tempdir().unwrap();
        let path = fixture.path().canonicalize().unwrap();
        let parent = lock_dir(&path).unwrap();
        std::fs::write(path.join("library.json"), b"existing").unwrap();
        std::fs::create_dir(path.join("home.json")).unwrap();
        let result = write_bounded(&parent, OsStr::new("home.json"), b"new", 1, 12);
        assert!(result.is_err());
        assert_eq!(
            std::fs::read(path.join("library.json")).unwrap(),
            b"existing"
        );
    }

    #[test]
    fn purge_respects_main_database_locks_and_preserves_unrelated_files() {
        let fixture = tempfile::tempdir().unwrap();
        let parent = fixture.path().canonicalize().unwrap();
        let root = private_dir(&parent, false).unwrap();
        let account = "a".repeat(64);
        let catalog = parent.join("Catalog");
        let db = catalog.join(&account);
        let rune = parent.join("RuneCatalog").join(&account);
        for dir in [&db, &rune] {
            secure_dir(dir).unwrap();
            std::fs::write(dir.join("my-notes"), b"fixture").unwrap();
        }
        for name in DATABASE_FILES {
            std::fs::write(db.join(std::str::from_utf8(name).unwrap()), b"synthetic").unwrap();
        }
        for name in [
            "library.json",
            ".home.json.0123456789abcdef.pending",
            &format!("{account}.json"),
        ] {
            std::fs::write(rune.join(name), b"synthetic").unwrap();
        }
        let db_directory = File::open(&db).unwrap();
        let root_lock =
            catalog_lock(&File::open(&catalog).unwrap(), "catalog-ownership.lock").unwrap();
        assert!(purge_catalog(&root, "Catalog", true).is_err());
        drop(root_lock);
        let active = catalog_lock(&db_directory, "ownership.lock").unwrap();
        assert!(purge_catalog(&root, "Catalog", true).is_err());
        assert!(db.join("catalog.sqlite").exists());
        drop(active);
        let rune_lock = catalog_lock(
            &File::open(rune.parent().unwrap()).unwrap(),
            "catalog-ownership.lock",
        )
        .unwrap();
        assert!(purge_catalog(&root, "RuneCatalog", false).is_err());
        assert!(rune.join("library.json").exists());
        drop(rune_lock);
        std::os::unix::fs::symlink(db.join("my-notes"), db.join("catalog.sqlite-wal.fixture"))
            .unwrap();
        purge_catalog(&root, "Catalog", true).unwrap();
        purge_catalog(&root, "RuneCatalog", false).unwrap();
        assert!(db.join("ownership.lock").exists());
        assert!(db.join("my-notes").exists());
        assert!(db.join("catalog.sqlite-wal.fixture").exists());
        assert!(!db.join("catalog.sqlite").exists());
        assert!(!db.join("catalog.sqlite-wal").exists());
        assert_eq!(std::fs::read_dir(&rune).unwrap().count(), 1);
        assert!(rune.join("my-notes").exists());
    }
}
