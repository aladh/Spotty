// swift-tools-version: 6.3

import Foundation
import PackageDescription

private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

// BEGIN GENERATED PLAYBACK ARTIFACT PIN. Run Backend/spotty-playback/update-artifact-pin.sh
// after publishing a new immutable XCFramework. This is the app dependency pin.
private let generatedPlaybackArtifactURL =
    "https://github.com/aladh/Spotty/releases/download/playback-v0.2.1/SpottyPlaybackCore.xcframework.zip"
private let generatedPlaybackArtifactChecksum = "ee930c23f399ba6d1d2923f7d802af08acdefa8f606aabfcdf92063fb88d565d"
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

// One portable graph supports Linux and isolated policy verification on macOS. It never
// evaluates playback selection or resolves shipping dependencies.
private func domainTargets() -> [Target] {
    [
        .target(name: "SpottyDomain", path: "Sources/SpottyDomain", exclude: ["AGENTS.md"]),
        .testTarget(name: "SpottyDomainTests", dependencies: ["SpottyDomain"], path: "Tests/SpottyDomainTests"),
    ]
}
private func domainPackage() -> Package {
    Package(
        name: "Spotty", platforms: [.macOS("27.0")],
        products: [.library(name: "SpottyDomain", targets: ["SpottyDomain"])],
        targets: domainTargets())
}

// Share declarations with the full graph: focused adapter tests must not resolve playback
// or desktop dependencies before SwiftPM even selects what to compile.
private func engineFreeTargets() -> [Target] {
    domainTargets() + [
        .target(name: "SpottyDiagnostics", path: "Sources/SpottyDiagnostics"),
        .target(name: "SpottyRuntimeContracts", dependencies: ["SpottyDomain"]),
        // Shared deterministic test primitives; no production target depends on this module.
        .target(
            name: "SpottyTestSupport", dependencies: ["SpottyRuntimeContracts"],
            path: "Tests/SpottyTestSupport"
        ),
        .testTarget(name: "SpottyTestSupportTests", dependencies: ["SpottyTestSupport"]),
        .target(
            name: "SpottyGateway",
            dependencies: ["SpottyDomain", "SpottyRuntimeContracts", "SpottyDiagnostics"]
        ),
        .testTarget(
            name: "SpottyGatewayTests",
            dependencies: ["SpottyGateway", "SpottyRuntimeContracts", "SpottyDomain", "SpottyTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "SpottyCatalogStorage",
            dependencies: ["SpottyDomain"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "SpottyCatalogStorageTests",
            dependencies: ["SpottyCatalogStorage", "SpottyDomain"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
}
private func engineFreePackage() -> Package {
    Package(name: "Spotty", platforms: [.macOS("27.0")], targets: engineFreeTargets())
}

// These declarations are the sole dependency graph for shipping and focused verification.
private func desktopAndRuntimeTargets() -> [Target] {
    [
        .target(
            name: "SpottySessionRuntime",
            dependencies: [
                "SpottyDomain", "SpottyRuntimeContracts", "SpottyGateway", "SpottyCatalogStorage",
                "SpottyEngineAdapter", "SpottyDiagnostics",
            ]
        ),
        // Shared fakes consume ports and adapters; runtime composition stays in test targets.
        .target(
            name: "SpottyRuntimeTestSupport",
            dependencies: [
                "SpottyEngineAdapter", "SpottyGateway",
                "SpottyRuntimeContracts", "SpottyDomain", "SpottyTestSupport",
            ],
            path: "Tests/SpottyRuntimeTestSupport"
        ),
        .testTarget(
            name: "SpottySessionRuntimeTests",
            dependencies: [
                "SpottySessionRuntime", "SpottyRuntimeContracts", "SpottyDomain", "SpottyCatalogStorage",
                "SpottyEngineAdapter", "SpottyTestSupport", "SpottyRuntimeTestSupport",
            ]
        ),
        // The production owner of the playback binary, C symbols, Rust snapshots and audio
        // renderer. The headless runtime consumes this adapter; desktop code cannot reach it.
        .target(
            name: "SpottyEngineAdapter",
            dependencies: [
                "SpottyDomain", "SpottyPlaybackCore", "SpottyDiagnostics", "SpottyRuntimeContracts",
            ],
            path: "Sources/SpottyEngineAdapter",
            exclude: ["AGENTS.md"],
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(
            name: "SpottyEngineAdapterTests",
            dependencies: [
                "SpottyEngineAdapter", "SpottyPlaybackCore", "SpottyDomain", "SpottyRuntimeContracts",
                "SpottyTestSupport",
            ]
        ),
        .target(
            name: "SpottyCore",
            dependencies: [
                "SpottyDomain", "SpottyRuntimeContracts", "SpottySessionRuntime", "SpottyDiagnostics",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Spotty",
            exclude: [
                "AGENTS.md",
                "Spotify/AGENTS.md",
                "Views/AGENTS.md",
            ]
        ),
        .executableTarget(
            name: "SpottyApp",
            dependencies: ["SpottyCore"],
            path: "Sources/SpottyApp",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        // Cross-module workflows use injected engine ports. C snapshot and event-delivery
        // implementation checks live in SpottyEngineAdapterTests without the desktop.
        .testTarget(
            name: "SpottyBoundaryTests",
            dependencies: [
                "SpottyCore", "SpottyEngineAdapter", "SpottyGateway",
                "SpottySessionRuntime", "SpottyRuntimeContracts",
                "SpottyTestSupport", "SpottyRuntimeTestSupport",
            ],
            path: "Tests/SpottyBoundaryTests"
        ),
    ]
}

private func externalPackages() -> [(name: String, dependency: Package.Dependency)] {
    [("Sparkle", .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))]
}

private func testTargetPackage(_ name: String) -> Package {
    let declarations = desktopAndRuntimeTargets() + engineFreeTargets()
    let packageDeclarations = externalPackages()
    let byName = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
    guard let selected = byName[name], selected.type == .test else {
        fatalError("Unknown focused test target: \(name)")
    }
    var reachable = Set<String>()
    var packages = Set<String>()
    var pending = [name]
    while let current = pending.popLast() {
        guard reachable.insert(current).inserted else { continue }
        // The binary has no local edges. Evaluate its validated declaration only after the
        // dependency walk proves that it is needed, so engine-free cuts ignore overrides.
        if current == "SpottyPlaybackCore" { continue }
        guard let target = byName[current] else {
            fatalError("Unknown local dependency in focused graph: \(current)")
        }
        for dependency in target.dependencies {
            switch dependency {
            case .targetItem(let dependencyName, _), .byNameItem(let dependencyName, _):
                pending.append(dependencyName)
            case .productItem(_, let packageName, _, _):
                guard let packageName,
                    packageDeclarations.contains(where: { $0.name == packageName })
                else {
                    fatalError("Unknown external dependency in focused graph: \(current)")
                }
                packages.insert(packageName)
            @unknown default:
                fatalError("Unsupported dependency in focused graph: \(current)")
            }
        }
    }
    let targets =
        (reachable.contains("SpottyPlaybackCore") ? [playbackTarget()] : [])
        + declarations.filter { reachable.contains($0.name) }
    guard targets.filter({ $0.type == .test }).count == 1 else {
        fatalError("Focused graph must contain exactly one test target")
    }
    return Package(
        name: "Spotty", platforms: [.macOS("27.0")],
        dependencies: packageDeclarations.filter { packages.contains($0.name) }.map(\.dependency),
        targets: targets
    )
}

let package: Package
#if os(macOS)
    let graph = ProcessInfo.processInfo.environment["SPOTTY_PACKAGE_GRAPH"] ?? "full"
    switch graph {
    case "domain":
        package = domainPackage()
    case "engine-free":
        package = engineFreePackage()
    case "full":
        let playbackSelection = playbackTarget()

        package = Package(
            name: "Spotty",
            platforms: [.macOS("27.0")],
            products: [
                .executable(name: "Spotty", targets: ["SpottyApp"]),
                .library(name: "SpottyCore", targets: ["SpottyCore"]),
                .library(name: "SpottyDomain", targets: ["SpottyDomain"]),
            ],
            dependencies: externalPackages().map(\.dependency),
            targets: [playbackSelection] + desktopAndRuntimeTargets() + engineFreeTargets()
        )

        // An opt-in, non-shipping app inspects production views through explicitly enabled testability.
        // The ordinary package graph (including distribution builds) contains no harness or fixtures.
        if ProcessInfo.processInfo.environment["SPOTTY_BUILD_BROWSING_HARNESS"] == "1" {
            package.products.append(.executable(name: "SpottyBrowsingHarness", targets: ["SpottyBrowsingHarness"]))
            package.targets += [
                .target(
                    name: "SpottyBrowsingSupport",
                    dependencies: [
                        "SpottyCore", "SpottyDomain", "SpottySessionRuntime", "SpottyEngineAdapter",
                        "SpottyRuntimeContracts", "SpottyGateway",
                    ],
                    path: "Tests/BrowsingHarness/Support",
                    resources: [.copy("Artwork")]
                ),
                .executableTarget(
                    name: "SpottyBrowsingHarness",
                    dependencies: ["SpottyBrowsingSupport"],
                    path: "Tests/BrowsingHarness/App",
                    linkerSettings: [
                        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
                    ]
                ),
                .testTarget(
                    name: "SpottyBrowsingHarnessTests",
                    dependencies: [
                        "SpottyBrowsingSupport", "SpottyCore", "SpottyDomain", "SpottyGateway",
                        "SpottyEngineAdapter", "SpottyRuntimeContracts", "SpottySessionRuntime",
                    ],
                    path: "Tests/BrowsingHarness/Checks"
                ),
            ]
        }
    default:
        guard graph.hasPrefix("test-target:") else {
            fatalError("SPOTTY_PACKAGE_GRAPH must be full, domain, engine-free, or test-target:NAME")
        }
        package = testTargetPackage(String(graph.dropFirst("test-target:".count)))
    }
#else
    package = domainPackage()
#endif
