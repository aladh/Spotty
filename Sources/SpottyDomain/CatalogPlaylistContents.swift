/// Browsing tracks travel with their collection and account identity. This value supplies
/// playback ordering only; it cannot establish ownership or authorize playlist mutations.
public struct CatalogPlaylistContents: Sendable {
    public let uri: String
    public let accountEpoch: UInt64
    public let collection: CatalogTrackCollection

    public init?(uri: String?, accountEpoch: UInt64, collection: CatalogTrackCollection) {
        guard let uri, SpotifyURI.id(from: uri, kind: "playlist") != nil else { return nil }
        self.uri = uri
        self.accountEpoch = accountEpoch
        self.collection = collection
    }

    public func tracks(for uri: String, accountEpoch: UInt64) -> [CatalogTrack] {
        guard self.uri == uri, self.accountEpoch == accountEpoch else { return [] }
        return collection.tracks
    }
}
