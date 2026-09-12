import Foundation

/// Offset arithmetic and the bounded walk policy for paged Spotify endpoints.
///
/// `nextOffset` is the page-to-page step. `collect` is the walk: it latches the first reported
/// `totalCount`, concatenates decoded items in request order, and refuses to continue when a
/// page does not advance the offset or when `maximumPageCount` pages still name a further
/// request. Missing `totalCount` still ends on an empty page; an endpoint that ignores `offset`
/// cannot loop or allocate without bound.
public enum Pagination {
    /// Hard cap on `fetchPage` invocations for one walk. A 2,500-song library at 50 items
    /// per page is 50 requests; 500 pages covers 25,000 library rows or 150,000 playlist
    /// rows at the current Partner API page sizes.
    public static let maximumPageCount = 500

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        /// `maximumPageCount` pages were fetched and the walk still named another offset.
        case pageLimitReached
        /// The next offset repeats or does not move forward, so another fetch would not progress.
        case offsetDidNotAdvance
        /// A page ended before the collection's reported total was reached.
        case incompleteCollection

        public var errorDescription: String? {
            switch self {
            case .pageLimitReached:
                "Spotify pagination exceeded the request limit"
            case .offsetDidNotAdvance:
                "Spotify pagination did not advance"
            case .incompleteCollection:
                "Spotify returned an incomplete collection"
            }
        }
    }

    public struct Page<Item: Sendable>: Sendable {
        public let items: [Item]
        public let pageEntryCount: Int
        public let totalCount: Int?

        public init(items: [Item], pageEntryCount: Int, totalCount: Int?) {
            self.items = items
            self.pageEntryCount = pageEntryCount
            self.totalCount = totalCount
        }
    }

    public enum Decision: Equatable, Sendable {
        case finished
        case fetch(offset: Int)
        case failed(Failure)
    }

    public static func nextOffset(offset: Int, pageEntryCount: Int, totalCount: Int?) -> Int? {
        guard pageEntryCount > 0 else { return nil }
        let fetched = offset + pageEntryCount
        if let totalCount, fetched >= totalCount { return nil }
        return fetched
    }

    /// After consuming the page fetched at `offset`, decide whether to stop, continue, or fail.
    ///
    /// `pagesFetched` counts the page just consumed. `requestedOffsets` are offsets already
    /// fetched on this walk, including `offset`, so a next offset that repeats is a failure
    /// rather than another request.
    public static func decision(
        offset: Int,
        pageEntryCount: Int,
        totalCount: Int?,
        pagesFetched: Int,
        requestedOffsets: Set<Int> = [],
        maximumPageCount: Int = maximumPageCount,
        nextOffset: @Sendable (Int, Int, Int?) -> Int? = {
            Pagination.nextOffset(offset: $0, pageEntryCount: $1, totalCount: $2)
        }
    ) -> Decision {
        if pageEntryCount == 0, let totalCount, offset < totalCount {
            return .failed(.incompleteCollection)
        }
        guard let next = nextOffset(offset, pageEntryCount, totalCount) else {
            return .finished
        }
        guard next > offset, !requestedOffsets.contains(next) else {
            return .failed(.offsetDidNotAdvance)
        }
        guard pagesFetched < maximumPageCount else {
            return .failed(.pageLimitReached)
        }
        return .fetch(offset: next)
    }

    /// Walks `fetchPage` from offset 0 until `decision` finishes or fails.
    ///
    /// `nextOffset` defaults to `Pagination.nextOffset`. Checks may pass a non-advancing
    /// function to cover a stuck offset without a live endpoint. `firstPage`, when present,
    /// is the offset-0 page so a caller that already fetched the header does not capture
    /// mutable walk state in `fetchPage`.
    public static func collect<Item: Sendable>(
        maximumPageCount: Int = maximumPageCount,
        firstPage: Page<Item>? = nil,
        nextOffset: @Sendable (Int, Int, Int?) -> Int? = {
            Pagination.nextOffset(offset: $0, pageEntryCount: $1, totalCount: $2)
        },
        fetchPage: @Sendable (Int) async throws -> Page<Item>
    ) async throws -> [Item] {
        guard maximumPageCount > 0 else {
            throw Failure.pageLimitReached
        }

        var items: [Item] = []
        var requestedOffsets: Set<Int> = []
        var pagesFetched = 0
        var total: Int?

        func consume(_ page: Page<Item>, offset: Int) throws -> Int? {
            requestedOffsets.insert(offset)
            pagesFetched += 1
            if total == nil {
                total = page.totalCount
            }
            items += page.items
            switch decision(
                offset: offset,
                pageEntryCount: page.pageEntryCount,
                totalCount: total,
                pagesFetched: pagesFetched,
                requestedOffsets: requestedOffsets,
                maximumPageCount: maximumPageCount,
                nextOffset: nextOffset
            ) {
            case .finished:
                return nil
            case let .fetch(next):
                return next
            case let .failed(failure):
                throw failure
            }
        }

        try Task.checkCancellation()
        let first: Page<Item>
        if let firstPage {
            first = firstPage
        } else {
            first = try await fetchPage(0)
        }
        try Task.checkCancellation()
        guard var offset = try consume(first, offset: 0) else {
            return items
        }

        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(offset)
            try Task.checkCancellation()
            guard let next = try consume(page, offset: offset) else {
                return items
            }
            offset = next
        }
    }
}

public enum SpotifyURI {
    public static func id(from uri: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count >= 3, parts[0] == "spotify", let last = parts.last, !last.isEmpty else {
            return nil
        }
        return String(last)
    }

    public static func id(from uri: String, kind: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == kind, !parts[2].isEmpty else {
            return nil
        }
        return String(parts[2])
    }
}

/// Pulls the query out of an HTTP request line without opening a socket.
///
/// The listener is registered for `http://127.0.0.1:<port>/login`. Only that origin-form
/// target is accepted, so `GET /` or a lookalike path cannot consume the one-shot callback.
public enum LoopbackRequestParser {
    public static let callbackPath = "/login"

    public static func parseRequestLine(_ request: String) -> URLComponents? {
        guard let line = firstRequestLine(request) else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET" else { return nil }
        guard isHTTPVersion(parts[2]) else { return nil }
        return parseOriginFormCallbackTarget(String(parts[1]))
    }

    /// RFC 9112 `HTTP-version`: `HTTP/` plus ASCII DIGIT major, optionally `.` minor.
    static func isHTTPVersion(_ token: Substring) -> Bool {
        guard token.hasPrefix("HTTP/") else { return false }
        let version = token.dropFirst(5)
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) }
        }
    }

    /// First HTTP request-line, without a CR, LF, or CRLF terminator.
    ///
    /// Swift treats CRLF as a single `Character`, so this walks Unicode scalars. Empty or
    /// terminator-only input is malformed.
    public static func firstRequestLine(_ request: String) -> String? {
        let scalars = request.unicodeScalars
        var end = scalars.startIndex
        while end != scalars.endIndex {
            let scalar = scalars[end]
            if scalar == "\r" || scalar == "\n" { break }
            end = scalars.index(after: end)
        }
        let line = String(scalars[scalars.startIndex..<end])
        return line.isEmpty ? nil : line
    }

    /// Origin-form request-target that names exactly `/login` after percent-decoding.
    public static func parseOriginFormCallbackTarget(_ target: String) -> URLComponents? {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("://") else {
            return nil
        }
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            return nil
        }
        guard components.scheme == "http",
            components.host == "127.0.0.1",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.fragment == nil,
            components.path == callbackPath
        else {
            return nil
        }
        return components
    }
}
