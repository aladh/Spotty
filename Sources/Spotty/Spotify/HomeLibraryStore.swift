//
//  HomeLibraryStore.swift
//  Spotty
//
//  Independent, account-scoped Home and saved-library lifetimes.
//

import SpottyDomain
import Foundation
import SpottyRuntimeContracts
import OSLog

@MainActor
@Observable
final class HomeLibraryStore {
    private typealias Flight = AccountScopedSingleFlight<Request>

    /// Independent request lifetimes: the launch-critical aggregate load and each section.
    private enum Request: Hashable, Sendable {
        case initialLoad
        case section(Section)
    }

    enum Section: String, CaseIterable, Hashable, Sendable {
        case home = "Home"
        case profile = "Profile"
        case playlists = "Playlists"
        case albums = "Albums"
        case artists = "Artists"
        case likedTracks = "Liked Songs"
    }

    private(set) var greeting = "Home"
    private(set) var profileName = "Spotify Premium"
    private(set) var profileURI: String?
    private(set) var homeSections: [CatalogSection] = []
    private(set) var playlists: [CatalogItem] = []
    private(set) var playlistLibrary: [PlaylistLibraryNode] = []
    var playlistLibraryIsCached: Bool { state(for: .playlists).isShowingSavedContent(in: session.snapshot) }
    private(set) var albums: [CatalogItem] = []
    private(set) var artists: [CatalogItem] = []
    private(set) var likedTrackCollection = CatalogTrackCollection()
    var likedTracks: [CatalogTrack] { likedTrackCollection.tracks }
    private var sectionStates: [Section: CatalogLoadState] = [:]
    var loadingSections: Set<Section> { Set(Section.allCases.filter { state(for: $0).isLoading }) }
    var loadedSections: Set<Section> { Set(Section.allCases.filter { state(for: $0).hasContent }) }
    var errors: [Section: String] {
        Dictionary(
            uniqueKeysWithValues: Section.allCases.compactMap { section in
                state(for: section).error.map { (section, $0) }
            })
    }

    private func state(for section: Section) -> CatalogLoadState { sectionStates[section] ?? CatalogLoadState() }

    var isLoading: Bool { !loadingSections.isEmpty }
    var isLoadingInitialPlaylists: Bool { isLoading(.playlists) && !loadedSections.contains(.playlists) }
    var error: String? {
        let messages = Section.allCases.compactMap { section in
            errors[section].map { "\(section.rawValue): \($0)" }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "  •  ")
    }

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let flight: Flight

    init(
        provider: any CatalogProviding,
        metadata: CatalogMetadataRepository,
        session: CatalogSessionAvailability
    ) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
        // Sections publish independently, so each request key owns its own lifetime.
        flight = Flight(session: session, join: .joinMatchingKey, scope: .perKey, publish: .strict)
    }

    func reset() {
        flight.reset()
        greeting = "Home"
        profileName = "Spotify Premium"
        profileURI = nil
        homeSections = []
        playlists = []
        playlistLibrary = []
        albums = []
        artists = []
        likedTrackCollection.replace([])
        sectionStates = [:]
    }

    /// Home and profile publish independently. The sidebar verifies the profile, restores saved
    /// content, then refreshes; albums, artists, and liked tracks are lazy.
    func load() async {
        let interval = SpottyLog.catalogSignposter.beginInterval("Initial catalog load")
        defer { SpottyLog.catalogSignposter.endInterval("Initial catalog load", interval) }
        switch flight.admit(.initialLoad) {
        case .skip:
            return
        case let .join(claim):
            await flight.awaitFlight(claim)
        case let .start(handle):
            await flight.run(handle) { [weak self] in
                guard let self else { return }
                async let home: Void = self.loadHome()
                async let profile: Void = self.loadProfile()
                async let playlists: Void = self.loadPlaylists()
                _ = await (home, profile, playlists)
            }
        }
    }

    func loadHome(force: Bool = false) async {
        await loadSection(.home, force: force) { [provider] in
            let home = try await provider.home()
            return .home(
                greeting: home.greeting,
                sections: home.sections
            )
        }
    }

    func loadProfile(force: Bool = false) async {
        await loadSection(.profile, force: force) { [provider] in
            let profile = try await provider.profile()
            return .profile(
                name: profile.name,
                uri: profile.uri
            )
        }
    }

    func loadPlaylists(force: Bool = false) async {
        await loadSection(.playlists, force: force) { [provider] in
            .playlistLibrary(try await provider.playlistLibrary())
        }
    }

    func loadAlbums(force: Bool = false) async {
        await loadSection(.albums, force: force) { [provider] in
            .items(try await provider.libraryAlbums())
        }
    }

    func loadArtists(force: Bool = false) async {
        await loadSection(.artists, force: force) { [provider] in
            .items(try await provider.libraryArtists())
        }
    }

    func loadLikedTracks(force: Bool = false) async {
        await loadSection(.likedTracks, force: force) { [provider] in
            .tracks(try await provider.libraryTracks())
        }
    }

    func error(for section: Section) -> String? { errors[section] }
    func isLoading(_ section: Section) -> Bool { loadingSections.contains(section) }

    private enum SectionPayload: Sendable {
        case home(greeting: String, sections: [CatalogSection])
        case profile(name: String, uri: String?)
        case items([CatalogItem])
        case playlistLibrary([PlaylistLibraryNode])
        case tracks([CatalogTrack])
    }

    private func loadSection(
        _ section: Section,
        force: Bool,
        operation: @escaping @Sendable () async throws -> SectionPayload
    ) async {
        if !force, state(for: section).isCurrent(in: session.snapshot) { return }
        let handle: Flight.Handle
        switch flight.admit(.section(section), force: force) {
        case .skip:
            return
        case let .join(claim):
            await flight.awaitFlight(claim)
            return
        case let .start(started):
            handle = started
        }

        begin(section)
        defer { finish(section, handle: handle) }
        await flight.run(handle) { [weak self] in
            guard let self else { return }
            do {
                if section == .playlists {
                    // The live profile opens the matching disk partition. Joining the profile
                    // flight keeps account proof shared with startup and explicit library retries.
                    await self.loadProfile()
                    guard self.flight.isCurrent(handle) else { return }
                    if !self.loadedSections.contains(.playlists),
                        let cached = try await self.provider.cachedPlaylistLibrary()
                    {
                        guard self.flight.isCurrent(handle) else { return }
                        self.applyPlaylistLibrary(cached.nodes, cached: true)
                        self.sectionStates[.playlists, default: CatalogLoadState()].receive(
                            session: handle.sessionSnapshot, freshness: .cached(fetchedAt: cached.fetchedAt))
                        SpottyLog.catalog.info("Saved playlist library restored")
                    }
                }
                guard self.flight.isCurrent(handle) else { return }
                let payload = try await operation()
                guard self.flight.isCurrent(handle) else { return }
                switch payload {
                case let .home(greeting, sections):
                    self.greeting = greeting
                    self.homeSections = sections
                    self.metadata.replaceItems(sections.flatMap(\.items), from: .home)
                case let .profile(name, uri):
                    self.profileName = name
                    self.profileURI = uri
                case let .playlistLibrary(nodes):
                    self.applyPlaylistLibrary(nodes, cached: false)
                case let .items(items):
                    if section == .albums { self.albums = items }
                    if section == .artists { self.artists = items }
                    self.updateLibraryItemCache()
                case let .tracks(tracks):
                    likedTrackCollection.replace(tracks)
                    self.metadata.replaceTracks(tracks, from: .library)
                }
                self.succeed(section, handle: handle)
            } catch {
                self.record(error, for: section, handle: handle)
            }
        }
    }

    private func begin(_ section: Section) {
        SpottyLog.catalog.info("Catalog section started: \(section.rawValue, privacy: .public)")
        sectionStates[section, default: CatalogLoadState()].begin(keepPreviousError: false)
        if section == .playlists, loadedSections.contains(.playlists) {
            applyPlaylistLibrary(playlistLibrary, cached: true)
        }
    }

    private func succeed(_ section: Section, handle: Flight.Handle) {
        SpottyLog.catalog.info("Catalog section finished: \(section.rawValue, privacy: .public)")
        sectionStates[section, default: CatalogLoadState()].receive(session: handle.sessionSnapshot)
    }

    private func finish(_ section: Section, handle: Flight.Handle) {
        guard flight.owns(handle) else { return }
        sectionStates[section, default: CatalogLoadState()].finish()
    }

    private func record(
        _ error: Error,
        for section: Section,
        handle: Flight.Handle
    ) {
        guard flight.shouldReport(error, for: handle) else { return }
        if sectionStates[section, default: CatalogLoadState()].fail(error) {
            // A refusal fences every sibling request sharing this account, not just the failed
            // section. No in-flight Home/library response can restore rejected account content.
            reset()
            for affected in Section.allCases {
                sectionStates[affected, default: CatalogLoadState()].fail(error)
            }
            metadata.replaceItems([], from: .home)
            metadata.replaceItems([], from: .library)
            metadata.replaceTracks([], from: .library)
        } else if section == .playlists, loadedSections.contains(.playlists) {
            applyPlaylistLibrary(playlistLibrary, cached: true)
        }
        SpottyLog.catalog.error(
            "Catalog section failed: \(section.rawValue, privacy: .public); error=\(String(describing: type(of: error)), privacy: .public)"
        )
    }

    private func updateLibraryItemCache() {
        metadata.replaceItems(playlists + albums + artists, from: .library)
    }

    private func applyPlaylistLibrary(_ nodes: [PlaylistLibraryNode], cached: Bool) {
        playlistLibrary = cached ? nodes.map(\.withoutOwnership) : nodes
        playlists = playlistLibrary.flatMap(\.playlists)
        updateLibraryItemCache()
    }

}
