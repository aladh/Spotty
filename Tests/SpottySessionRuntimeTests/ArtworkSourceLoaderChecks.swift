import Foundation
import os
import SpottyRuntimeContracts
import Testing
@testable import SpottySessionRuntime

@Suite("Bounded artwork source transfers")
struct ArtworkSourceLoaderTests {
    @Test func chunkedBodySucceedsAtTheExactLimitWithoutContentLength() async throws {
        let fixture = ArtworkHTTPFixture()
        defer { fixture.remove() }
        let loader = ArtworkSourceLoader(maximumSourceBytes: 128 * 1_024, protocolClasses: [ArtworkHTTPProtocol.self])
        let loading = Task { try await loader.load(fixture.url) }
        #expect(await waitForArtworkTransfer { fixture.started })
        fixture.send(Data(repeating: 1, count: 64 * 1_024))
        fixture.send(Data(repeating: 2, count: 64 * 1_024))
        fixture.finish()

        let data = try await loading.value
        #expect(data.count == 128 * 1_024)
        #expect(data.prefix(64 * 1_024).allSatisfy { $0 == 1 })
        #expect(data.suffix(64 * 1_024).allSatisfy { $0 == 2 })
        #expect(fixture.request?.httpShouldHandleCookies == false)
        #expect(fixture.request?.cachePolicy == .reloadIgnoringLocalCacheData)
        await loader.cancelAll()
    }

    @Test(arguments: [nil, 4])
    func oversizedStreamStopsBeforeCompletionDespiteMissingOrFalseLength(contentLength: Int?) async {
        let fixture = ArtworkHTTPFixture(contentLength: contentLength)
        defer { fixture.remove() }
        let loader = ArtworkSourceLoader(maximumSourceBytes: 8, protocolClasses: [ArtworkHTTPProtocol.self])
        let loading = Task { try await loader.load(fixture.url) }
        #expect(await waitForArtworkTransfer { fixture.started })
        fixture.send(Data(repeating: 1, count: 8))
        // CFNetwork may coalesce a tiny custom-protocol body before calling the delegate.
        // Force delivery while retaining the eight-byte application buffer limit.
        fixture.send(Data(repeating: 2, count: 64 * 1_024))
        // No finish signal is sent. A whole-response download with a post hoc cap would hang.
        await #expect(throws: ArtworkFailure.tooLarge) { try await loading.value }
        #expect(await waitForArtworkTransfer { fixture.stopped })
        await loader.cancelAll()
    }

    @Test func declaredOversizeCancelsBeforeAcceptingTheBody() async {
        let fixture = ArtworkHTTPFixture(contentLength: 8 * 1_024 * 1_024 + 1)
        defer { fixture.remove() }
        let loader = ArtworkSourceLoader(protocolClasses: [ArtworkHTTPProtocol.self])
        let loading = Task { try await loader.load(fixture.url) }
        #expect(await waitForArtworkTransfer { fixture.started })
        // This probe is below the source limit and has no end signal. Only the declared
        // oversized length can reject it; CFNetwork need not deliver header-only fixtures.
        fixture.send(Data(repeating: 1, count: 64 * 1_024))
        await #expect(throws: ArtworkFailure.tooLarge) { try await loading.value }
        #expect(await waitForArtworkTransfer { fixture.stopped })
        await loader.cancelAll()
    }

    @Test func cancellationStopsPendingTransferAndLoaderAcceptsAReplacement() async throws {
        let first = ArtworkHTTPFixture()
        let second = ArtworkHTTPFixture()
        defer { first.remove(); second.remove() }
        let loader = ArtworkSourceLoader(maximumSourceBytes: 8, protocolClasses: [ArtworkHTTPProtocol.self])
        let canceled = Task { try await loader.load(first.url) }
        #expect(await waitForArtworkTransfer { first.started })
        first.send(Data([1, 2]))
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(await waitForArtworkTransfer { first.stopped })

        let replacement = Task { try await loader.load(second.url) }
        #expect(await waitForArtworkTransfer { second.started })
        second.send(Data([3, 4]))
        second.finish()
        #expect(try await replacement.value == Data([3, 4]))
        await loader.cancelAll()
    }

    @Test func retirementCancelsEveryOldTransferWithoutAffectingTheReplacement() async throws {
        let old = ArtworkHTTPFixture()
        let alsoOld = ArtworkHTTPFixture()
        let current = ArtworkHTTPFixture()
        defer { old.remove(); alsoOld.remove(); current.remove() }
        let loader = ArtworkSourceLoader(maximumSourceBytes: 8, protocolClasses: [ArtworkHTTPProtocol.self])
        let oldLoading = Task { try await loader.load(old.url) }
        let alsoOldLoading = Task { try await loader.load(alsoOld.url) }
        #expect(await waitForArtworkTransfer { old.started })
        #expect(await waitForArtworkTransfer { alsoOld.started })
        old.send(Data([1]))
        await loader.cancelAll()
        await #expect(throws: CancellationError.self) { try await oldLoading.value }
        await #expect(throws: CancellationError.self) { try await alsoOldLoading.value }
        #expect(await waitForArtworkTransfer { old.stopped })
        #expect(await waitForArtworkTransfer { alsoOld.stopped })

        let currentLoading = Task { try await loader.load(current.url) }
        #expect(await waitForArtworkTransfer { current.started })
        current.send(Data([2]))
        current.finish()
        #expect(try await currentLoading.value == Data([2]))
        await loader.cancelAll()
    }

    @Test func failedHTTPStatusNeverAdmitsItsBody() async {
        let fixture = ArtworkHTTPFixture(status: 503)
        defer { fixture.remove() }
        let loader = ArtworkSourceLoader(protocolClasses: [ArtworkHTTPProtocol.self])
        let loading = Task { try await loader.load(fixture.url) }
        #expect(await waitForArtworkTransfer { fixture.started })
        fixture.send(Data(repeating: 1, count: 64 * 1_024))
        await #expect(throws: ArtworkFailure.unavailable) { try await loading.value }
        #expect(await waitForArtworkTransfer { fixture.stopped })
        await loader.cancelAll()
    }
}

private final class ArtworkHTTPFixture: Sendable {
    private struct State: Sendable {
        var source: ArtworkHTTPProtocol?
        var request: URLRequest?
        var started = false
        var stopped = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let url: URL
    let contentLength: Int?
    let status: Int

    init(contentLength: Int? = nil, status: Int = 200) {
        url = URL(string: "https://artwork-fixtures.invalid/\(UUID().uuidString)")!
        self.contentLength = contentLength
        self.status = status
        ArtworkHTTPProtocol.fixtures.withLock { $0[url] = self }
    }

    var started: Bool { state.withLock { $0.started } }
    var stopped: Bool { state.withLock { $0.stopped } }
    var request: URLRequest? { state.withLock { $0.request } }

    func start(_ source: ArtworkHTTPProtocol) {
        state.withLock {
            $0.source = source
            $0.request = source.request
        }
        var headers = ["Content-Type": "application/octet-stream", "X-Content-Type-Options": "nosniff"]
        if let contentLength { headers["Content-Length"] = String(contentLength) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        source.client?.urlProtocol(source, didReceive: response, cacheStoragePolicy: .notAllowed)
        state.withLock { $0.started = true }
    }

    func send(_ data: Data) {
        let source = state.withLock { !$0.stopped ? $0.source : nil }
        if let source { source.client?.urlProtocol(source, didLoad: data) }
    }

    func finish() {
        let source = state.withLock { !$0.stopped ? $0.source : nil }
        if let source { source.client?.urlProtocolDidFinishLoading(source) }
    }

    func stop() { state.withLock { $0.stopped = true } }
    func remove() { ArtworkHTTPProtocol.fixtures.withLock { $0[url] = nil } }
}

private final class ArtworkHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = OSAllocatedUnfairLock(initialState: [URL: ArtworkHTTPFixture]())

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "artwork-fixtures.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.fixtures.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        fixture.start(self)
    }
    override func stopLoading() {
        if let url = request.url { Self.fixtures.withLock { $0[url] }?.stop() }
    }
}

private func waitForArtworkTransfer(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if predicate() { return true }
        await Task.yield()
    }
    return false
}
