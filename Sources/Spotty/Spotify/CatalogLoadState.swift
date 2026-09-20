import SpottyRuntimeContracts

/// Presentation transitions shared by catalog stores. Request identity and cancellation remain
/// AccountScopedSingleFlight-owned; stores apply these transitions only after its publish gate.
nonisolated struct CatalogLoadState {
    struct Content {
        let session: CatalogSessionSnapshot?
        let freshness: CatalogFreshness
        var needsRefresh: Bool
    }

    enum Phase {
        case idle
        case loading(Content?, previousError: String?)
        case loaded(Content)
        case failed(Content?, message: String)
        case credentialsRefused(message: String)
    }

    private(set) var phase: Phase = .idle

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var hasSettled: Bool {
        switch phase {
        case .loaded, .failed, .credentialsRefused: true
        case .idle, .loading: false
        }
    }

    var content: Content? {
        switch phase {
        case let .loading(content, _), let .failed(content, _): content
        case let .loaded(content): content
        case .idle, .credentialsRefused: nil
        }
    }

    var hasContent: Bool { content != nil }
    var freshness: CatalogFreshness { content?.freshness ?? .current }
    var session: CatalogSessionSnapshot? { content?.session }
    var error: String? {
        switch phase {
        case let .loading(_, message): message
        case let .failed(_, message), let .credentialsRefused(message): message
        case .idle, .loaded: nil
        }
    }

    func isCurrent(in session: CatalogSessionSnapshot) -> Bool {
        guard case let .loaded(content) = phase else { return false }
        return session.isAvailable && content.session == session
            && content.freshness.isCurrent && !content.needsRefresh
    }

    func isShowingSavedContent(in session: CatalogSessionSnapshot) -> Bool {
        hasContent && !isCurrent(in: session)
    }

    mutating func begin(keepPreviousError: Bool = true) {
        var retained = content
        retained?.needsRefresh = true
        phase = .loading(retained, previousError: keepPreviousError && hasContent ? error : nil)
    }

    /// A saved result may arrive while its live refresh is still running. Receiving content
    /// must not finish that request or make historical ownership current.
    mutating func receive(session: CatalogSessionSnapshot?, freshness: CatalogFreshness = .current) {
        let content = Content(session: session, freshness: freshness, needsRefresh: session == nil)
        phase = isLoading ? .loading(content, previousError: nil) : .loaded(content)
    }

    mutating func restore(
        session: CatalogSessionSnapshot?, freshness: CatalogFreshness,
        needsRefresh: Bool = false, error: String? = nil
    ) {
        let content = Content(session: session, freshness: freshness, needsRefresh: needsRefresh || session == nil)
        phase = error.map { .failed(content, message: $0) } ?? .loaded(content)
    }

    mutating func markStale() {
        guard var retained = content else { return }
        retained.needsRefresh = true
        switch phase {
        case .loading: phase = .loading(retained, previousError: error)
        case let .failed(_, message): phase = .failed(retained, message: message)
        case .loaded: phase = .loaded(retained)
        case .idle, .credentialsRefused: break
        }
    }

    mutating func finish() {
        guard case let .loading(content, error) = phase else { return }
        if let error {
            phase = .failed(content, message: error)
        } else {
            phase = content.map(Phase.loaded) ?? .idle
        }
    }

    /// Returns whether the store must retire its data, retained routes, and suspended work.
    /// Credential refusal is terminal even when the surrounding session has not updated yet.
    @discardableResult
    mutating func fail(_ error: any Error) -> Bool {
        let message = CatalogErrorPresentation.message(for: error)
        if error as? CatalogReadFailure == .sessionExpired {
            phase = .credentialsRefused(message: message)
            return true
        }
        fail(message: message)
        return false
    }

    mutating func fail(message: String) {
        var retained = content
        retained?.needsRefresh = true
        phase = .failed(retained, message: message)
    }
}
