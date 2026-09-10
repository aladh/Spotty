import Darwin
import Foundation

/// App-private session storage for releases without a stable Apple signing identity.
/// This is deliberately not encrypted: other processes running as this user can read it.
/// Directory-relative operations reject symlinks and publish complete grants atomically.
nonisolated struct KeymasterFileStore: KeymasterTokenStoring {
    private static let filename = "session.json"
    private static let maximumBytes = 65_536
    let directory: URL

    private static let temporary = ".session.pending"
    private let clearLegacyGrant: @Sendable () -> Void

    init() {
        self.init(
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Spotty/Session", isDirectory: true),
            clearLegacyGrant: { UserDefaults.standard.removeObject(forKey: "keymaster.tokens.v1") })
    }

    init(directory: URL, clearLegacyGrant: @escaping @Sendable () -> Void = {}) {
        self.directory = directory
        self.clearLegacyGrant = clearLegacyGrant
    }

    func loadResult() -> KeymasterGrantLoadResult {
        clearLegacyGrant()
        do {
            let parent = try openDirectory(create: false)
            defer { close(parent) }
            let file = openat(parent, Self.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw StoreError.system(errno) }
            defer { close(file) }
            var info = stat()
            guard fstat(file, &info) == 0 else { throw StoreError.system(errno) }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                info.st_size > 0, info.st_size <= Self.maximumBytes
            else { throw StoreError.invalidFile }
            guard fchmod(file, 0o600) == 0 else { throw StoreError.system(errno) }
            var bytes = [UInt8](repeating: 0, count: Self.maximumBytes + 1)
            let count = try bytes.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = read(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw StoreError.system(errno)
                    }
                    if count == 0 { break }
                    offset += count
                }
                return offset
            }
            guard count <= Self.maximumBytes,
                let tokens = KeymasterStoredGrantCodec.decode(Data(bytes.prefix(count)))
            else { throw StoreError.invalidFile }
            return .found(tokens)
        } catch StoreError.system(ENOENT) {
            return .absent
        } catch StoreError.system(EACCES), StoreError.system(EPERM) {
            SpottyLog.authentication.error("\(KeymasterGrantPersistenceDiagnostics.deniedGrant, privacy: .public)")
            return .denied
        } catch {
            SpottyLog.authentication.error("\(KeymasterGrantPersistenceDiagnostics.failedGrant, privacy: .public)")
            return .failed
        }
    }

    func save(_ tokens: KeymasterTokens) throws {
        clearLegacyGrant()
        let data = try JSONEncoder().encode(tokens)
        guard data.count <= Self.maximumBytes else { throw StoreError.invalidFile }
        let parent = try openDirectory(create: true)
        defer { close(parent) }
        let temporary = Self.temporary
        let file = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw StoreError.system(errno) }
        defer {
            close(file)
            unlinkat(parent, temporary, 0)
        }
        guard fchmod(file, 0o600) == 0 else { throw StoreError.system(errno) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.system(errno)
                }
                guard count > 0 else { throw StoreError.invalidFile }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw StoreError.system(errno) }
        guard renameat(parent, temporary, parent, Self.filename) == 0 else { throw StoreError.system(errno) }
        guard fsync(parent) == 0 else { throw StoreError.system(errno) }
    }

    func clear() {
        clearLegacyGrant()
        do {
            let parent = try openDirectory(create: false)
            defer { close(parent) }
            guard unlinkat(parent, Self.filename, 0) == 0 || errno == ENOENT else {
                throw StoreError.system(errno)
            }
            guard fsync(parent) == 0 else { throw StoreError.system(errno) }
        } catch StoreError.system(ENOENT) {
            return
        } catch {
            SpottyLog.authentication.error("Stored grant removal failed source=file")
        }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        // Walk from root using directory descriptors: O_NOFOLLOW on only the final
        // component would still permit a symlinked Spotty parent to redirect writes.
        guard directory.isFileURL, !directory.pathComponents.contains("..") else { throw StoreError.invalidFile }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw StoreError.system(errno) }
        do {
            for component in directory.pathComponents.dropFirst() {
                if create, mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST {
                    throw StoreError.system(errno)
                }
                let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw StoreError.system(errno) }
                close(descriptor)
                descriptor = child
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw StoreError.system(errno) }
            guard info.st_uid == geteuid() else { throw StoreError.system(EACCES) }
            guard fchmod(descriptor, 0o700) == 0 else { throw StoreError.system(errno) }
            // Serialize store instances/processes before reclaiming a crash-orphaned
            // staging file. A live writer cannot lose its staging name to cleanup.
            guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.system(errno) }
            guard unlinkat(descriptor, Self.temporary, 0) == 0 || errno == ENOENT else {
                throw StoreError.system(errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private enum StoreError: Error {
        case system(Int32)
        case invalidFile
    }
}
