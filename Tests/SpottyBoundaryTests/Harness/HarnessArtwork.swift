import SpottyRuntimeContracts

/// Completions deliberately ignore cancellation so consumers must fence retired requests.
actor HarnessArtwork: ArtworkProviding {
    private(set) var requests: [ArtworkRequest] = []
    private var pending: [Int: CheckedContinuation<ArtworkAsset, Error>] = [:]

    func artwork(for request: ArtworkRequest) async throws -> ArtworkAsset {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func complete(_ index: Int, with result: Result<ArtworkAsset, Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }

    func activate(accountEpoch: UInt64) async {}
    func retire(accountEpoch: UInt64) async {}
}
