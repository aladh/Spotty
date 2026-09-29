import Foundation
import SpottyDomain
@testable import SpottyCore

// Each expected error must occur at its annotated line. The reducer snapshot is absent from
// the facade, and presentation projections have no writable surface for boundary clients.
@MainActor
func rejectPlaybackStoreWrite(_ store: PlaybackStore) {
    // expected-error@+1 {{'currentTrackIndicator' setter is inaccessible}}
    store.currentTrackIndicator = store.currentTrackIndicator
    // expected-error@+1 {{'catalogPlaybackAvailability' setter is inaccessible}}
    store.catalogPlaybackAvailability = store.catalogPlaybackAvailability
    // expected-error@+1 {{value of type 'PlaybackStore' has no member 'state'}}
    _ = store.state
    // expected-error@+1 {{value of type 'PlaybackStore' has no member 'state'}}
    _ = store.state.transport
    // expected-error@+1 {{'requiresReauthentication' setter is inaccessible}}
    store.requiresReauthentication = store.requiresReauthentication
    // expected-error@+1 {{'accountEpoch' setter is inaccessible}}
    store.accountEpoch = store.accountEpoch
    // expected-error@+1 {{'engineGeneration' setter is inaccessible}}
    store.engineGeneration = store.engineGeneration
    // expected-error@+1 {{'phase' is a get-only property}}
    store.phase = store.phase
    // expected-error@+1 {{'trackURI' is a get-only property}}
    store.trackURI = store.trackURI
    // expected-error@+1 {{'trackTitle' is a get-only property}}
    store.trackTitle = store.trackTitle
    // expected-error@+1 {{'artistName' is a get-only property}}
    store.artistName = store.artistName
    // expected-error@+1 {{'artworkURL' is a get-only property}}
    store.artworkURL = store.artworkURL
    // expected-error@+1 {{'isPlaying' is a get-only property}}
    store.isPlaying = store.isPlaying
    // expected-error@+1 {{'isShuffleEnabled' is a get-only property}}
    store.isShuffleEnabled = store.isShuffleEnabled
    // expected-error@+1 {{'repeatMode' is a get-only property}}
    store.repeatMode = store.repeatMode
    // expected-error@+1 {{'isActiveDevice' is a get-only property}}
    store.isActiveDevice = store.isActiveDevice
    // expected-error@+1 {{'position' is a get-only property}}
    store.position = store.position
    // expected-error@+1 {{'duration' is a get-only property}}
    store.duration = store.duration
    // expected-error@+1 {{'positionAnchorDate' is a get-only property}}
    store.positionAnchorDate = store.positionAnchorDate
    // expected-error@+1 {{'queueNextEntries' is a get-only property}}
    store.queueNextEntries = store.queueNextEntries
    // expected-error@+1 {{'history' setter is inaccessible}}
    store.history = store.history
    // expected-error@+1 {{'history' setter is inaccessible}}
    store.history.removeAll()
    // expected-error@+1 {{'connectDevices' is a get-only property}}
    store.connectDevices = store.connectDevices
    // expected-error@+1 {{'localDeviceID' is a get-only property}}
    store.localDeviceID = store.localDeviceID
    // expected-error@+1 {{'isPlaybackCommandPending' is a get-only property}}
    store.isPlaybackCommandPending = store.isPlaybackCommandPending
    // expected-error@+1 {{'hasCurrentTrackMetadata' is a get-only property}}
    store.hasCurrentTrackMetadata = store.hasCurrentTrackMetadata
    // expected-error@+1 {{'transientCommandError' is a get-only property}}
    store.transientCommandError = store.transientCommandError
    // expected-error@+1 {{'isConnected' is a get-only property}}
    store.isConnected = store.isConnected
    // expected-error@+1 {{'catalogCurrentTrack' is a get-only property}}
    store.catalogCurrentTrack = store.catalogCurrentTrack
    // expected-error@+1 {{'displayedTrackTitle' is a get-only property}}
    store.displayedTrackTitle = store.displayedTrackTitle
    // expected-error@+1 {{'displayedArtistName' is a get-only property}}
    store.displayedArtistName = store.displayedArtistName
    // expected-error@+1 {{'displayedArtworkURL' is a get-only property}}
    store.displayedArtworkURL = store.displayedArtworkURL
    // expected-error@+1 {{'hasCurrentTrack' is a get-only property}}
    store.hasCurrentTrack = store.hasCurrentTrack
    // expected-error@+1 {{'showsPauseControl' is a get-only property}}
    store.showsPauseControl = store.showsPauseControl
    // expected-error@+1 {{'canStartPlayback' is a get-only property}}
    store.canStartPlayback = store.canStartPlayback
    // expected-error@+1 {{'canTogglePlayback' is a get-only property}}
    store.canTogglePlayback = store.canTogglePlayback
    // expected-error@+1 {{'canSkipTrack' is a get-only property}}
    store.canSkipTrack = store.canSkipTrack
    // expected-error@+1 {{'statusText' is a get-only property}}
    store.statusText = store.statusText
    // expected-error@+1 {{'activeRemoteDevice' is a get-only property}}
    store.activeRemoteDevice = store.activeRemoteDevice
    // expected-error@+1 {{'remotePlaybackBanner' is a get-only property}}
    store.remotePlaybackBanner = store.remotePlaybackBanner
    // expected-error@+1 {{'commandRoute' is a get-only property}}
    store.commandRoute = store.commandRoute
    // expected-error@+1 {{'greeting' setter is inaccessible}}
    store.catalog.homeLibrary.greeting = "Home"
    // expected-error@+1 {{'profileName' setter is inaccessible}}
    store.catalog.homeLibrary.profileName = "Name"
    // expected-error@+1 {{'profileURI' setter is inaccessible}}
    store.catalog.homeLibrary.profileURI = nil
    // expected-error@+1 {{'homeSections' setter is inaccessible}}
    store.catalog.homeLibrary.homeSections = []
    // expected-error@+1 {{'playlists' setter is inaccessible}}
    store.catalog.homeLibrary.playlists = []
    // expected-error@+1 {{'albums' setter is inaccessible}}
    store.catalog.homeLibrary.albums = []
    // expected-error@+1 {{'artists' setter is inaccessible}}
    store.catalog.homeLibrary.artists = []
    // expected-error@+1 {{'description' is a get-only property}}
    store.catalog.playlistStore.description = ""
    // expected-error@+1 {{'isLoading' is a get-only property}}
    store.catalog.playlistStore.isLoading = false
    // expected-error@+1 {{'error' is a get-only property}}
    store.catalog.playlistStore.error = nil
}
