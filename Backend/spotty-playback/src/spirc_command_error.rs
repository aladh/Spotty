use crate::{ERROR_CREDENTIALS_REJECTED, ERROR_GENERAL, ERROR_NEEDS_REINIT};
use librespot_core::error::ErrorKind;
use std::fmt;

/// The stable outcomes used by the retained engine's initialization transaction.
///
/// The upstream error is intentionally not retained. The connection snapshot and reconnect
/// owner only need to distinguish a credential that Spotify proved unusable from an outage that
/// remains eligible for backoff and retry.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum InitializationFailure {
    CredentialsRejected,
    Transient,
}

impl InitializationFailure {
    pub(crate) const fn message(self) -> &'static str {
        match self {
            Self::CredentialsRejected => "Spotify credentials rejected",
            Self::Transient => "Player initialization failed",
        }
    }
}

impl fmt::Display for InitializationFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.message())
    }
}

/// The small set of outcomes the retained engine exposes for a failed Spirc operation.
///
/// `CredentialRejected` is deliberately narrower than `PermissionDenied`: librespot uses the
/// latter for several AP login failures, and only the two server codes below prove that the
/// cached credential itself is unusable. The other outcomes retain the existing command result
/// contract.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SpircCommandFailure {
    Ordinary,
    NeedsReinit,
    CredentialRejected,
}

/// Identifies the terminal authentication outcome exposed by the pinned librespot boundary.
///
/// `librespot_core::connection::AuthenticationError` is private in the pinned revision. Its AP
/// login failures are converted into the public `PermissionDenied` kind before `Session::connect`
/// returns, so the exact server code is not available to this crate without a dependency patch.
/// The pinned error's inner `Display` is a stable, finite category for the two server codes we
/// can act on. Compare the complete string only at this classifier boundary; never log or expose
/// it. Other `PermissionDenied` values, including premium/account policy failures, remain
/// ordinary and do not clear the credential cache.
pub(crate) fn is_definitive_credential_rejection(err: &librespot_core::Error) -> bool {
    err.kind == ErrorKind::PermissionDenied
        && matches!(
            err.error.to_string().as_str(),
            "Login failed with reason: Bad credentials"
                | "Login failed with reason: Could not validate credentials"
        )
}

/// Converts an upstream Spirc construction error into the small safe lifecycle vocabulary.
pub(crate) fn classify_initialization_error(err: &librespot_core::Error) -> InitializationFailure {
    if is_definitive_credential_rejection(err) {
        InitializationFailure::CredentialsRejected
    } else {
        InitializationFailure::Transient
    }
}

/// Converts a failed initialization transaction to the stable C/Swift result code.
///
/// Credential rejection has its own terminal code so the account owner can retain the Web API
/// grant while stopping automatic retries of the unusable streaming credentials. A transient
/// constructor or transport failure remains the ordinary error; a closed Spirc command channel
/// is the separate `ERROR_NEEDS_REINIT` result used only by command calls.
pub(crate) const fn initialization_failure_code(failure: InitializationFailure) -> i32 {
    match failure {
        InitializationFailure::CredentialsRejected => ERROR_CREDENTIALS_REJECTED,
        InitializationFailure::Transient => ERROR_GENERAL,
    }
}

pub(crate) fn classify_spirc_command_failure(err: &librespot_core::Error) -> SpircCommandFailure {
    if is_definitive_credential_rejection(err) {
        SpircCommandFailure::CredentialRejected
    } else if err.kind == ErrorKind::Internal {
        SpircCommandFailure::NeedsReinit
    } else {
        SpircCommandFailure::Ordinary
    }
}

/// Maps a failed public Spirc command to the FFI recovery code.
///
/// Pinned librespot (`939dc5ee9d833e1980f9495241219d9d4868a061`) exposes
/// `librespot_core::Error.kind`. Every `Spirc` handle used by [`crate::spirc_error`]
/// either only sends on the unbounded command `mpsc` (`play`, `pause`, `next`,
/// `prev`, `shuffle`, `repeat`, `repeat_track`, `set_position_ms`, `load`,
/// `shutdown`, `transfer`) or, for `add_to_queue`, may also return
/// `ErrorKind::InvalidArgument` when the URI kind is not track, episode, album, or
/// playlist. `handle_command` runs on the task after a successful send and never
/// returns to these handles.
///
/// A dropped command receiver becomes `tokio::sync::mpsc::error::SendError`, which
/// that revision converts with `From<SendError<T>>` to `ErrorKind::Internal` and a
/// private `ErrorMessage` of `SendError::to_string()`. The `SendError` type is
/// erased, so `Internal` is the inspectable closed-channel signal at this boundary.
/// Other kinds, including that `add_to_queue` `InvalidArgument`, stay
/// [`ERROR_GENERAL`]. Classification uses `kind` only; `Debug` text is not consulted.
pub(crate) fn classify_spirc_command_error(err: &librespot_core::Error) -> i32 {
    match classify_spirc_command_failure(err) {
        SpircCommandFailure::NeedsReinit => ERROR_NEEDS_REINIT,
        // Commands can only observe a Spirc send result. They do not carry the captured
        // initialization generation needed to publish a credential rejection safely, so keep
        // this defensive variant ordinary until an initialization transaction handles it.
        SpircCommandFailure::CredentialRejected => ERROR_GENERAL,
        SpircCommandFailure::Ordinary => ERROR_GENERAL,
    }
}
