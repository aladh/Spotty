import SpottyDomain

/// A successful envelope and an explicitly present item list. Missing content never means an
/// authoritative empty collection, even when HTTP and JSON decoding both succeeded.
struct ValidatedCatalogPage<Header: Sendable, Item: Sendable>: Sendable {
    let header: Header
    let items: [Item]
    let totalCount: Int?

    init(
        header: Header?, typename: String?, expectedType: String,
        uri: String?, requestedURI: String, items: [Item]?, totalCount: Int?
    ) throws {
        guard let header, typename == expectedType, let items,
            uri == nil || uri == requestedURI
        else { throw PartnerAPIError.emptyPayload }
        self.header = header
        self.items = items
        self.totalCount = totalCount
    }
}

/// Only a completed bounded walk can create this value. Header metadata stays paired with its
/// complete occurrence sequence until the gateway maps it into the public catalog contract.
struct CompleteCatalogCollection<Header: Sendable, Item: Sendable>: Sendable {
    let header: Header
    let items: [Item]

    private init(header: Header, items: [Item]) {
        self.header = header
        self.items = items
    }

    static func collect(
        fetchPage: @Sendable (Int) async throws -> ValidatedCatalogPage<Header, Item>
    ) async throws -> Self {
        let first = try await fetchPage(0)
        do {
            let items = try await Pagination.collect(
                firstPage: Pagination.Page(
                    items: first.items, pageEntryCount: first.items.count, totalCount: first.totalCount)
            ) { offset in
                let page = try await fetchPage(offset)
                return Pagination.Page(items: page.items, pageEntryCount: page.items.count, totalCount: page.totalCount)
            }
            return Self(header: first.header, items: items)
        } catch let failure as Pagination.Failure {
            throw PartnerAPIError.pagination(failure)
        }
    }
}

typealias CompleteAlbum = CompleteCatalogCollection<PathfinderAlbumUnion, PathfinderAlbumUnion.TrackList.Item>
typealias CompletePlaylist = CompleteCatalogCollection<PathfinderPlaylistUnion, PathfinderPlaylistItem>
typealias CompleteDiscography = CompleteCatalogCollection<PathfinderArtistUnion, PathfinderReleaseGroup.Item>

extension PathfinderItems {
    /// Individual unavailable entries can be skipped, but absence of the requested list is a
    /// response-shape failure. Use this at read boundaries instead of the permissive metadata view.
    func validatedEntities() throws -> [Item] {
        guard let items else { throw PartnerAPIError.emptyPayload }
        return items.compactMap(\.entity)
    }
}

extension PathfinderLibraryPage {
    func validatedEntities() throws -> [Entity] {
        guard let items else { throw PartnerAPIError.emptyPayload }
        return items.compactMap(\.item?.data)
    }
}
