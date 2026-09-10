#ifndef SPOTTY_PLAYBACK_ANNOTATIONS_H
#define SPOTTY_PLAYBACK_ANNOTATIONS_H

#include <stddef.h>
#include <stdint.h>

/*
 * cbindgen emits the ABI declarations that use these names. The aliases keep
 * the generated Rust raw-pointer layout while retaining the public nullability
 * contract of the handwritten header.
 */
typedef const char *_Nullable SpottyNullableCString;
typedef char *_Nullable SpottyNullableMutCString;
typedef const char *_Nullable const *_Nullable SpottyNullableCStringArray;
typedef const float *_Nullable SpottyNullableFloatSamples;

typedef const struct SpottyStringPair *_Nullable SpottyNullableStringPairPointer;
typedef const struct SpottyRestriction *_Nullable SpottyNullableRestrictionPointer;
typedef const struct SpottyProtocolQueueTrack *_Nullable SpottyNullableQueueTrackPointer;
typedef const struct SpottyProtocolDevice *_Nullable SpottyNullableDevicePointer;
typedef struct SpottyQueueSnapshot *_Nullable SpottyNullableQueueSnapshot;
typedef const struct SpottyConnectionSnapshot *_Nullable SpottyNullableConnectionSnapshotPointer;
typedef const struct SpottyPlaybackSnapshot *_Nullable SpottyNullablePlaybackSnapshotPointer;
typedef const struct SpottyQueueSnapshot *_Nullable SpottyNullableQueueSnapshotPointer;

/* ========================================================================== */
/* Error codes                                                               */
/* ========================================================================== */
/*
 * Command functions return a SpottyPlaybackResult:
 *   SpottyPlaybackResultOk                   ( 0) = success
 *   SpottyPlaybackResultError                (-1) = general error
 *   SpottyPlaybackResultSessionDisconnected  (-2) = session disconnected, needs reinitialization
 *                                             (call spotty_playback_init_player with NULL)
 *   SpottyPlaybackResultSessionNotConnected  (-3) = session not connected (command rejected,
 *                                             wait for session to connect)
 *   SpottyPlaybackResultCredentialsRejected  (-4) = cached streaming credentials rejected during
 *                                             initialization; authorize streaming again
 *
 * On SpottyPlaybackResultSessionDisconnected, the Spirc channel has closed (e.g., due
 * to idle timeout). Call spotty_playback_init_player() with NULL so it reconnects from the
 * credentials cached by spotty_playback_authorize_streaming().
 *
 * On SpottyPlaybackResultSessionNotConnected, the session is not yet connected. Wait
 * for the connection-state callback before retrying the command.
 *
 * SpottyPlaybackResultCredentialsRejected is returned only by initialization after Spotify
 * definitively rejects the cached streaming credentials. It is terminal for those credentials:
 * retain the separate Web API grant, ask the account owner for explicit authorization, and do not
 * retry initialization automatically with the same cache.
 */
typedef enum __attribute__((enum_extensibility(open))) SpottyPlaybackResult : int32_t {
    SpottyPlaybackResultOk = 0,
    SpottyPlaybackResultError = -1,
    SpottyPlaybackResultSessionDisconnected = -2,
    SpottyPlaybackResultSessionNotConnected = -3,
    SpottyPlaybackResultCredentialsRejected = -4,
} SpottyPlaybackResult;

/* Audio playback control event, delivered to AudioControlCallback. */
typedef enum __attribute__((enum_extensibility(open))) SpottyPlaybackAudioControlEvent : uint8_t {
    SpottyPlaybackAudioControlEventStop = 0,
    SpottyPlaybackAudioControlEventStart = 1,
    SpottyPlaybackAudioControlEventClear = 2,
} SpottyPlaybackAudioControlEvent;

#endif /* SPOTTY_PLAYBACK_ANNOTATIONS_H */
