import SpottyDomain

/// One desktop publisher's complete entity lookup for an account. Revisions increase when
/// effective browsing metadata changes; collection occurrence identity never crosses this seam.
package struct BrowsingMetadataSnapshot: Sendable {
    package let accountEpoch: UInt64
    package let revision: UInt64
    package let tracks: [String: CatalogTrackMetadata]

    package init(accountEpoch: UInt64, revision: UInt64, tracks: [String: CatalogTrackMetadata]) {
        self.accountEpoch = accountEpoch
        self.revision = revision
        self.tracks = tracks
    }
}
