//
//  HomeLibraryStore.swift
//  Spotty
//
//  Independent, account-scoped Home and saved-library lifetimes.
//

import SpottyDomain
import Foundation
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

    var greeting = "Home"
    var profileName = "Spotify Premium"
    var profileURI: String?
    var homeSections: [CatalogSection] = []
    var playlists: [CatalogItem] = []
    private(set) var playlistLibrary: [PlaylistLibraryNode] = []
    var albums: [CatalogItem] = []
    var artists: [CatalogItem] = []
    private(set) var likedTrackCollection = CatalogTrackCollection()
    var likedTracks: [CatalogTrack] { likedTrackCollection.tracks }
    private(set) var loadingSections: Set<Section> = []
    private(set) var loadedSections: Set<Section> = []
    private(set) var errors: [Section: String] = [:]

    var isLoading: Bool { !loadingSections.isEmpty }
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
        loadingSections = []
        loadedSections = []
        errors = [:]
    }

    /// Launch-critical content only: Home, profile, and playlists for the sidebar. These requests
    /// run concurrently and publish independently; albums, artists, and liked tracks are lazy.
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
                greeting: home.greeting?.transformedLabel ?? "Home",
                sections: CatalogMapping.sections(from: home)
            )
        }
    }

    func loadProfile(force: Bool = false) async {
        await loadSection(.profile, force: force) { [provider] in
            let profile = try await provider.profile()
            return .profile(
                name: profile.name ?? profile.username ?? "Spotify Premium",
                uri: CatalogMapping.profileUserURI(from: profile)
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
            .items(try await provider.libraryAlbums().compactMap(CatalogMapping.item(from:)))
        }
    }

    func loadArtists(force: Bool = false) async {
        await loadSection(.artists, force: force) { [provider] in
            .items(try await provider.libraryArtists().compactMap(CatalogMapping.item(from:)))
        }
    }

    func loadLikedTracks(force: Bool = false) async {
        await loadSection(.likedTracks, force: force) { [provider] in
            .tracks(try await provider.libraryTracks().compactMap(CatalogMapping.track(from:)))
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
        await flight.run(handle) { [weak self] in
            guard let self else { return }
            defer { self.finish(section, handle: handle) }
            do {
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
                    self.playlistLibrary = nodes
                    self.playlists = nodes.flatMap(\.playlists)
                    self.updateLibraryItemCache()
                case let .items(items):
                    if section == .albums { self.albums = items }
                    if section == .artists { self.artists = items }
                    self.updateLibraryItemCache()
                case let .tracks(tracks):
                    likedTrackCollection.replace(tracks)
                    self.metadata.replaceTracks(tracks, from: .library)
                    self.metadata.loadTrackAttributes(for: tracks)
                }
                self.succeed(section, handle: handle)
            } catch {
                self.record(error, for: section, handle: handle)
            }
        }
    }

    private func begin(_ section: Section) {
        SpottyLog.catalog.info("Catalog section started: \(section.rawValue, privacy: .public)")
        loadingSections.insert(section)
        errors[section] = nil
    }

    private func succeed(_ section: Section, handle: Flight.Handle) {
        SpottyLog.catalog.info("Catalog section finished: \(section.rawValue, privacy: .public)")
        loadedSections.insert(section)
        flight.markLoaded(handle)
        errors[section] = nil
    }

    private func finish(_ section: Section, handle: Flight.Handle) {
        guard flight.owns(handle) else { return }
        loadingSections.remove(section)
    }

    private func record(
        _ error: Error,
        for section: Section,
        handle: Flight.Handle
    ) {
        guard flight.shouldReport(error, for: handle) else { return }
        SpottyLog.catalog.error(
            "Catalog section failed: \(section.rawValue, privacy: .public); error=\(String(describing: type(of: error)), privacy: .public)"
        )
        errors[section] = CatalogErrorPresentation.message(for: error)
    }

    private func updateLibraryItemCache() {
        metadata.replaceItems(playlists + albums + artists, from: .library)
    }
}
