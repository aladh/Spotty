import Foundation

struct BrowsingSourceIdentity: Codable {
    let revision: String
    let diffSHA256: String
    let sourceSHA256: String
    let trackedFileCount: Int
    let untrackedFileCount: Int
    let includesUntrackedNonignoredFiles: Bool
}

struct BrowsingBuildIdentity: Codable {
    let configuration: String
    let optimization: String
    let testabilityEnabled: Bool
    let compilerVersion: String
    let requestedSDKVersion: String
    let requestedSDKName: String
    /// The executable's Mach-O SDK stamp does not prove which SDK compiled its Swift modules.
    let linkedSDKVersion: String
    /// The compiled product before Demo signing seals launch.json into the bundle.
    let buildProductSHA256: String
}

struct BrowsingEngineIdentity: Codable {
    let selection: String
    let pinURL: String
    let pinChecksum: String
    let librarySHA256: String
    let canonicalHeadersSHA256: String
    let sourceRevision: String
    let engineInputDigest: String
    let librespotRevision: String
    let usedForPlayback: Bool
}

struct BrowsingExecutionConfiguration: Encodable {
    let configuration: String
    let optimization: String
    let debugCompilation: Bool
    let debugAssertionsEnabled: Bool
    let testabilityEnabled = true
    let harnessInstrumentationEnabled = true
    let playbackImplementation = "synthetic-no-audio"

    static var current: Self {
        #if SPOTTY_BROWSING_OPTIMIZED
            Self(
                configuration: "release", optimization: "-O", debugCompilation: false,
                debugAssertionsEnabled: _isDebugAssertConfiguration()
            )
        #else
            Self(
                configuration: "debug", optimization: "-Onone", debugCompilation: true,
                debugAssertionsEnabled: _isDebugAssertConfiguration()
            )
        #endif
    }
}
