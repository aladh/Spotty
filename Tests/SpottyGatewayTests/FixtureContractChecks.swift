import Foundation
import Testing
@testable import SpottyGateway

@Suite("Fixture contract")
struct FixtureContractTests {
    @Test func searchTrackWrapper() throws {
        let response = try JSONDecoder().decode(
            PathfinderResponse<PathfinderTrackResults>.self, from: gatewayFixture(named: "search-tracks"))
        #expect(response.results?.tracksV2?.entities.first?.name == "Fixture Track")
    }

    @Test func albumTrack() throws {
        let response = try JSONDecoder().decode(PathfinderAlbumResponse.self, from: gatewayFixture(named: "album"))
        #expect(response.data?.albumUnion?.tracks.first?.name == "Fixture Track")
    }

    @Test func discographyGroup() throws {
        let response = try JSONDecoder().decode(PathfinderArtistResponse.self, from: gatewayFixture(named: "artist"))
        #expect(response.data?.artistUnion?.releases.first?.name == "Fixture Album")
    }

    @Test func homeSection() throws {
        let response = try JSONDecoder().decode(PathfinderHomeResponse.self, from: gatewayFixture(named: "home"))
        #expect(response.home?.sections.first?.title == "Fixture shelf")
    }
}
