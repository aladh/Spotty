import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore
@testable import SpottyGateway

@Suite("Media Selection")
struct MediaSelectionTests {
    @Test
    @MainActor
    func testMediaSelection() {
        do {
            let uri = "spotify:playlist:remembered-private-id"
            let remembered = item(uri: uri, title: "Remembered", kind: .playlist)
            var model = MediaSelectionModel()

            #expect((model.select(remembered)) == (.navigate), "playlist selection navigates")
            #expect((model.selection) == (.playlist(uri)), "playlist selection is retained")

            let restored = MediaSelectionModel(rawValue: model.rawValue)
            #expect((restored?.selection) == (.playlist(uri)), "persisted selection round-trips")
            #expect(
                (restored?.item(uri: uri, kind: .playlist, metadataItem: nil)) == (remembered),
                "remembered metadata round-trips")

            let metadata = item(uri: uri, title: "Metadata", kind: .playlist)
            #expect(
                (restored?.item(uri: uri, kind: .playlist, metadataItem: metadata)) == (metadata),
                "metadata supersedes remembered fallback")

            let library = item(uri: uri, title: "Library", kind: .playlist)
            #expect(
                (restored?.item(
                    uri: uri,
                    kind: .playlist,
                    playlists: [library],
                    metadataItem: metadata
                )) == (library), "library playlist has first precedence")

            var sameSelection = restored ?? MediaSelectionModel()
            sameSelection.updateSelection(.playlist(uri))
            #expect(
                (sameSelection.item(uri: uri, kind: .playlist, metadataItem: nil)) == (remembered),
                "same selection preserves remembered fallback")

            sameSelection.updateSelection(.album("spotify:album:different"))
            #expect(
                (sameSelection.item(uri: uri, kind: .playlist, metadataItem: nil)) == nil,
                "different selection clears remembered fallback")

            var resetModel = restored ?? MediaSelectionModel()
            resetModel.reset()
            #expect((resetModel.selection) == (.destination(.home)), "account reset returns home")
            #expect(
                (resetModel.item(uri: uri, kind: .playlist, metadataItem: nil)) == nil,
                "account reset clears remembered fallback")

            let malformed = MediaSelectionModel(rawValue: "not persisted selection state")
            #expect((malformed?.selection) == (.destination(.home)), "malformed persistence falls back home")

            let trackURI = "spotify:track:private-track-id"
            #expect(
                (model.select(item(uri: trackURI, title: "Track", kind: .track))) == (.play(trackURI)),
                "track selection routes playback")
            #expect((model.selection) == (.playlist(uri)), "track selection preserves navigation")
            #expect(
                (model.item(uri: uri, kind: .playlist, metadataItem: nil)) == (remembered),
                "track selection preserves remembered fallback")

            let unknownURI = "spotify:episode:private-unknown-id"
            #expect(
                (model.select(item(uri: unknownURI, title: "Unknown", kind: .unknown))) == (.play(unknownURI)),
                "unknown selection routes playback")
            #expect((model.selection) == (.playlist(uri)), "unknown selection preserves navigation")
            #expect(
                (model.item(uri: uri, kind: .playlist, metadataItem: nil)) == (remembered),
                "unknown selection preserves remembered fallback")
            #expect((model.diagnosticLabel) == ("media:playlist"), "diagnostics retain only the media kind")
            #expect((!model.diagnosticLabel.contains("private-id")) == true, "diagnostics omit the selected URI")
        }
    }
}

private func item(uri: String, title: String, kind: CatalogItem.Kind) -> CatalogItem {
    CatalogItem(
        id: SpotifyURI.id(from: uri) ?? uri,
        uri: uri,
        title: title,
        subtitle: "Synthetic subtitle",
        artworkURL: URL(string: "https://example.invalid/artwork.jpg"),
        kind: kind
    )
}
