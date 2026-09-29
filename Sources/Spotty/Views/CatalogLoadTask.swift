import SpottyDomain
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
        let session = playback.catalogSessionSnapshot
        return task(id: CatalogLoadIdentity(resource: id, session: session)) {
            guard let session, playback.catalogSessionSnapshot == session else { return }
            await action()
        }
    }
}

private struct CatalogLoadIdentity<Resource: Equatable>: Equatable {
    let resource: Resource
    let session: CatalogSessionSnapshot?
}
