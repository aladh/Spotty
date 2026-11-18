use super::*;
use librespot_core::error::ErrorKind;

#[test]
fn dropped_unbounded_command_receiver_maps_to_needs_reinit() {
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<()>();
    drop(rx);
    let send_error = tx
        .send(())
        .expect_err("send after dropping the receiver is the closed Spirc command channel");
    let err = librespot_core::Error::from(send_error);

    assert_eq!(err.kind, ErrorKind::Internal);
    // Exercise the same shared result wrapper used by load/play/activation call paths, rather
    // than only testing the classifier in isolation. A closed command receiver is the retained
    // engine's deterministic reinitialization signal.
    assert_eq!(
        spirc_error("closed-command-fixture", &err),
        CommandError::NeedsReinitialization
    );
    assert_eq!(
        classify_spirc_command_error(&err),
        CommandError::NeedsReinitialization
    );
}

#[test]
fn add_to_queue_invalid_argument_maps_to_general() {
    let err = librespot_core::Error::invalid_argument("uri");

    assert_eq!(err.kind, ErrorKind::InvalidArgument);
    assert_eq!(classify_spirc_command_error(&err), CommandError::Failed);
}

#[test]
fn initialization_errors_keep_credentials_rejection_terminal() {
    assert_eq!(
        initialization_error(InitializationFailure::CredentialsRejected),
        CommandError::CredentialsRejected
    );
    assert_eq!(
        initialization_error(InitializationFailure::Transient),
        CommandError::Failed
    );

    // A command-side PermissionDenied result has no captured initialization generation. Keep it
    // ordinary; only the initialization transaction may publish the terminal result safely.
    let err = librespot_core::Error::permission_denied(std::io::Error::other(
        "Login failed with reason: Bad credentials",
    ));
    assert_eq!(
        classify_spirc_command_failure(&err),
        SpircCommandFailure::CredentialRejected
    );
    assert_eq!(classify_spirc_command_error(&err), CommandError::Failed);
}

#[test]
fn classification_uses_kind_not_debug_text() {
    let internal_without_legacy_substring = librespot_core::Error::internal("synthetic");
    assert!(
        !format!("{internal_without_legacy_substring:?}").contains("channel closed"),
        "this Internal value must not satisfy the old Debug substring"
    );
    assert_eq!(
        classify_spirc_command_error(&internal_without_legacy_substring),
        CommandError::NeedsReinitialization
    );

    let invalid_argument_with_legacy_substring =
        librespot_core::Error::invalid_argument("channel closed");
    assert!(
        format!("{invalid_argument_with_legacy_substring:?}").contains("channel closed"),
        "this InvalidArgument value would have matched the old Debug substring"
    );
    assert_eq!(
        classify_spirc_command_error(&invalid_argument_with_legacy_substring),
        CommandError::Failed
    );
}
