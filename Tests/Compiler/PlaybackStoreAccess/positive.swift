import Foundation
import SpottyDomain
@testable import SpottyCore

// This function is intentionally never called. Type-checking it against the built testable
// module proves that boundary clients can observe the reducer snapshot and its presentation
// projections without depending on source spelling or linking the playback archive.
@MainActor
func readPlaybackStoreAccess(_ store: PlaybackStore) {
    _ = store.currentTrackIndicator
    _ = store.catalogPlaybackAvailability
    _ = store.state
    _ = store.requiresReauthentication
    _ = store.accountEpoch
    _ = store.engineGeneration
    _ = store.phase
    _ = store.trackURI
    _ = store.trackTitle
    _ = store.artistName
    _ = store.artworkURL
    _ = store.isPlaying
    _ = store.isShuffleEnabled
    _ = store.repeatMode
    _ = store.isActiveDevice
    _ = store.position
    _ = store.duration
    _ = store.positionAnchorDate
    _ = store.queueNextEntries
    _ = store.connectDevices
    _ = store.localDeviceID
    _ = store.isPlaybackCommandPending
    _ = store.hasCurrentTrackMetadata
    _ = store.transientCommandError
    _ = store.isConnected
    _ = store.catalogCurrentTrack
    _ = store.displayedTrackTitle
    _ = store.displayedArtistName
    _ = store.displayedArtworkURL
    _ = store.hasCurrentTrack
    _ = store.showsPauseControl
    _ = store.canStartPlayback
    _ = store.canTogglePlayback
    _ = store.canSkipTrack
    _ = store.statusText
    _ = store.activeRemoteDevice
    _ = store.remotePlaybackBanner
    _ = store.commandRoute
    _ = store.displayedPosition(at: Date())
}
