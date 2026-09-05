use crate::*;

// Helper function to convert URL to URI
pub(crate) fn url_to_uri(input: &str) -> String {
    // If already a URI, return as-is
    if input.starts_with("spotify:") {
        return input.to_string();
    }

    // If it's a URL, parse it
    if input.starts_with("http://") || input.starts_with("https://") {
        if let Some(marker_pos) = input.find("open.spotify.com/") {
            let after_marker = &input[marker_pos + "open.spotify.com/".len()..];
            let parts: Vec<&str> = after_marker.split('/').collect();

            // Filter out locale prefixes like "intl-de"
            let filtered: Vec<&str> = parts
                .iter()
                .filter(|p| !p.starts_with("intl-"))
                .copied()
                .collect();

            if filtered.len() >= 2 {
                let content_type = filtered[0];
                let mut id = filtered[1];

                // Remove query parameters
                if let Some(query_pos) = id.find('?') {
                    id = &id[..query_pos];
                }

                return format!("spotify:{}:{}", content_type, id);
            }
        }
    }

    // Return original if can't parse
    input.to_string()
}

// Helper function to parse Spotify URI from string
pub(crate) fn parse_spotify_uri(uri_str: &str) -> Result<SpotifyUri, String> {
    SpotifyUri::from_uri(uri_str).map_err(|e| format!("Invalid Spotify URI: {:?}", e))
}

/// Copies a C string argument into an owned `String`, or `None` if it is null or not UTF-8.
///
/// # Safety
/// `ptr` must be null or point to a valid NUL-terminated C string.
pub(crate) unsafe fn c_string_arg(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    c_str.to_str().ok().map(str::to_owned)
}

/// Copies a registered callback out of its slot, releasing the slot lock before returning.
///
/// No callback may run with its slot lock held: it re-enters Swift, which can call straight
/// back into Rust. Taking the pointer out here makes that structural instead of a
/// `drop(guard)` that every call site has to remember. The export panic barrier does not
/// make an invalid callback pointer safe, and it does not wrap these outbound calls.
pub(crate) fn registered_callback<F: Copy>(slot: &Mutex<Option<F>>) -> Option<F> {
    *slot.lock().unwrap_or_else(|e| e.into_inner())
}

/// Hands an owned string to Swift, which frees it with `spotty_playback_free_string`.
///
/// A string carrying an interior NUL cannot cross the boundary, and every caller already
/// treats null as "nothing to report", so that is what it becomes.
pub(crate) fn into_owned_c_string(value: String) -> *mut c_char {
    c_string_from_text(&value)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn c_string_from_text(text: &str) -> Option<CString> {
    match CString::new(text) {
        Ok(c_str) => Some(c_str),
        Err(e) => {
            debug!("C string contained interior NUL: {}", e);
            None
        }
    }
}

pub(crate) fn optional_callback_c_string(value: Option<&str>) -> Option<CString> {
    value
        .filter(|text| !text.is_empty())
        .and_then(c_string_from_text)
}

/// Connection observation delivered as a C struct. `device_id` and `last_error` are valid only
/// for the callback; Swift must copy them before returning. Null means missing; outbound empty
/// strings and strings containing an interior NUL are also delivered as null fields. Flags are
/// 0 or 1.
///
/// `credentials_rejected` is a typed, definitive streaming-credential rejection. It takes
/// precedence over generic reconnect errors; it does not revoke the independent Keymaster
/// grant.
///
/// `resume_pending` is set only inside a reconnect's rehydration window: the session is
/// connected and activated but `spirc_ready` is deliberately still 0, and Swift should issue
/// its resume-load targets through `spotty_playback_load` now. Readiness is published once a
/// Playing event lands, a load reports a dead Spirc, or the window times out.
#[repr(C)]
pub struct SpottyConnectionSnapshot {
    pub revision: u64,
    pub session_generation: u64,
    pub session_connected: u8,
    pub spirc_ready: u8,
    pub is_active_device: u8,
    pub resume_pending: u8,
    pub credentials_rejected: u8,
    pub device_id: SpottyNullableCString,
    pub last_error: SpottyNullableCString,
}

pub(crate) type SpottyNullableCString = *const c_char;

pub(crate) type SpottyNullableMutCString = *mut c_char;

pub(crate) type SpottyNullableCStringArray = *const *const c_char;

pub(crate) type SpottyNullableFloatSamples = *const f32;

pub(crate) type SpottyNullableStringPairPointer = *const SpottyStringPair;

pub(crate) type SpottyNullableRestrictionPointer = *const SpottyRestriction;

pub(crate) type SpottyNullableQueueTrackPointer = *const SpottyProtocolQueueTrack;

pub(crate) type SpottyNullableDevicePointer = *const SpottyProtocolDevice;

pub(crate) type SpottyNullableQueueSnapshot = *mut SpottyQueueSnapshot;

pub(crate) type SpottyPlaybackResult = i32;

pub(crate) type SpottyPlaybackAudioControlEvent = u8;

/// Callback function type for connection state change notifications. Receives a typed snapshot;
/// the snapshot pointer and its string pointers are valid only for the callback invocation.
pub(crate) type ConnectionSnapshotCallback = extern "C" fn(*const SpottyConnectionSnapshot);

/// Callback function type for receiving raw PCM audio data. Audio format is 44.1 kHz, stereo,
/// Float32, interleaved; the samples pointer is valid only for the callback invocation.
/// Called from a background decoder thread, so the callback must be thread-safe.
///
/// # Parameters
/// - `samples`: Nullable pointer to interleaved f32 samples.
/// - `sample_count`: Number of f32 values (frames * 2 for stereo).
pub(crate) type AudioDataCallback = extern "C" fn(SpottyNullableFloatSamples, usize);

/// Callback function type for audio control events (start/stop/clear). Called from a background
/// decoder thread, so the callback must be thread-safe.
pub(crate) type AudioControlCallback = extern "C" fn(SpottyPlaybackAudioControlEvent);

pub(crate) fn send_connection_snapshot(
    callback: ConnectionSnapshotCallback,
    stamp: SnapshotStamp,
    state: &ConnectionState,
) {
    let device_id = optional_callback_c_string(state.device_id.as_deref());
    let last_error = optional_callback_c_string(state.last_error.as_deref());
    let snapshot = SpottyConnectionSnapshot {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        session_connected: u8::from(state.session_connected),
        spirc_ready: u8::from(state.spirc_ready),
        is_active_device: u8::from(state.is_active_device),
        resume_pending: u8::from(state.resume_pending),
        credentials_rejected: u8::from(state.credentials_rejected),
        device_id: device_id
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null()),
        last_error: last_error
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null()),
    };
    callback(&snapshot);
}

/// Protocol playing/paused flags, track identity, timing, and options. Transport presentation
/// is Swift-owned. Not a JSON DTO.
pub(crate) struct PlaybackObservation {
    pub is_playing: bool,
    pub is_paused: bool,
    /// True only for the one local snapshot that reports the current requested track's
    /// unavailable event. Protocol snapshots and ordinary local transport updates keep this
    /// false; Swift owns the presentation of the actionable notice.
    pub track_unavailable: bool,
    pub track_uri: String,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub shuffle: bool,
    pub repeat_track: bool,
    pub repeat_context: bool,
    pub is_active_device: bool,
    pub timestamp_ms: i64,
}

/// Playback observation. `track_uri` is valid only for the callback;
/// Swift must copy it before returning. Null means missing; outbound empty strings and
/// strings containing an interior NUL are also delivered as null fields. Flags are 0 or 1.
///
/// `is_active_device` is the protocol active-member fact captured with this observation;
/// it is independent of the arrival order of the connection callback.
///
/// `track_unavailable` is set only on the local callback corresponding to a current requested
/// track whose load failed. It is never set on protocol snapshots, preload failures, stale
/// request events, or snapshots from an inactive device.
#[repr(C)]
pub struct SpottyPlaybackSnapshot {
    pub revision: u64,
    pub session_generation: u64,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub timestamp_ms: i64,
    pub is_playing: u8,
    pub is_paused: u8,
    pub track_unavailable: u8,
    pub shuffle: u8,
    pub repeat_track: u8,
    pub repeat_context: u8,
    pub is_active_device: u8,
    pub track_uri: SpottyNullableCString,
}

/// Callback function type for playback state updates. Receives a typed snapshot; string
/// pointers are valid only for the callback invocation.
pub(crate) type PlaybackSnapshotCallback = extern "C" fn(*const SpottyPlaybackSnapshot);

pub(crate) fn send_playback_snapshot(
    callback: PlaybackSnapshotCallback,
    stamp: SnapshotStamp,
    observation: &PlaybackObservation,
) {
    let track_uri = optional_callback_c_string(Some(observation.track_uri.as_str()));
    let snapshot = SpottyPlaybackSnapshot {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        position_ms: observation.position_ms,
        duration_ms: observation.duration_ms,
        timestamp_ms: observation.timestamp_ms,
        is_playing: u8::from(observation.is_playing),
        is_paused: u8::from(observation.is_paused),
        track_unavailable: u8::from(observation.track_unavailable),
        shuffle: u8::from(observation.shuffle),
        repeat_track: u8::from(observation.repeat_track),
        repeat_context: u8::from(observation.repeat_context),
        is_active_device: u8::from(observation.is_active_device),
        track_uri: track_uri
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null()),
    };
    callback(&snapshot);
}

/// One Connect cluster member. String pointers are valid only for the callback. Null means
/// missing; outbound empty strings and strings containing an interior NUL are also delivered
/// as null fields.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct SpottyProtocolDevice {
    pub id: SpottyNullableCString,
    pub name: SpottyNullableCString,
    pub device_type: SpottyNullableCString,
}

/// Device-list observation. `active_device_id` and `devices` are valid only for the callback.
/// Swift must copy them before returning. A null `devices` pointer with count 0 is an empty list.
#[repr(C)]
pub struct SpottyDevicesSnapshot {
    pub revision: u64,
    pub session_generation: u64,
    pub active_device_id: SpottyNullableCString,
    pub devices: SpottyNullableDevicePointer,
    pub device_count: usize,
}

/// Callback function type for Connect device-list updates. String pointers and the device
/// array are valid only for the callback invocation.
pub(crate) type DevicesSnapshotCallback = extern "C" fn(*const SpottyDevicesSnapshot);

pub(crate) fn send_devices_snapshot(
    callback: DevicesSnapshotCallback,
    stamp: SnapshotStamp,
    active_device_id: &str,
    devices: &[ProtocolConnectDevice],
) {
    let active = optional_callback_c_string(Some(active_device_id));
    let row_strings: Vec<(Option<CString>, Option<CString>, Option<CString>)> = devices
        .iter()
        .map(|device| {
            (
                optional_callback_c_string(Some(device.id.as_str())),
                optional_callback_c_string(Some(device.name.as_str())),
                optional_callback_c_string(Some(device.device_type.as_str())),
            )
        })
        .collect();
    let rows: Vec<SpottyProtocolDevice> = row_strings
        .iter()
        .map(|(id, name, device_type)| SpottyProtocolDevice {
            id: id
                .as_ref()
                .map(|value| value.as_ptr())
                .unwrap_or(std::ptr::null()),
            name: name
                .as_ref()
                .map(|value| value.as_ptr())
                .unwrap_or(std::ptr::null()),
            device_type: device_type
                .as_ref()
                .map(|value| value.as_ptr())
                .unwrap_or(std::ptr::null()),
        })
        .collect();
    let snapshot = SpottyDevicesSnapshot {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        active_device_id: active
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null()),
        devices: if rows.is_empty() {
            std::ptr::null()
        } else {
            rows.as_ptr()
        },
        device_count: rows.len(),
    };
    callback(&snapshot);
}

/// The current Spirc, or `None` after logging that there is none.
///
/// Handed out as a clone rather than behind the guard: several callers go on to publish a
/// connection snapshot, which re-enters Swift, and Swift may call straight back into Rust.
/// No FFI entry point may hold the `SPIRC` lock across that.
pub(crate) fn current_spirc(what: &str) -> Option<Arc<Spirc>> {
    let spirc = SPIRC.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if spirc.is_none() {
        debug!("{} error: Spirc not initialized", what);
    }
    spirc
}

/// Logs a failed Spirc command against `what` and maps it to its FFI error code.
///
/// A closed command channel is reported separately (`ERROR_NEEDS_REINIT`) because Swift
/// responds to it by rebuilding the player rather than by surfacing a failure. The recovery
/// code comes from [`classify_spirc_command_error`]. The log contains only the stable
/// classification; the upstream error can carry private response details and must not cross
/// this boundary through `Debug` formatting.
pub(crate) fn spirc_error(what: &str, err: &librespot_core::Error) -> i32 {
    let category = match classify_spirc_command_failure(err) {
        SpircCommandFailure::CredentialRejected => "credential_rejected",
        SpircCommandFailure::NeedsReinit => "needs_reinit",
        SpircCommandFailure::Ordinary => "ordinary",
    };
    debug!("{} error: {}", what, category);
    classify_spirc_command_error(err)
}

/// Runs a command against the current Spirc and maps the outcome to an FFI error code.
pub(crate) fn spirc_command(
    what: &str,
    command: impl FnOnce(&Spirc) -> Result<(), librespot_core::Error>,
) -> i32 {
    let Some(spirc) = current_spirc(what) else {
        return ERROR_GENERAL;
    };

    match command(&spirc) {
        Ok(()) => 0,
        Err(e) => spirc_error(what, &e),
    }
}

/// Defined fallback when an FFI export panics: command `i32`s become [`ERROR_GENERAL`].
pub(crate) fn ffi_command(export: &'static str, work: impl FnOnce() -> i32) -> i32 {
    ffi_catch(export, ERROR_GENERAL, work)
}

/// Defined fallback when an FFI flag query panics: conservative `0` / false.
#[cfg(test)]
pub(crate) fn ffi_query_i32(export: &'static str, work: impl FnOnce() -> i32) -> i32 {
    ffi_catch(export, 0, work)
}

/// Defined fallback when an FFI `u32` query panics: conservative `0`.
pub(crate) fn ffi_query_u32(export: &'static str, work: impl FnOnce() -> u32) -> u32 {
    ffi_catch(export, 0, work)
}

/// Defined fallback when an FFI `u8` query panics: conservative `0`.
#[cfg(test)]
pub(crate) fn ffi_query_u8(export: &'static str, work: impl FnOnce() -> u8) -> u8 {
    ffi_catch(export, 0, work)
}

/// Defined fallback when an FFI `bool` query panics: conservative `false`.
#[cfg(test)]
pub(crate) fn ffi_query_bool(export: &'static str, work: impl FnOnce() -> bool) -> bool {
    ffi_catch(export, false, work)
}

/// Defined fallback when an owned-string export panics: a null pointer.
pub(crate) fn ffi_owned_string(
    export: &'static str,
    work: impl FnOnce() -> *mut c_char,
) -> *mut c_char {
    ffi_catch(export, std::ptr::null_mut(), work)
}

/// Defined fallback when an owned-pointer export panics: a null pointer.
pub(crate) fn ffi_owned_ptr<T>(export: &'static str, work: impl FnOnce() -> *mut T) -> *mut T {
    ffi_catch(export, std::ptr::null_mut(), work)
}

/// Defined fallback when a void export panics: a no-op completion.
pub(crate) fn ffi_void(export: &'static str, work: impl FnOnce()) {
    ffi_catch(export, (), work)
}

/// Contains a panic originating in `work` so it cannot unwind across the C ABI.
///
/// `AssertUnwindSafe` is used because FFI bodies capture raw pointers and process-wide
/// locks, which are not `UnwindSafe`. That wrapper does not make invalid foreign pointers
/// defined; it only stops a Rust panic from crossing into Swift. After a panic, existing
/// poisoned-lock recovery (`into_inner`) remains the recovery path. The process panic hook
/// is left untouched, and the panic payload is not copied into logs.
fn ffi_catch<T>(export: &'static str, fallback: T, work: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(work)) {
        Ok(value) => value,
        Err(_) => {
            log::error!("FFI export {export} panicked; returning defined fallback");
            fallback
        }
    }
}

/// Frees a C string allocated by this library. Tolerates a null pointer, including the result
/// of an export that returned null on error.
#[no_mangle]
pub extern "C" fn spotty_playback_free_string(s: SpottyNullableMutCString) {
    ffi_void("spotty_playback_free_string", || {
        if !s.is_null() {
            unsafe {
                let _ = CString::from_raw(s);
            }
        }
    })
}

/// Registers a callback to receive queue updates as a C snapshot.
/// String and nested pointers are valid only for the call.
#[no_mangle]
pub extern "C" fn spotty_playback_register_queue_callback(callback: QueueSnapshotCallback) {
    ffi_void("spotty_playback_register_queue_callback", || {
        *CONTROL_CALLBACKS
            .queue
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive playback state updates as a C snapshot.
/// String pointers are valid only for the call.
#[no_mangle]
pub extern "C" fn spotty_playback_register_playback_state_callback(
    callback: PlaybackSnapshotCallback,
) {
    ffi_void("spotty_playback_register_playback_state_callback", || {
        *CONTROL_CALLBACKS
            .playback_state
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive the Connect device list from cluster updates.
/// The callback receives a C snapshot; string pointers are valid only for the call.
/// Fires only when the list actually changes, not on every cluster tick.
#[no_mangle]
pub extern "C" fn spotty_playback_register_devices_callback(callback: DevicesSnapshotCallback) {
    ffi_void("spotty_playback_register_devices_callback", || {
        *CONTROL_CALLBACKS
            .devices
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive connection state change notifications.
/// Called whenever the connection state changes (connect, disconnect, error, etc.).
/// The callback receives a C snapshot; string pointers are valid only for the call.
#[no_mangle]
pub extern "C" fn spotty_playback_register_connection_state_callback(
    callback: ConnectionSnapshotCallback,
) {
    ffi_void("spotty_playback_register_connection_state_callback", || {
        *CONTROL_CALLBACKS
            .connection_state
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive raw PCM audio data (f32, 44100Hz, stereo interleaved).
/// Called from librespot's player thread for each decoded audio chunk. The samples pointer is
/// valid only for the callback invocation, and the callback must be thread-safe.
#[no_mangle]
pub extern "C" fn spotty_playback_register_audio_data_callback(callback: AudioDataCallback) {
    ffi_void("spotty_playback_register_audio_data_callback", || {
        proxy_sink::register_audio_data_callback(callback);
    })
}

/// Registers a callback for audio control events (start/stop/clear). Called from librespot's
/// player thread. Events are 0 = stop, 1 = start/resume, and 2 = clear/flush.
#[no_mangle]
pub extern "C" fn spotty_playback_register_audio_control_callback(callback: AudioControlCallback) {
    ffi_void("spotty_playback_register_audio_control_callback", || {
        proxy_sink::register_audio_control_callback(callback);
    })
}
