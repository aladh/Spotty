import SpottyDomain
import Synchronization

extension PartnerAPI {
    /// One complete tree in server order. All folders share a page and raw-entry budget;
    /// repeated folder identities, incomplete pagination, and failed children reject the read.
    func playlistLibrary() async throws -> [PlaylistLibraryNode] {
        let budget = PlaylistLibraryReadBudget()
        let folders = try await withThrowingTaskGroup(
            of: (PlaylistFolderRequest, [PlaylistLibraryEntry]).self
        ) { group in
            var pending = [PlaylistFolderRequest(uri: nil, depth: 0)]
            var next = 0
            var active = 0
            var discovered: Set<String> = []
            var results: [String: [PlaylistLibraryEntry]] = [:]
            while next < pending.count || active > 0 {
                try Task.checkCancellation()
                while active < 4, next < pending.count {
                    let request = pending[next]
                    next += 1
                    active += 1
                    group.addTask { (request, try await playlistLibraryEntries(request.uri, budget: budget)) }
                }
                guard let (request, entries) = try await group.next() else { break }
                active -= 1
                guard entries.isEmpty || request.depth <= PlaylistLibraryLimits.maximumDepth else {
                    throw PartnerAPIError.libraryLimitReached
                }
                // Validate every discovery before the next scheduling turn. A repeated folder
                // cannot overwrite another branch or cause duplicate requests, even across pages.
                for case let .folder(uri, _) in entries {
                    guard discovered.insert(uri).inserted else { throw PartnerAPIError.emptyPayload }
                    pending.append(PlaylistFolderRequest(uri: uri, depth: request.depth + 1))
                }
                results[request.uri ?? ""] = entries
            }
            return results
        }
        func nodes(in key: String) throws -> [PlaylistLibraryNode] {
            try Task.checkCancellation()
            guard let entries = folders[key] else { throw PartnerAPIError.emptyPayload }
            return try entries.map { entry in
                try Task.checkCancellation()
                switch entry {
                case .playlist(let item): return PlaylistLibraryNode(playlist: item)
                case .folder(let uri, let title):
                    return PlaylistLibraryNode(folderURI: uri, title: title, children: try nodes(in: uri))
                }
            }
        }
        return try nodes(in: "")
    }

    private func playlistLibraryEntries(_ folderURI: String?, budget: PlaylistLibraryReadBudget) async throws
        -> [PlaylistLibraryEntry]
    {
        try await Pagination.collect { offset in
            try budget.reservePage()
            let response: PathfinderLibraryResponse<PathfinderPlaylist> = try await query(
                .libraryV3,
                variables: PathfinderLibraryVariables(
                    filters: [LibraryFilter.playlists], offset: offset, limit: LibraryFilter.playlistPageLimit,
                    order: "Custom Order", flatten: false, folderUri: folderURI))
            guard let page = response.page, let items = page.items else { throw PartnerAPIError.emptyPayload }
            try budget.consumeEntries(items.count)
            // Count unavailable entries before mapping. Only compact domain values survive
            // this page; tree discovery and assembly share one interpretation of each entry.
            let entries = try items.compactMap { try $0.item?.data.flatMap(PlaylistLibraryEntry.init) }
            return Pagination.Page(items: entries, pageEntryCount: items.count, totalCount: page.totalCount)
        }
    }
}

private struct PlaylistFolderRequest: Sendable {
    let uri: String?
    let depth: Int
}

private enum PlaylistLibraryEntry: Sendable {
    case playlist(CatalogItem)
    case folder(uri: String, title: String)

    init?(_ value: PathfinderPlaylist) throws {
        if let item = CatalogMapping.item(from: value) {
            self = .playlist(item)
        } else if let uri = value.uri, uri.contains(":folder:") {
            let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.first == "spotify", parts.allSatisfy({ !$0.isEmpty }),
                (parts.count == 3 && parts[1] == "folder")
                    || (parts.count == 5 && parts[1] == "user" && parts[3] == "folder")
            else { throw PartnerAPIError.emptyPayload }
            self = .folder(uri: uri, title: value.name ?? "Folder")
        } else {
            return nil
        }
    }
}

/// A single load owns these counters. Short synchronous reservations keep every concurrent
/// folder inside the same work budget without adding an executor or a caller-visible port.
private final class PlaylistLibraryReadBudget: Sendable {
    private struct State {
        var remainingPages = Pagination.maximumPageCount
        var remainingEntries = PlaylistLibraryLimits.maximumNodes
        var failed = false
    }
    private let state = Mutex(State())

    func reservePage() throws {
        try Task.checkCancellation()
        try state.withLock {
            guard !$0.failed, $0.remainingPages > 0 else {
                $0.failed = true
                throw PartnerAPIError.libraryLimitReached
            }
            $0.remainingPages -= 1
        }
    }

    func consumeEntries(_ count: Int) throws {
        try Task.checkCancellation()
        try state.withLock {
            guard !$0.failed, count <= $0.remainingEntries else {
                $0.failed = true
                throw PartnerAPIError.libraryLimitReached
            }
            $0.remainingEntries -= count
        }
    }
}
