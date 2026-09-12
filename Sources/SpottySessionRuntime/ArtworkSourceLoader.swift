import Foundation
import SpottyRuntimeContracts

protocol ArtworkSourceLoading: Sendable {
    func load(_ url: URL) async throws -> Data
    func cancelAll() async
}

/// No shared response cache, authentication state or disk cache participates in artwork loads.
actor ArtworkSourceLoader: ArtworkSourceLoading {
    private let maximumSourceBytes: Int
    private let allowFileURLs: Bool
    private var generation: UInt64 = 0
    private var session: URLSession
    private var fileReads: [UUID: Task<Data, any Error>] = [:]

    init(maximumSourceBytes: Int = 8 * 1_024 * 1_024, allowFileURLs: Bool = false) {
        precondition(maximumSourceBytes > 0 && maximumSourceBytes < Int.max)
        self.maximumSourceBytes = maximumSourceBytes
        self.allowFileURLs = allowFileURLs
        session = Self.makeSession()
    }

    func load(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let stamp = generation
        if url.isFileURL {
            guard allowFileURLs else { throw ArtworkFailure.unsupportedURL }
            let limit = maximumSourceBytes
            let id = UUID()
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { throw ArtworkFailure.unsupportedURL }
                if let size = values.fileSize, size > limit { throw ArtworkFailure.tooLarge }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: limit + 1) ?? Data()
                try Task.checkCancellation()
                guard data.count <= limit else { throw ArtworkFailure.tooLarge }
                return data
            }
            fileReads[id] = task
            defer { fileReads[id] = nil }
            let data = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard generation == stamp else { throw CancellationError() }
            return data
        }
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw ArtworkFailure.unsupportedURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ArtworkFailure.unavailable
        }
        guard response.expectedContentLength <= maximumSourceBytes else { throw ArtworkFailure.tooLarge }
        var data = Data()
        data.reserveCapacity(min(maximumSourceBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard generation == stamp else { throw CancellationError() }
            guard data.count < maximumSourceBytes else { throw ArtworkFailure.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard generation == stamp else { throw CancellationError() }
        return data
    }

    func cancelAll() {
        generation &+= 1
        fileReads.values.forEach { $0.cancel() }
        fileReads.removeAll()
        session.invalidateAndCancel()
        session = Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: ArtworkRedirectPolicy(), delegateQueue: nil)
    }
}

private final class ArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https", request.url?.user == nil, request.url?.password == nil
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
