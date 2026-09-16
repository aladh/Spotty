import Foundation
import SpottyDomain
@testable import SpottyCore

// This function is intentionally never called. Type-checking it against the built testable
// module proves that boundary clients can observe presentation projections without depending
// on source spelling or linking the playback archive.
@MainActor
func readPlaybackStoreAccess(_ store: PlaybackStore) {
    _ = store.currentTrackIndicator
    _ = store.catalogPlaybackAvailability
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
    _ = store.history
    _ = store.connectDevices
    _ = store.localDeviceID
    _ = store.defaultLocalPlaybackDevice
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
    _ = store.catalog.homeLibrary.greeting
    _ = store.catalog.homeLibrary.profileName
    _ = store.catalog.homeLibrary.profileURI
    _ = store.catalog.homeLibrary.homeSections
    _ = store.catalog.homeLibrary.playlists
    _ = store.catalog.homeLibrary.albums
    _ = store.catalog.homeLibrary.artists
    _ = store.catalog.playlistStore.description
    _ = store.catalog.playlistStore.isLoading
    _ = store.catalog.playlistStore.error
}
