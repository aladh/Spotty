import SpottyRuntimeContracts
import SwiftUI

/// A small tint request shares source bytes and account retirement with displayed artwork.
enum ArtworkDominantColor {
    static func load(from url: URL?, using artwork: ArtworkAccess) async throws -> Color? {
        guard let url else { return nil }
        do {
            let asset = try await artwork.provider.artwork(
                for: ArtworkRequest(url: url, maximumPixelDimension: 64, accountEpoch: artwork.accountEpoch))
            try Task.checkCancellation()
            return asset.tint.map { Color(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }
}
