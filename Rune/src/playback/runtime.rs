use crate::playback::*;
use std::future::Future;

// Global tokio runtime for async operations
pub(crate) static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

/// Returns `Err(CommandError::Failed)` if this thread already owns a Tokio runtime.
///
/// Centralizes the nested-`block_on` rule so commands can refuse before mutating
/// lifecycle flags, without each call site reading `Handle::try_current`.
pub(crate) fn refuse_if_nested_runtime() -> Result<(), CommandError> {
    if tokio::runtime::Handle::try_current().is_ok() {
        debug!("Refusing nested Runtime::block_on from a Tokio-owned thread");
        return Err(CommandError::Failed);
    }
    Ok(())
}

/// Blocks the caller on playback I/O. The app calls this from its playback command
/// thread so the UI and the session worker can continue handling events.
pub(crate) fn block_on_playback<T>(fut: impl Future<Output = T>) -> Result<T, CommandError> {
    refuse_if_nested_runtime()?;
    Ok(RUNTIME.block_on(fut))
}
