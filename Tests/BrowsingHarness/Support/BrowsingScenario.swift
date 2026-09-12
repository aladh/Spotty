#if !DEBUG && !SPOTTY_BROWSING_OPTIMIZED
    #error("The browsing harness requires Debug or the isolated optimized Demo build with explicit testability.")
#endif
#if DEBUG && SPOTTY_BROWSING_OPTIMIZED
    #error("The optimized Demo requires the Release configuration.")
#endif

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import SpottyCore
@testable import SpottyGateway

/// Version one retains browsing compatibility; version two adds isolated playback scenarios.
struct BrowsingScenario: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case browsing
        case playback
        case signedOut = "signed-out"
    }

    var version = 1
    var mode = Mode.browsing
    var trackCount = 1_000
    var artworkCount = 48
    var artworkPixels = 640
    var cycles = 3
    /// A declared viewing cadence, not a readiness timeout or simulated network delay.
    var dwellMilliseconds = 250
    var combinedHydration: Bool? = nil
    /// Rich interactive library; omitted in historical measurement scenarios.
    var expandedLibrary: Bool? = nil
    /// Keep historical stress runs comparable; false lets AppKit schedule layout normally.
    var forceSynchronousLayout: Bool? = nil

    func validate() throws {
        guard (1...2).contains(version), (mode != .playback || version == 2), (1...5_000).contains(trackCount),
            (combinedHydration != true || mode == .playback), (1...96).contains(artworkCount),
            [64, 640, 1_280].contains(artworkPixels),
            (1...10).contains(cycles), (100...2_000).contains(dwellMilliseconds)
        else { throw BrowsingFailure.invalidScenario }
    }

    static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
}

enum BrowsingFailure: Error, LocalizedError {
    case invalidScenario
    case unsupportedAction
    case artworkResource
    case checkpoint(String)

    var errorDescription: String? {
        switch self {
        case .invalidScenario: "Use a valid browsing, signed-out, or version-2 playback scenario."
        case .artworkResource: "Rebuild the demo with its bundled artwork resources."
        case .unsupportedAction: "This demo does not support that action."
        case let .checkpoint(name): "Browsing checkpoint failed: \(name)."
        }
    }
}

struct BrowsingFixtures: Sendable {
    static let topLevelPlaylistCount = 20
    static let folderNames = ["Focus", "Weekend"]
    static let playlistsPerFolder = 4
    static let expandedPlaylistCount = topLevelPlaylistCount + folderNames.count * playlistsPerFolder
    static let playlistNames = [
        "Moonlit Drive", "Neon Afterglow", "Sunday Coffee", "Soft Focus", "Coastal Morning",
        "Night Bus Home", "Golden Hour", "Rain on the Window", "Kitchen Dancing", "Quiet Momentum",
        "Indie Daydream", "Late Checkout", "City in Bloom", "Analog Warmth", "Open Road",
        "Slow Sundays", "After Work", "Fresh Air", "Midnight Radio", "Low-Key Favorites",
        "Deep Work", "Instrumental Focus", "Morning Flow", "No Distractions", "Weekend Warm-Up",
        "Saturday Sun", "Dinner with Friends", "Sunday Reset",
    ]
    static let playlistDescriptions = [
        "Dreamy songs for the drive home", "Electric nights and glowing city streets",
        "A slow start with something warm", "Gentle textures for an unhurried afternoon",
        "Bright songs for open windows", "The soundtrack for watching the city pass by",
        "Hold on to the last light", "Soft songs for grey weather", "Turn the kitchen into a dance floor",
        "Steady energy without the noise", "Guitars, daydreams, and good company",
        "One more song before heading downstairs", "Fresh finds with room to breathe",
        "Warm recordings and timeless melodies", "Songs that make the miles disappear",
        "Nothing urgent, nowhere else to be", "A clean break between work and evening",
        "Music made for getting outside", "Songs worth staying up for", "The ones that always fit",
        "Long stretches of uninterrupted concentration", "Words out, focus on",
        "A clear head and an easy rhythm", "Calm sounds for getting things done",
        "Start the weekend at full volume", "Sunshine, side streets, and nowhere to rush",
        "Crowd-pleasers for a table full of people", "Ease into the week ahead",
    ]
    static let trackNames = [
        "Silver Lining", "Night Transit", "Paper Sun", "Glass Garden", "Afterimage", "Violet Orbit",
        "Static on the Line", "Coastline", "Half Awake", "Borrowed Time", "Northern Lights", "Slow Motion",
        "Blue Hour", "Backseat Summer", "Familiar Streets", "Signals", "Warm Nights", "Passing Through",
        "Open Window", "Satellite Heart", "Second Wind", "Side by Side", "Wildflower", "Stay for a While",
        "First Light", "Out of Frame", "Long Way Home", "Tidal Lines", "Velvet Sky", "Here and Now",
        "Easy Company", "Turning Pages", "Distant Thunder", "Under the Pines", "Little Victories", "Daybreak",
        "Parallel Lines", "Good Intentions", "September Air", "Anywhere with You", "Last Train", "Soft Landing",
        "Bright Side", "The Way It Goes", "Quietly Loud", "Between Stations", "New Perspective", "Home Again",
    ]
    static let albumNames = [
        "Signals at Dusk", "Postcards from Nowhere", "Rooms with Open Windows", "Northern Exposure",
        "Everything in Motion", "Polaroid Weather", "The Long Weekend", "Maps We Never Used",
        "Small Hours", "Color Theory", "Familiar Places", "A Different Light",
    ]
    static let artistNames = [
        "Harbor Lights", "Mara Vale", "The Side Streets", "June Arcade", "Northbound", "Ellis Rowe",
        "Paper Satellites", "Cedar House", "Lena Hart", "Atlas Bloom", "Night Weather", "Theo Lane",
    ]
    static let listenerNames = [
        "Mara Vale", "Ellis Rowe", "Lena Hart", "Theo Lane", "Nina Cole",
    ]

    static func playlistName(at index: Int) -> String { playlistNames[index % playlistNames.count] }
    static func playlistDescription(at index: Int) -> String {
        playlistDescriptions[index % playlistDescriptions.count]
    }
    static func trackName(at index: Int) -> String { trackNames[index % trackNames.count] }
    static func albumName(at index: Int) -> String { albumNames[index % albumNames.count] }
    static func artistName(at index: Int) -> String { artistNames[index % artistNames.count] }
    static func listenerName(at index: Int) -> String { listenerNames[index % listenerNames.count] }

    static func addedAt(playlistIndex: Int, trackIndex: Int) -> String {
        let ordinal = (trackIndex + playlistIndex * 13) % 1_344
        let year = 2025 - ordinal / 336
        let dayOfYear = ordinal % 336
        let month = 12 - dayOfYear / 28
        let day = 28 - dayOfYear % 28
        return String(format: "%04d-%02d-%02dT00:00:00Z", year, month, day)
    }

    let playlists: [PathfinderPlaylist]
    let details: [String: PathfinderPlaylistUnion]
    let home: PathfinderHome
    let artworkURLs: [URL]
    let artworkBytes: Int

    init(scenario: BrowsingScenario, artworkDirectory: URL) throws {
        try scenario.validate()
        guard artworkDirectory.isFileURL else { throw BrowsingFailure.invalidScenario }
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let urls = (0..<scenario.artworkCount).map { artworkDirectory.appendingPathComponent("\($0).png") }
        var bytes = 0
        for (index, url) in urls.enumerated() {
            let data = try Self.png(index: index, pixels: scenario.artworkPixels)
            try data.write(to: url, options: .atomic)
            bytes += data.count
        }
        artworkURLs = urls
        artworkBytes = bytes
        func image(_ index: Int) -> [String: Any] {
            [
                "sources": [
                    [
                        "url": urls[index % scenario.artworkCount].absoluteString,
                        "width": scenario.artworkPixels, "height": scenario.artworkPixels,
                    ]
                ]
            ]
        }
        let playlistCount = scenario.expandedLibrary == true ? Self.expandedPlaylistCount : 2
        let records: [[String: Any]] = (0..<playlistCount).map { index in
            [
                "uri": "spotify:playlist:synthetic\(index)", "name": Self.playlistName(at: index),
                "description": Self.playlistDescription(at: index),
                "images": ["items": [image(index)]],
                "ownerV2": [
                    "data": ["name": Self.listenerName(at: index), "uri": "spotify:user:synthetic\(index)"]
                ],
            ]
        }
        playlists = try records.map { try Self.decode(PathfinderPlaylist.self, $0) }
        var details: [String: PathfinderPlaylistUnion] = [:]
        for (playlistIndex, record) in records.enumerated() {
            var record = record
            let items: [[String: Any]] = (0..<scenario.trackCount).map { index in
                [
                    "uid": "occurrence-\(playlistIndex)-\(index)",
                    "addedAt": ["isoString": Self.addedAt(playlistIndex: playlistIndex, trackIndex: index)],
                    "itemV2": [
                        "data": [
                            "uri": "spotify:track:synthetic\(playlistIndex)x\(index)",
                            "name": Self.trackName(at: index),
                            "trackDuration": ["totalMilliseconds": 180_000 + index % 60 * 1_000],
                            "albumOfTrack": ["name": Self.albumName(at: index), "coverArt": image(index)],
                            "artists": ["items": [["profile": ["name": Self.artistName(at: index)]]]],
                        ]
                    ],
                ]
            }
            record["content"] = ["items": items, "totalCount": items.count]
            details["synthetic\(playlistIndex)"] = try Self.decode(PathfinderPlaylistUnion.self, record)
        }
        self.details = details
        home = try Self.decode(
            PathfinderHome.self,
            [
                "__typename": "HomeResponsePayload", "greeting": ["transformedLabel": "Good afternoon"],
                "sectionContainer": [
                    "sections": [
                        "items": [
                            [
                                "uri": "spotify:section:synthetic",
                                "data": ["title": ["transformedLabel": "Made for the moment"]],
                                "sectionItems": [
                                    "items": records.map {
                                        ["content": ["__typename": "PlaylistResponseWrapper", "data": $0]]
                                    }
                                ],
                            ]
                        ]
                    ]
                ],
            ])
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    /// Materialize bundled demo art at the scenario size before measuring the UI workload.
    private static func png(index: Int, pixels: Int) throws -> Data {
        let names = ["tidal-light", "night-transit", "paper-sun", "glass-garden", "afterimage", "violet-orbit"]
        guard
            let url = Bundle.module.url(
                forResource: names[index % names.count], withExtension: "jpg", subdirectory: "Artwork"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw BrowsingFailure.artworkResource }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let data = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw BrowsingFailure.artworkResource }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BrowsingFailure.artworkResource }
        return data as Data
    }
}
