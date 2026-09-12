import Testing
import Foundation
@testable import SpottyCore
@testable import SpottyGateway
import SpottyRuntimeContracts

@Suite("Fixture Contract")
struct FixtureContractTests {
    @Test
    @MainActor
    func testFixtureContract() {
        do {
            let decoder = JSONDecoder()

            do {
                do {
                    let response = try decoder.decode(
                        PathfinderResponse<PathfinderTrackResults>.self,
                        from: boundaryFixture(named: "search-tracks")
                    )
                    #expect(
                        (response.results?.tracksV2?.entities.first?.name) == ("Fixture Track"), "track wrapper shape")

                } catch {
                    Issue.record("\("track search fixture decodes"): unexpected error \(error)")
                }
            }
            do {
                do {
                    let response = try decoder.decode(
                        PathfinderAlbumResponse.self, from: boundaryFixture(named: "album"))
                    #expect((response.data?.albumUnion?.tracks.first?.name) == ("Fixture Track"), "album track shape")

                } catch {
                    Issue.record("\("album fixture decodes"): unexpected error \(error)")
                }
            }
            do {
                do {
                    let response = try decoder.decode(
                        PathfinderArtistResponse.self, from: boundaryFixture(named: "artist"))
                    #expect(
                        (response.data?.artistUnion?.releases.first?.name) == ("Fixture Album"),
                        "discography group shape")

                } catch {
                    Issue.record("\("artist fixture decodes"): unexpected error \(error)")
                }
            }
            do {
                do {
                    let response = try decoder.decode(PathfinderHomeResponse.self, from: boundaryFixture(named: "home"))
                    #expect((response.home?.sections.first?.title) == ("Fixture shelf"), "home section shape")

                } catch {
                    Issue.record("\("home fixture decodes"): unexpected error \(error)")
                }
            }
        }
    }
}
