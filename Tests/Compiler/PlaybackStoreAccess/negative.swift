import Foundation
import SpottyDomain
@testable import SpottyCore

// Each probe enables one forbidden access. The reducer snapshot is absent from the facade,
// and its presentation projections have no writable surface for boundary clients.
@MainActor
func rejectPlaybackStoreWrite(_ store: PlaybackStore) {
    #if NEG_CURRENT_TRACK_INDICATOR
        store.currentTrackIndicator = store.currentTrackIndicator
    #elseif NEG_CATALOG_PLAYBACK_AVAILABILITY
        store.catalogPlaybackAvailability = store.catalogPlaybackAvailability
    #elseif NEG_STATE
        _ = store.state
    #elseif NEG_STATE_MEMBER
        store.state.transport = store.state.transport
    #elseif NEG_REQUIRES_REAUTHENTICATION
        store.requiresReauthentication = store.requiresReauthentication
    #elseif NEG_ACCOUNT_EPOCH
        store.accountEpoch = store.accountEpoch
    #elseif NEG_ENGINE_GENERATION
        store.engineGeneration = store.engineGeneration
    #elseif NEG_PHASE
        store.phase = store.phase
    #elseif NEG_TRACK_URI
        store.trackURI = store.trackURI
    #elseif NEG_TRACK_TITLE
        store.trackTitle = store.trackTitle
    #elseif NEG_ARTIST_NAME
        store.artistName = store.artistName
    #elseif NEG_ARTWORK_URL
        store.artworkURL = store.artworkURL
    #elseif NEG_IS_PLAYING
        store.isPlaying = store.isPlaying
    #elseif NEG_IS_SHUFFLE_ENABLED
        store.isShuffleEnabled = store.isShuffleEnabled
    #elseif NEG_REPEAT_MODE
        store.repeatMode = store.repeatMode
    #elseif NEG_IS_ACTIVE_DEVICE
        store.isActiveDevice = store.isActiveDevice
    #elseif NEG_POSITION
        store.position = store.position
    #elseif NEG_DURATION
        store.duration = store.duration
    #elseif NEG_POSITION_ANCHOR_DATE
        store.positionAnchorDate = store.positionAnchorDate
    #elseif NEG_QUEUE_NEXT_ENTRIES
        store.queueNextEntries = store.queueNextEntries
    #elseif NEG_CONNECT_DEVICES
        store.connectDevices = store.connectDevices
    #elseif NEG_LOCAL_DEVICE_ID
        store.localDeviceID = store.localDeviceID
    #elseif NEG_IS_PLAYBACK_COMMAND_PENDING
        store.isPlaybackCommandPending = store.isPlaybackCommandPending
    #elseif NEG_HAS_CURRENT_TRACK_METADATA
        store.hasCurrentTrackMetadata = store.hasCurrentTrackMetadata
    #elseif NEG_TRANSIENT_COMMAND_ERROR
        store.transientCommandError = store.transientCommandError
    #elseif NEG_IS_CONNECTED
        store.isConnected = store.isConnected
    #elseif NEG_CATALOG_CURRENT_TRACK
        store.catalogCurrentTrack = store.catalogCurrentTrack
    #elseif NEG_DISPLAYED_TRACK_TITLE
        store.displayedTrackTitle = store.displayedTrackTitle
    #elseif NEG_DISPLAYED_ARTIST_NAME
        store.displayedArtistName = store.displayedArtistName
    #elseif NEG_DISPLAYED_ARTWORK_URL
        store.displayedArtworkURL = store.displayedArtworkURL
    #elseif NEG_HAS_CURRENT_TRACK
        store.hasCurrentTrack = store.hasCurrentTrack
    #elseif NEG_SHOWS_PAUSE_CONTROL
        store.showsPauseControl = store.showsPauseControl
    #elseif NEG_CAN_START_PLAYBACK
        store.canStartPlayback = store.canStartPlayback
    #elseif NEG_CAN_TOGGLE_PLAYBACK
        store.canTogglePlayback = store.canTogglePlayback
    #elseif NEG_CAN_SKIP_TRACK
        store.canSkipTrack = store.canSkipTrack
    #elseif NEG_STATUS_TEXT
        store.statusText = store.statusText
    #elseif NEG_ACTIVE_REMOTE_DEVICE
        store.activeRemoteDevice = store.activeRemoteDevice
    #elseif NEG_REMOTE_PLAYBACK_BANNER
        store.remotePlaybackBanner = store.remotePlaybackBanner
    #elseif NEG_COMMAND_ROUTE
        store.commandRoute = store.commandRoute
    #endif
}
