// swift-tools-version: 6.3

import Foundation
import PackageDescription

private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

// BEGIN GENERATED PLAYBACK ARTIFACT PIN. Run Backend/spotty-playback/update-artifact-pin.sh
// after publishing a new immutable XCFramework. This is the app dependency pin.
private let generatedPlaybackArtifactURL =
    "https://github.com/aladh/Spotty/releases/download/playback-v0.1.1/SpottyPlaybackCore.xcframework.zip"
private let generatedPlaybackArtifactChecksum = "27831f909a9dba1686faf40658d02b34a535c862a91a5cfd7105d676a15fdbed"
// END GENERATED PLAYBACK ARTIFACT PIN

private func pathRelativeToPackageRoot(_ url: URL) -> String {
    let baseComponents = packageRoot.standardizedFileURL.pathComponents
    let targetComponents = url.standardizedFileURL.pathComponents
    var commonCount = 0
    while commonCount < baseComponents.count,
        commonCount < targetComponents.count,
        baseComponents[commonCount] == targetComponents[commonCount]
    {
        commonCount += 1
    }
    let parentComponents = Array(repeating: "..", count: baseComponents.count - commonCount)
    let childComponents = Array(targetComponents.dropFirst(commonCount))
    return (parentComponents + childComponents).joined(separator: "/")
}

private func manifestString(
    _ key: String,
    from manifest: [String: Any],
    context: String = "artifact manifest"
) -> String {
    guard let value = manifest[key] as? String, !value.isEmpty else {
        fatalError("\(context) is missing a non-empty \(key) string")
    }
    return value
}

private func playbackTarget() -> Target {
    guard let override = ProcessInfo.processInfo.environment["SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK"] else {
        return .binaryTarget(
            name: "SpottyPlaybackCore",
            url: generatedPlaybackArtifactURL,
            checksum: generatedPlaybackArtifactChecksum
        )
    }

    let url = URL(fileURLWithPath: override, relativeTo: packageRoot).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        fatalError("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK must point to an existing XCFramework directory")
    }
    guard url.pathExtension == "xcframework" else {
        fatalError("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK must point to a .xcframework directory")
    }
    let provenanceURL = url.appendingPathComponent("spotty_playback_provenance.json")
    guard
        let data = try? Data(contentsOf: provenanceURL),
        let object = try? JSONSerialization.jsonObject(with: data),
        let provenance = object as? [String: Any],
        let source = provenance["source"] as? [String: Any]
    else {
        fatalError(
            "SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK must contain spotty_playback_provenance.json"
        )
    }
    let sourceDigest = manifestString(
        "engineInputDigest",
        from: source,
        context: "playback provenance source"
    )
    let libraryDigest = manifestString(
        "librarySHA256",
        from: provenance,
        context: "playback provenance"
    )
    let digestPattern = "^[0-9a-fA-F]{64}$"
    guard
        sourceDigest.range(of: digestPattern, options: .regularExpression) != nil,
        libraryDigest.range(of: digestPattern, options: .regularExpression) != nil
    else {
        fatalError("Playback provenance digests must be 64-character SHA-256 hex strings")
    }

    return .binaryTarget(name: "SpottyPlaybackCore", path: pathRelativeToPackageRoot(url))
}

private let playbackSelection = playbackTarget()

let package = Package(
    name: "Spotty",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Spotty", targets: ["SpottyApp"]),
        .library(name: "SpottyCore", targets: ["SpottyCore"]),
        .library(name: "SpottyDomain", targets: ["SpottyDomain"]),
    ],
    targets: [
        playbackSelection,
        .target(
            name: "SpottyCore",
            dependencies: ["SpottyDomain", "SpottyPlaybackCore"],
            path: "Sources/Spotty",
            exclude: [
                "AGENTS.md",
                "Spotify/AGENTS.md",
                "Views/AGENTS.md",
            ],
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "SpottyApp",
            dependencies: ["SpottyCore"],
            path: "Sources/SpottyApp"
        ),
        .target(
            name: "SpottyDomain",
            path: "Sources/SpottyDomain",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "SpottyDomainTests",
            dependencies: ["SpottyDomain"],
            path: "Tests/SpottyDomainTests"
        ),
        .testTarget(
            name: "SpottyBoundaryTests",
            dependencies: ["SpottyCore"],
            path: "Tests/SpottyBoundaryTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)

// An opt-in, non-shipping app can inspect internal production views through Debug testability.
// The ordinary package graph (including distribution builds) contains no harness or fixtures.
if ProcessInfo.processInfo.environment["SPOTTY_BUILD_BROWSING_HARNESS"] == "1" {
    package.products.append(.executable(name: "SpottyBrowsingHarness", targets: ["SpottyBrowsingHarness"]))
    package.targets += [
        .target(
            name: "SpottyBrowsingSupport",
            dependencies: ["SpottyCore"],
            path: "Tests/BrowsingHarness/Support",
            resources: [.copy("Artwork")]
        ),
        .executableTarget(
            name: "SpottyBrowsingHarness",
            dependencies: ["SpottyBrowsingSupport"],
            path: "Tests/BrowsingHarness/App"
        ),
        .testTarget(
            name: "SpottyBrowsingHarnessTests",
            dependencies: ["SpottyBrowsingSupport", "SpottyCore"],
            path: "Tests/BrowsingHarness/Checks"
        ),
    ]
}
