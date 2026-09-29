import Foundation
import SpottyDomain
import SpottyRuntimeContracts

/// Owns one bounded query. Registration and retirement serialize independently of reads, so
/// an uncooperative cancelled read cannot hold capacity needed by a replacement query.
@MainActor
final class CatalogEntityObservation {
    private struct Membership {
        let versions: Set<UUID>
        let uris: Set<String>
    }

    private struct Request {
        let id = UUID()
        let uris: Set<String>
        let session: CatalogSessionSnapshot
        let apply: @MainActor ([String: CatalogTrackMetadata]) -> Void
    }

    private struct Installed {
        let requestID: UUID
        let token: CatalogEntitySubscriptionToken
    }

    private enum RegistrationAction {
        case retire(CatalogEntitySubscriptionToken)
        case subscribe(Request)
    }

    private let provider: (any CatalogEntityQueryProviding)?
    private let session: CatalogSessionAvailability
    private var membership: Membership?
    private var desired: Request?
    private var installed: Installed?
    private var registrationTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?

    init(provider: any CatalogProviding, session: CatalogSessionAvailability) {
        self.provider = provider as? any CatalogEntityQueryProviding
        self.session = session
    }

    isolated deinit {
        consumerTask?.cancel()
        if let provider, let token = installed?.token {
            Task { await provider.unsubscribeCatalogEntities(token) }
        }
        // The registration worker owns any token currently crossing an await. It must finish
        // retiring that token, including a registration returned after this owner is gone.
    }

    func reset() {
        membership = nil
        desired = nil
        consumerTask?.cancel()
        consumerTask = nil
        reconcileRegistration()
    }

    func update(
        collections: [CatalogTrackCollection], apply: @escaping @MainActor ([String: CatalogTrackMetadata]) -> Void
    ) {
        guard provider != nil, session.isAvailable else {
            reset()
            return
        }
        let bounded = requestedURIs(in: collections)
        guard !bounded.isEmpty else {
            reset()
            return
        }
        guard desired?.uris != bounded || desired?.session != session.snapshot else { return }
        consumerTask?.cancel()
        consumerTask = nil
        desired = Request(uris: bounded, session: session.snapshot, apply: apply)
        reconcileRegistration()
    }

    /// Versions identify immutable collection values, not query authority. A cache hit must
    /// still pass through admission above so a failed query can retry or a session can change.
    /// Keep only the bounded URI set; never retain track rows or historical membership entries.
    private func requestedURIs(in collections: [CatalogTrackCollection]) -> Set<String> {
        let versions = Set(collections.map(\.version))
        if let membership, membership.versions == versions { return membership.uris }
        var remaining = versions
        var uris = Set<String>()
        for collection in collections where remaining.remove(collection.version) != nil {
            uris.formUnion(collection.tracks.lazy.map(\.uri))
        }
        let limit = CatalogEntityQueryLimits.maximumRequestedURIs
        var bounded = uris.count <= limit ? uris : Set(uris.sorted().prefix(limit))
        // Enrichment changes display versions without changing membership. Share the existing
        // set with the active request and preserve that request's read/acknowledgement lifetime.
        if let previous = membership?.uris, previous == bounded { bounded = previous }
        membership = Membership(versions: versions, uris: bounded)
        return bounded
    }

    private func reconcileRegistration() {
        guard registrationTask == nil, let provider else { return }
        registrationTask = Task { [weak self] in
            while let action = self?.nextRegistrationAction() {
                switch action {
                case let .retire(token):
                    await provider.unsubscribeCatalogEntities(token)
                case let .subscribe(request):
                    do {
                        let subscription = try await provider.subscribeCatalogEntities(request.uris)
                        if self?.install(subscription, for: request) != true {
                            await provider.unsubscribeCatalogEntities(subscription.token)
                        }
                    } catch {
                        self?.finish(request.id)
                    }
                }
            }
        }
    }

    private func nextRegistrationAction() -> RegistrationAction? {
        if let installed, installed.requestID != desired?.id {
            self.installed = nil
            return .retire(installed.token)
        }
        if installed == nil, let desired { return .subscribe(desired) }
        registrationTask = nil
        return nil
    }

    private func install(_ subscription: CatalogEntitySubscription, for request: Request) -> Bool {
        guard desired?.id == request.id else { return false }
        guard session.isAvailable, session.snapshot == request.session else {
            desired = nil
            return false
        }
        installed = Installed(requestID: request.id, token: subscription.token)
        guard let provider else { return false }
        consumerTask = Task { [weak self] in
            await Self.consume(provider, subscription: subscription, request: request) { [weak self] in
                self?.isCurrent(request) == true
            }
            self?.finish(request.id)
        }
        return true
    }

    private func isCurrent(_ request: Request) -> Bool {
        !Task.isCancelled && desired?.id == request.id && installed?.requestID == request.id
            && session.isAvailable && session.snapshot == request.session
    }

    private func finish(_ requestID: UUID) {
        guard desired?.id == requestID else { return }
        desired = nil
        consumerTask = nil
        reconcileRegistration()
    }

    private static func consume(
        _ provider: any CatalogEntityQueryProviding, subscription: CatalogEntitySubscription, request: Request,
        isCurrent: @MainActor () -> Bool
    ) async {
        var appliedRevision: UInt64?
        for await change in subscription.updates {
            guard isCurrent() else { break }
            guard change.token == subscription.token,
                appliedRevision.map({ change.revision > $0 }) ?? true
            else { continue }
            // Superseded reads receive another accumulated change. Other failures retire this
            // query; a later explicit update can retry without an automatic failure loop.
            let entities: [String: CatalogTrackMetadata]
            do {
                entities = try await provider.catalogEntities(for: change)
            } catch CatalogEntityQueryFailure.superseded {
                continue
            } catch {
                break
            }
            guard isCurrent() else { break }
            guard entities.count <= request.uris.count,
                entities.allSatisfy({ request.uris.contains($0.key) && $0.value.uri == $0.key })
            else { break }
            request.apply(entities)
            guard isCurrent() else { break }
            appliedRevision = change.revision
            await provider.acknowledgeCatalogEntities(subscription.token, revision: change.revision)
            guard isCurrent() else { break }
        }
    }
}
