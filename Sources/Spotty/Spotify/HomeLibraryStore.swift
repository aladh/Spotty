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
    @ObservationIgnored private var nextRequestID: UInt64 = 0
    @ObservationIgnored private var requestIDs: [Section: UInt64] = [:]
    @ObservationIgnored private var initialLoadTask: Task<Void, Never>?
    @ObservationIgnored private var initialLoadToken: UUID?
    @ObservationIgnored private var sectionTasks: [Section: Task<Void, Never>] = [:]
    @ObservationIgnored private var sectionSessionSnapshots: [Section: CatalogSessionSnapshot] = [:]
    @ObservationIgnored private var loadedSessionSnapshots: [Section: CatalogSessionSnapshot] = [:]
    @ObservationIgnored private var loadSessionSnapshot: CatalogSessionSnapshot?

    init(
        provider: any CatalogProviding,
        metadata: CatalogMetadataRepository,
        session: CatalogSessionAvailability
    ) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
    }

    func reset() {
        nextRequestID &+= 1
        initialLoadTask?.cancel()
        sectionTasks.values.forEach { $0.cancel() }
        initialLoadTask = nil
        initialLoadToken = nil
        sectionTasks.removeAll(keepingCapacity: false)
        sectionSessionSnapshots.removeAll(keepingCapacity: false)
        loadedSessionSnapshots.removeAll(keepingCapacity: false)
        requestIDs.removeAll(keepingCapacity: false)
        loadSessionSnapshot = nil
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
        let currentSession = session.snapshot
        guard currentSession.isAvailable else { return }
        if let initialLoadTask, loadSessionSnapshot == currentSession {
            await initialLoadTask.value
            return
        }

        initialLoadTask?.cancel()
        let token = UUID()
        initialLoadToken = token
        loadSessionSnapshot = currentSession
        let task = Task { [weak self] in
            guard let self else { return }
            async let home: Void = self.loadHome()
            async let profile: Void = self.loadProfile()
            async let playlists: Void = self.loadPlaylists()
            _ = await (home, profile, playlists)
        }
        initialLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if initialLoadToken == token {
            initialLoadTask = nil
            initialLoadToken = nil
            loadSessionSnapshot = nil
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
        let currentSession = session.snapshot
        guard currentSession.isAvailable else { return }
        if let task = sectionTasks[section],
            !force,
            sectionSessionSnapshots[section] == currentSession
        {
            await task.value
            return
        }
        if !force,
            loadedSections.contains(section),
            loadedSessionSnapshots[section] == currentSession
        {
            return
        }

        nextRequestID &+= 1
        let requestID = nextRequestID
        requestIDs[section] = requestID
        let identity = session.requestIdentity(requestID: requestID)
        sectionTasks[section]?.cancel()
        sectionSessionSnapshots[section] = currentSession
        begin(section)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(section, identity: identity) }
            do {
                let payload = try await operation()
                guard self.isCurrent(identity, for: section) else { return }
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
                self.succeed(section)
            } catch {
                self.record(error, for: section, identity: identity)
            }
        }
        sectionTasks[section] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func begin(_ section: Section) {
        SpottyLog.catalog.info("Catalog section started: \(section.rawValue, privacy: .public)")
        loadingSections.insert(section)
        errors[section] = nil
    }

    private func succeed(_ section: Section) {
        SpottyLog.catalog.info("Catalog section finished: \(section.rawValue, privacy: .public)")
        loadedSections.insert(section)
        loadedSessionSnapshots[section] = session.snapshot
        errors[section] = nil
    }

    private func finish(_ section: Section, identity: AccountScopedRequestIdentity) {
        guard requestIDs[section] == identity.requestID else { return }
        loadingSections.remove(section)
        sectionTasks[section] = nil
        sectionSessionSnapshots[section] = nil
    }

    private func record(
        _ error: Error,
        for section: Section,
        identity: AccountScopedRequestIdentity
    ) {
        guard !isCancellation(error), isCurrent(identity, for: section) else { return }
        SpottyLog.catalog.error(
            "Catalog section failed: \(section.rawValue, privacy: .public); error=\(String(describing: type(of: error)), privacy: .public)"
        )
        errors[section] = error.localizedDescription
    }

    private func updateLibraryItemCache() {
        metadata.replaceItems(playlists + albums + artists, from: .library)
    }

    private func isCurrent(
        _ identity: AccountScopedRequestIdentity,
        for section: Section
    ) -> Bool {
        guard let requestID = requestIDs[section] else { return false }
        return identity.isCurrent(
            requestID: requestID,
            accountEpoch: session.accountEpoch,
            sessionRevision: session.snapshot.revision,
            isAvailable: session.isAvailable,
            isCancelled: Task.isCancelled
        )
    }
}
