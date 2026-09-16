import SwiftUI

extension View {
    /// Re-admit visible catalog work when its resource or session readiness changes. Feature
    /// stores still own caching and request admission, including preparing retained content offline.
    @MainActor
    func catalogTask<Resource: Equatable>(
        id: Resource,
        playback: CatalogPlaybackAccess,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> some View {
        task(
            id: CatalogLoadIdentity(
                resource: id, accountEpoch: playback.accountEpoch, isConnected: playback.isConnected)
        ) {
            await action()
        }
    }
}

private struct CatalogLoadIdentity<Resource: Equatable>: Equatable {
    let resource: Resource
    let accountEpoch: UInt64
    let isConnected: Bool
}
