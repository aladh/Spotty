import SpottyDomain

/// Entity metadata may enrich every occurrence of a requested track. Membership, occurrence UID,
/// requested identity, and date-added belong to the collection and are never copied from an entity.
enum CatalogTrackMetadata {
    static func applying(
        _ entities: [String: CatalogTrack], to collection: CatalogTrackCollection
    ) -> CatalogTrackCollection? {
        var changed = false
        let tracks = collection.tracks.map { occurrence in
            guard let entity = entities[occurrence.uri], entity.uri == occurrence.uri else { return occurrence }
            let updated = CatalogTrack(
                id: occurrence.id, uri: occurrence.uri, title: entity.title, artist: entity.artist,
                album: entity.album, duration: entity.duration, artworkURL: entity.artworkURL,
                addedAt: occurrence.addedAt, artists: entity.artists, albumItem: entity.albumItem,
                occurrenceUID: occurrence.occurrenceUID)
            if updated != occurrence { changed = true }
            return updated
        }
        return changed ? CatalogTrackCollection(tracks: tracks) : nil
    }
}
