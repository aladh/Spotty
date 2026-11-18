use crate::playback::*;
/// Why the streaming credential cache cannot be opened.
///
/// Variants carry no filesystem path so public logs stay sanitized.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CredentialsCacheError {
    /// `HOME` is unset or empty.
    Missing,
    /// `HOME` is not an absolute location, so it cannot be an app container path.
    Relative,
    /// `HOME` is a shared temporary root such as `/tmp` or `/private/tmp`.
    SharedTemporary,
}

impl CredentialsCacheError {
    pub(crate) fn message(self) -> &'static str {
        "Streaming credential cache is unavailable"
    }
}

/// Resolves the cache directory from an injected `HOME`.
///
/// Path selection is pure: callers pass a value rather than mutating the process
/// environment, so checks do not touch the developer's real home or race on `HOME`.
pub(crate) fn credentials_cache_dir_from_home(
    home: Option<&std::path::Path>,
) -> Result<std::path::PathBuf, CredentialsCacheError> {
    credentials_cache_dir_from_home_named(home, "Spotty")
}

fn credentials_cache_dir_from_home_named(
    home: Option<&std::path::Path>,
    product_directory_name: &str,
) -> Result<std::path::PathBuf, CredentialsCacheError> {
    let home = home
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or(CredentialsCacheError::Missing)?;
    if !home.is_absolute() {
        return Err(CredentialsCacheError::Relative);
    }
    let home = lexically_normalized_absolute(home).ok_or(CredentialsCacheError::SharedTemporary)?;
    if is_shared_temporary_home(&home) {
        return Err(CredentialsCacheError::SharedTemporary);
    }
    Ok(home
        .join("Library")
        .join("Application Support")
        .join(product_directory_name)
        .join("credentials"))
}

fn retired_credentials_cache_dir() -> Result<std::path::PathBuf, CredentialsCacheError> {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    credentials_cache_dir_from_home_named(home.as_deref(), "Aural")
}

/// Collapse `.` and refuse `..` without touching the filesystem or following symlinks.
fn lexically_normalized_absolute(home: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut normalized = std::path::PathBuf::new();
    for component in home.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => return None,
            other => normalized.push(other),
        }
    }
    Some(normalized)
}

/// Shared world-writable temp roots, including the macOS `/tmp` → `/private/tmp` pair.
/// Comparison is lexical so path selection stays pure and does not follow symlinks.
fn is_shared_temporary_home(home: &std::path::Path) -> bool {
    const ROOTS: &[&str] = &["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"];
    ROOTS.iter().any(|root| {
        let root = std::path::Path::new(root);
        home == root || home.starts_with(root)
    })
}

/// Where librespot persists the AP credentials produced by the streaming grant.
///
/// Under the sandbox `HOME` is already the app container, so this stays inside it.
/// Missing, relative, or shared-temporary `HOME` fails closed: it must not fall back to `/tmp`.
pub(crate) fn credentials_cache_dir() -> Result<std::path::PathBuf, CredentialsCacheError> {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    credentials_cache_dir_from_home(home.as_deref())
}

/// Creates `dir` and restricts it to the current user when the platform allows.
pub(crate) fn ensure_private_credentials_dir(dir: &std::path::Path) -> Result<(), String> {
    std::fs::create_dir_all(dir)
        .map_err(|_| CredentialsCacheError::Missing.message().to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| CredentialsCacheError::Missing.message().to_string())?;
    }
    Ok(())
}

/// Resolves the live cache directory and removes it. Unavailable locations are success:
/// there is no app-owned cache to clear.
pub(crate) fn clear_resolved_credentials() {
    let _ = try_clear_resolved_credentials();
}

/// Both locations are attempted even when one removal fails. A native client can keep
/// a failed retirement fenced and allow the user to retry it.
pub(crate) fn try_clear_resolved_credentials() -> std::io::Result<()> {
    let path_error = |error: CredentialsCacheError| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, error.message())
    };
    let active = credentials_cache_dir()
        .map_err(path_error)
        .and_then(|dir| try_clear_credentials_at(&dir));
    let retired = retired_credentials_cache_dir()
        .map_err(path_error)
        .and_then(|dir| {
            let cleared = try_clear_credentials_at(&dir);
            if cleared.is_ok() {
                if let Some(parent) = dir.parent() {
                    let _ = std::fs::remove_dir(parent);
                }
            }
            cleared
        });
    active.and(retired)
}

pub(crate) fn clear_retired_credentials_cache() {
    let Ok(dir) = retired_credentials_cache_dir() else {
        return;
    };
    clear_retired_credentials_at(&dir);
}

pub(crate) fn clear_retired_credentials_at(dir: &std::path::Path) {
    clear_credentials_at(dir);
    if let Some(parent) = dir.parent() {
        let _ = std::fs::remove_dir(parent);
    }
}

/// Removes cached credentials from `dir`, treating "not there" as success.
///
/// Takes the directory rather than reading `credentials_cache_dir()` so it can be tested
/// against a temporary one: `cargo test` runs unsandboxed, where that path resolves to the
/// developer's real credentials.
pub(crate) fn clear_credentials_at(dir: &std::path::Path) {
    let _ = try_clear_credentials_at(dir);
}

fn try_clear_credentials_at(dir: &std::path::Path) -> std::io::Result<()> {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => {
            debug!("Cleared streaming credentials");
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => {
            debug!(
                "Could not remove streaming credentials ({:?})",
                error.kind()
            );
            Err(error)
        }
    }
}
