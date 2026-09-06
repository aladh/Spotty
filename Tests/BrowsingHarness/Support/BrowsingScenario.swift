#if !DEBUG
    #error("The browsing harness requires Debug testability and must not ship.")
#endif

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import SpottyCore

/// Version one deliberately covers browsing and a signed-out shell, not playback simulation.
struct BrowsingScenario: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case browsing
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

    func validate() throws {
        guard version == 1, (1...5_000).contains(trackCount),
            (1...96).contains(artworkCount), [64, 640, 1_280].contains(artworkPixels),
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
    case checkpoint(String)

    var errorDescription: String? {
        switch self {
        case .invalidScenario: "Use a valid version-1 browsing or signed-out scenario."
        case .unsupportedAction: "This browsing-only harness does not support that action."
        case let .checkpoint(name): "Browsing checkpoint failed: \(name)."
        }
    }
}

struct BrowsingFixtures: Sendable {
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
        let records: [[String: Any]] = (0..<2).map { index in
            [
                "uri": "spotify:playlist:synthetic\(index)", "name": "Synthetic Mix \(index + 1)",
                "description": "Deterministic browsing fixture",
                "images": ["items": [image(index)]],
                "ownerV2": ["data": ["name": "Synthetic Listener", "uri": "spotify:user:synthetic"]],
            ]
        }
        playlists = try records.map { try Self.decode(PathfinderPlaylist.self, $0) }
        var details: [String: PathfinderPlaylistUnion] = [:]
        for (playlistIndex, record) in records.enumerated() {
            var record = record
            let items: [[String: Any]] = (0..<scenario.trackCount).map { index in
                [
                    "uid": "occurrence-\(playlistIndex)-\(index)",
                    "addedAt": ["isoString": "2026-01-01T00:00:00Z"],
                    "itemV2": [
                        "data": [
                            "uri": "spotify:track:synthetic\(playlistIndex)x\(index)",
                            "name": String(format: "Synthetic Track %04d", index + 1),
                            "trackDuration": ["totalMilliseconds": 180_000 + index % 60 * 1_000],
                            "albumOfTrack": ["name": "Synthetic Album \(index / 12 + 1)", "coverArt": image(index)],
                            "artists": ["items": [["profile": ["name": "Synthetic Artist \(index % 12 + 1)"]]]],
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
                "__typename": "HomeResponsePayload", "greeting": ["transformedLabel": "Synthetic browsing"],
                "sectionContainer": [
                    "sections": [
                        "items": [
                            [
                                "uri": "spotify:section:synthetic",
                                "data": ["title": ["transformedLabel": "Repeatable library"]],
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
        else { throw BrowsingFailure.invalidScenario }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let data = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw BrowsingFailure.invalidScenario }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BrowsingFailure.invalidScenario }
        return data as Data
    }
}
