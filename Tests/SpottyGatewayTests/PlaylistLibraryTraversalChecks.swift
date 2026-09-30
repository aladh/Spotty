import SpottyTestSupport
import Foundation
import SpottyDomain
import Synchronization
import Testing
@testable import SpottyGateway

@Suite("Playlist library traversal")
struct PlaylistLibraryTraversalTests {
    @Test
    func largeFolderLoadsInOneBoundedBatch() async throws {
        let calls = HarnessCounters()
        let folderURI = "spotify:user:fixture:folder:large"
        let entries = (0..<105).map { ("spotify:playlist:item\($0)", "Playlist \($0)") }
        let api = libraryAPI { request in
            calls.record("request")
            let variables = try libraryVariables(request)
            let limit = try #require(variables["limit"] as? Int)
            #expect((1...200).contains(limit), "startup batching must keep each request bounded")
            guard variables["folderUri"] as? String == folderURI else {
                return try libraryPage([(folderURI, "Large folder")], total: 1, request: request)
            }
            let offset = try #require(variables["offset"] as? Int)
            let page = Array(entries.dropFirst(offset).prefix(limit))
            return try libraryPage(page, total: entries.count, request: request)
        }

        let tree = try await api.playlistLibrary()
        #expect(tree.flatMap(\.playlists).map(\.title) == entries.map(\.1))
        #expect(calls.count("request") == 2, "one root request and one complete folder request")
    }

    @Test
    func customOrderAndNestedFoldersSurvivePagination() async throws {
        let api = libraryAPI { request in
            let variables = try libraryVariables(request)
            #expect(variables["order"] as? String == "Custom Order")
            #expect(variables["flatten"] as? Bool == false)
            let offset = variables["offset"] as? Int ?? 0
            let folder = variables["folderUri"] as? String
            let entries: [(String, String)]
            let total: Int
            switch (folder, offset) {
            case (nil, 0):
                entries = [("spotify:playlist:z", "Zulu"), ("spotify:user:fixture:folder:one", "Quick Lists")]
                total = 3
            case (nil, 2):
                entries = [("spotify:playlist:a", "Alpha")]
                total = 3
            case ("spotify:user:fixture:folder:one", 0):
                entries = [("spotify:playlist:child", "Child"), ("spotify:user:fixture:folder:two", "Nested")]
                total = 2
            case ("spotify:user:fixture:folder:two", 0):
                entries = [("spotify:playlist:deep", "Deep")]
                total = 1
            default:
                Issue.record("Unexpected library page")
                entries = []
                total = 0
            }
            return try libraryPage(entries, total: total, request: request)
        }
        let tree = try await api.playlistLibrary()
        #expect(tree.map(\.title) == ["Zulu", "Quick Lists", "Alpha"])
        #expect(tree.flatMap(\.playlists).map(\.title) == ["Zulu", "Child", "Deep", "Alpha"])

    }

    @Test
    func foldersLoadConcurrentlyWithABoundedSharedQueue() async throws {
        let gate = LibraryFolderGate()
        let api = libraryAPI { request in
            let variables = try libraryVariables(request)
            guard let folder = variables["folderUri"] as? String else {
                return try libraryPage(
                    (0..<7).map { ("spotify:user:fixture:folder:root-\($0)", "Folder \($0)") },
                    total: 7, request: request)
            }
            try await gate.enter(folder)
            let index = try #require(folder.split(separator: "-").last)
            let entry =
                folder.contains("root-")
                ? ("spotify:user:fixture:folder:nested-\(index)", "Nested \(index)")
                : ("spotify:playlist:child\(index)", "Child \(index)")
            return try libraryPage([entry], total: 1, request: request)
        }
        let load = Task { try await api.playlistLibrary() }
        defer {
            load.cancel()
            Task { await gate.releaseAll() }
        }
        try await requireEventually { await gate.entered.count == 4 }
        #expect(await gate.peakActive == 4)
        // Release out of order: the completed fourth folder must not move ahead of the first.
        await gate.release("spotify:user:fixture:folder:root-3")
        try await requireEventually { await gate.entered.count == 5 }
        await gate.releaseAll()
        let tree = try await load.value
        #expect(await gate.entered.count == 14)
        #expect(await gate.peakActive <= 4)
        #expect(tree.map(\.title) == (0..<7).map { "Folder \($0)" })
        #expect(tree.flatMap(\.playlists).map(\.title) == (0..<7).map { "Child \($0)" })
    }

    @Test
    func failedChildRequestFailsTheWholeTree() async throws {
        let api = libraryAPI { request in
            let variables = try libraryVariables(request)
            if variables["folderUri"] != nil { throw URLError(.notConnectedToInternet) }
            return try libraryPage(
                [("spotify:playlist:first", "First"), ("spotify:user:fixture:folder:one", "Folder")],
                total: 2, request: request)
        }
        do {
            _ = try await api.playlistLibrary()
            Issue.record("A failed folder must not return a partially populated tree")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
    }

    @Test
    func duplicateFolderReferencesFailBeforeSchedulingChildren() async throws {
        let calls = HarnessCounters()
        let folder = "spotify:user:fixture:folder:duplicate"
        let api = libraryAPI { request in
            let variables = try libraryVariables(request)
            if variables["folderUri"] != nil {
                calls.record("child")
                return try libraryPage([("spotify:playlist:child", "Child")], total: 1, request: request)
            }
            return try libraryPage([(folder, "First"), (folder, "Second")], total: 2, request: request)
        }
        await #expect(throws: PartnerAPIError.emptyPayload) { try await api.playlistLibrary() }
        #expect(calls.count("child") == 0, "Ambiguous folder identity must fail before duplicate network work")
    }

    @Test(arguments: [false, true])
    func repeatedFoldersAcrossPagesOrParentsCannotBeFetchedTwice(sharedParent: Bool) async throws {
        let calls = HarnessCounters()
        let shared = "spotify:user:fixture:folder:shared"
        let left = "spotify:user:fixture:folder:left"
        let right = "spotify:user:fixture:folder:right"
        let api = libraryAPI { request in
            let variables = try libraryVariables(request)
            if let folder = variables["folderUri"] as? String {
                if folder == shared {
                    calls.record("shared")
                    return try libraryPage([], total: 0, request: request)
                }
                return try libraryPage([(shared, "Shared")], total: 1, request: request)
            }
            if sharedParent {
                return try libraryPage([(left, "Left"), (right, "Right")], total: 2, request: request)
            }
            calls.record("page")
            return try libraryPage([(shared, "Shared")], total: 2, request: request)
        }
        await #expect(throws: PartnerAPIError.emptyPayload) { try await api.playlistLibrary() }
        #expect(calls.count("shared") <= (sharedParent ? 1 : 0))
        if !sharedParent { #expect(calls.count("page") == 2) }
    }

    @Test(arguments: [false, true])
    func aggregateRawEntryLimitIncludesUnavailableRows(unavailable: Bool) async throws {
        let calls = HarnessCounters()
        let api = libraryAPI { request in
            let variables = try libraryVariables(request)
            guard let folder = variables["folderUri"] as? String else {
                return try libraryPage(
                    [("spotify:folder:first", "First"), ("spotify:folder:second", "Second")], total: 2, request: request
                )
            }
            calls.record("page")
            let offset = try #require(variables["offset"] as? Int)
            let limit = try #require(variables["limit"] as? Int)
            let count = min(limit, 6_000 - offset)
            let entries = (offset..<(offset + count)).map {
                ("spotify:playlist:\(folder.split(separator: ":").last ?? "")-\($0)", "Playlist")
            }
            return try libraryPage(entries, total: 6_000, request: request, unavailable: unavailable)
        }
        await #expect(throws: PartnerAPIError.libraryLimitReached) { try await api.playlistLibrary() }
        // Two folders individually fit. Together they must stop at the shared raw-entry cap;
        // the other already-admitted page may finish while the group propagates the failure.
        #expect(calls.count("page") <= PlaylistLibraryLimits.maximumNodes / LibraryFilter.playlistPageLimit + 2)
    }

    @Test func exactlyTheEntryLimitRetainsTheCompleteTree() async throws {
        let perFolder = (PlaylistLibraryLimits.maximumNodes - 2) / 2
        let api = libraryAPI { request in
            let variables = try libraryVariables(request)
            guard let folder = variables["folderUri"] as? String else {
                return try libraryPage(
                    [("spotify:folder:first", "First"), ("spotify:folder:second", "Second")], total: 2, request: request
                )
            }
            let offset = try #require(variables["offset"] as? Int)
            let limit = try #require(variables["limit"] as? Int)
            let entries = (offset..<min(perFolder, offset + limit)).map {
                ("spotify:playlist:\(folder.split(separator: ":").last ?? "")-\($0)", "Playlist \($0)")
            }
            return try libraryPage(entries, total: perFolder, request: request)
        }
        let tree = try await api.playlistLibrary()
        #expect(tree.count == 2)
        #expect(tree.map { $0.children?.count } == [perFolder, perFolder])
        #expect(tree[0].children?.first?.title == "Playlist 0")
        #expect(tree[1].children?.last?.title == "Playlist \(perFolder - 1)")
    }

    @Test(arguments: [1, 2])
    func fragmentedFoldersShareOneLogicalPageBudget(folderCount: Int) async throws {
        let calls = HarnessCounters()
        let api = libraryAPI { request in
            calls.record("page")
            let variables = try libraryVariables(request)
            guard let folder = variables["folderUri"] as? String else {
                return try libraryPage(
                    (0..<folderCount).map { ("spotify:folder:\($0)", "Folder") },
                    total: folderCount, request: request)
            }
            let offset = try #require(variables["offset"] as? Int)
            return try libraryPage(
                [("spotify:playlist:\(folder.split(separator: ":").last ?? "")-\(offset)", "Playlist")],
                total: folderCount == 1 ? Pagination.maximumPageCount : 300, request: request)
        }
        await #expect(throws: PartnerAPIError.libraryLimitReached) { _ = try await api.playlistLibrary() }
        let dispatched = calls.count("page")
        // The root also spends one reservation. A single reader reaches the exact shared cap;
        // with two readers, failure may cancel the final reserved sibling before transport.
        #expect(dispatched <= Pagination.maximumPageCount)
        #expect(dispatched >= Pagination.maximumPageCount - (folderCount - 1))
    }

    @Test
    func cancelledReservedPageDoesNotReachTransport() async throws {
        let penultimateCredential = HarnessResponseGate<Void>()
        let lastCredential = HarnessResponseGate<Void>()
        // This ordinal must be assigned atomically; separate record/count calls could park
        // both concurrent readers. The gates own only the final two admitted credential requests.
        let admissions = Mutex(0)
        let calls = HarnessCounters()
        let api = libraryAPI(accessToken: {
            let ordinal = admissions.withLock { value in
                value += 1
                return value
            }
            guard ordinal <= Pagination.maximumPageCount else {
                Issue.record("A request exceeded the shared admission budget")
                throw GatewayFixtureFailure.unavailable
            }
            if ordinal == Pagination.maximumPageCount - 1 { try await penultimateCredential.wait() }
            if ordinal == Pagination.maximumPageCount { try await lastCredential.wait() }
            return "fixture-access"
        }) { request in
            calls.record("page")
            let variables = try libraryVariables(request)
            guard let folder = variables["folderUri"] as? String else {
                return try libraryPage(
                    [("spotify:folder:first", "First"), ("spotify:folder:second", "Second")],
                    total: 2, request: request)
            }
            let offset = try #require(variables["offset"] as? Int)
            // Neither reader can finish before the shared cap. Both final credential
            // requests park before either reader can attempt the refused reservation.
            return try libraryPage(
                [("spotify:playlist:\(folder.split(separator: ":").last ?? "")-\(offset)", "Playlist")],
                total: Pagination.maximumPageCount + 1, request: request)
        }
        let load = Task { _ = try await api.playlistLibrary() }
        defer {
            penultimateCredential.close()
            lastCredential.close()
            load.cancel()
        }
        do {
            try await requireEventually {
                penultimateCredential.waiterCount == 1 && lastCredential.waiterCount == 1
            }
            #expect(admissions.withLock { $0 } == Pagination.maximumPageCount)
            #expect(calls.count("page") == Pagination.maximumPageCount - 2)
            // Completing admission 499 lets its reader attempt 501. Admission 500 is
            // already parked, so budget failure must cancel and join it before transport.
            penultimateCredential.finish(())
            await #expect(throws: PartnerAPIError.libraryLimitReached) { _ = try await load.value }
            #expect(admissions.withLock { $0 } == Pagination.maximumPageCount)
            #expect(calls.count("page") == Pagination.maximumPageCount - 1)
            #expect(penultimateCredential.requestCount == 1)
            #expect(lastCredential.requestCount == 1)
            #expect(penultimateCredential.waiterCount == 0)
            #expect(lastCredential.waiterCount == 0, "The task group must join the cancelled credential owner")
        } catch {
            penultimateCredential.close()
            lastCredential.close()
            load.cancel()
            _ = try? await load.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func depthLimitAppliesToLeavesAndEmptyFolders(emptyLeaf: Bool) async throws {
        for depth in [PlaylistLibraryLimits.maximumDepth, PlaylistLibraryLimits.maximumDepth + 1] {
            let api = libraryAPI { request in
                let variables = try libraryVariables(request)
                let folder = variables["folderUri"] as? String
                let currentDepth = folder.flatMap { Int($0.split(separator: ":").last ?? "") }.map { $0 + 1 } ?? 0
                if currentDepth > depth { return try libraryPage([], total: 0, request: request) }
                let uri =
                    currentDepth < depth || emptyLeaf
                    ? "spotify:folder:\(currentDepth)" : "spotify:playlist:leaf"
                return try libraryPage([(uri, "Node \(currentDepth)")], total: 1, request: request)
            }
            if depth > PlaylistLibraryLimits.maximumDepth {
                await #expect(throws: PartnerAPIError.libraryLimitReached) { try await api.playlistLibrary() }
            } else {
                let tree = try await api.playlistLibrary()
                #expect(tree.count == 1)
                #expect(tree.flatMap(\.playlists).count == (emptyLeaf ? 0 : 1))
            }
        }
    }

    @Test(arguments: ["spotify:user::folder:bad", "other:user:fixture:folder:bad", "spotify:track:folder:bad"])
    func malformedFolderIdentityCannotStartAnotherRequest(uri: String) async throws {
        let calls = HarnessCounters()
        let api = libraryAPI { request in
            calls.record("request")
            return try libraryPage([(uri, "Invalid")], total: 1, request: request)
        }
        await #expect(throws: PartnerAPIError.emptyPayload) { try await api.playlistLibrary() }
        #expect(calls.count("request") == 1)
    }

    @Test(arguments: [false, true])
    func cancellationAndChildFailureDrainSiblings(cancel: Bool) async throws {
        let gate = LibraryFolderGate()
        let api = libraryAPI { request in
            let variables = try libraryVariables(request)
            guard let folder = variables["folderUri"] as? String else {
                return try libraryPage((0..<7).map { ("spotify:folder:\($0)", "Folder") }, total: 7, request: request)
            }
            try await gate.enter(folder)
            return try libraryPage([], total: 0, request: request)
        }
        let load = Task { try await api.playlistLibrary() }
        defer {
            load.cancel()
            Task { await gate.releaseAll() }
        }
        try await requireEventually { await gate.entered.count == 4 }
        if cancel {
            load.cancel()
            await #expect(throws: CancellationError.self) { try await load.value }
        } else {
            await gate.fail("spotify:folder:0")
            await #expect(throws: GatewayFixtureFailure.unavailable) { try await load.value }
        }
        #expect(await gate.activeCount == 0)
        #expect(await gate.entered.count == 4, "Failure must not admit the remaining folders")
    }

    @Test
    func cyclicFoldersFailInsteadOfPublishingAnIncompleteLibrary() async {
        let api = libraryAPI { request in
            try libraryPage([("spotify:user:fixture:folder:loop", "Loop")], total: 1, request: request)
        }
        do {
            _ = try await api.playlistLibrary()
            Issue.record("Cyclic folder response must fail")
        } catch {
            #expect(error as? PartnerAPIError == .emptyPayload)
        }
    }
}

private func libraryAPI(
    accessToken: @escaping @Sendable () async throws -> String = { "fixture-access" },
    transport: @escaping SpotifyCredentials.Transport
) -> PartnerAPI {
    PartnerAPI(
        accessToken: accessToken, clientToken: { "fixture-client" },
        invalidateAccessToken: { _ in }, invalidateClientToken: { _ in },
        transport: transport, retryTiming: .immediate
    )
}

private func libraryVariables(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    return try #require(body["variables"] as? [String: Any])
}

private func libraryPage(
    _ entries: [(String, String)], total: Int, request: URLRequest, unavailable: Bool = false
) throws -> (Data, URLResponse) {
    let items: [[String: Any]] = entries.map { uri, name in
        unavailable ? ["item": NSNull()] : ["item": ["data": ["uri": uri, "name": name]]]
    }
    let payload: [String: Any] = ["data": ["me": ["libraryV3": ["items": items, "totalCount": total]]]]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (data, response)
}

/// An out-of-order folder script with shared cancellation gates and concurrency accounting.
/// The URI-keyed responses and peak-active assertion require more than one anonymous gate.
private actor LibraryFolderGate {
    private(set) var entered: [String] = []
    private(set) var peakActive = 0
    private(set) var activeCount = 0
    private var open = false
    private var gates: [String: HarnessResponseGate<Void>] = [:]

    deinit { for gate in gates.values { gate.close() } }

    func enter(_ uri: String) async throws {
        entered.append(uri)
        activeCount += 1
        peakActive = max(peakActive, activeCount)
        defer { activeCount -= 1 }
        if !open {
            let gate = HarnessResponseGate<Void>()
            gates[uri] = gate
            defer { gates[uri] = nil }
            try await gate.wait()
        }
    }

    func release(_ uri: String) { gates[uri]?.finish(()) }
    func fail(_ uri: String) { gates[uri]?.resolve(.failure(GatewayFixtureFailure.unavailable)) }

    func releaseAll() {
        open = true
        for gate in gates.values { gate.finish(()) }
    }
}
