import Foundation
import SpottyDomain
import SpottyRuntimeContracts

enum DiscographySort: String, CaseIterable { case releaseDate = "Release date", name = "Name" }
enum DiscographyLayout: String, CaseIterable { case list = "List", grid = "Grid" }

enum DiscographyReleases {
    static func project(
        _ releases: [CatalogItem], kinds: [String: CatalogArtistReleaseKind], dates: [String: String],
        filter: ArtistReleaseFilter, sort: DiscographySort
    ) -> [CatalogItem] {
        releases.enumerated().filter { _, release in
            switch (filter, kinds[release.uri]) {
            case (.popular, _), (.albums, .album), (.singles, .single), (.singles, .ep), (.compilations, .compilation):
                true
            default: false
            }
        }.sorted { lhs, rhs in
            switch sort {
            case .releaseDate:
                let left = dates[lhs.element.uri] ?? ""
                let right = dates[rhs.element.uri] ?? ""
                if left != right { return left > right }
            case .name:
                let comparison = lhs.element.title.localizedStandardCompare(rhs.element.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
