import SpottyDomain
import SpottyRuntimeContracts

extension CatalogMetadataRepository {
    var trackTableSortValues: [String: TrackTableSortValues] {
        trackAttributes.mapValues {
            TrackTableSortValues(popularity: $0.popularity, bpm: $0.bpm, key: $0.key)
        }
    }
}
