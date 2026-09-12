import Foundation

/// Account-stamped image requests cannot acquire bytes from a replacement account lifetime.
public struct ArtworkRequest: Hashable, Codable, Sendable {
    public let url: URL
    public let maximumPixelDimension: Int
    public let accountEpoch: UInt64

    public init(url: URL, maximumPixelDimension: Int, accountEpoch: UInt64) {
        self.url = url
        self.maximumPixelDimension = maximumPixelDimension
        self.accountEpoch = accountEpoch
    }
}

/// The header range retains Spotify's muted, dark artwork-derived tint.
public struct ArtworkTint: Equatable, Codable, Sendable {
    public let hue: Double
    public let saturation: Double
    public let brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

/// Encoded thumbnails support transport; immutable decoded pixels let native presentation avoid
/// image decompression on MainActor. The raster is 8-bit premultiplied RGBA in sRGB, tightly packed.
public struct ArtworkAsset: Codable, Sendable {
    public let encodedThumbnail: Data
    public let rgbaPixels: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let tint: ArtworkTint?

    public init(encodedThumbnail: Data, rgbaPixels: Data, pixelWidth: Int, pixelHeight: Int, tint: ArtworkTint?) {
        self.encodedThumbnail = encodedThumbnail
        self.rgbaPixels = rgbaPixels
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.tint = tint
    }

    public var byteCount: Int { encodedThumbnail.count + rgbaPixels.count }
}

public enum ArtworkFailure: Error, Equatable, Sendable {
    case retired
    case unsupportedURL
    case tooLarge
    case invalidImage
    case unavailable
    case overloaded
}

public protocol ArtworkProviding: Sendable {
    func artwork(for request: ArtworkRequest) async throws -> ArtworkAsset
    func activate(accountEpoch: UInt64) async
    func retire(accountEpoch: UInt64) async
}

/// Synthetic tests and previews do not construct a live loader unless they explicitly opt in.
public struct UnavailableArtworkProvider: ArtworkProviding {
    public init() {}
    public func artwork(for _: ArtworkRequest) async throws -> ArtworkAsset { throw ArtworkFailure.unavailable }
    public func activate(accountEpoch _: UInt64) async {}
    public func retire(accountEpoch _: UInt64) async {}
}
