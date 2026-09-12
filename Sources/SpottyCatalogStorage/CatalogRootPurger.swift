import Darwin
import Foundation

/// Stable root coordination inode; never removed while account owners can still reference it.
final class CatalogDirectoryLock {
    private var descriptor: Int32 = -1

    init(rootDirectory: URL, exclusive: Bool) throws {
        let file = rootDirectory.appendingPathComponent("catalog-ownership.lock")
        descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        do {
            guard descriptor >= 0 else { throw CatalogStorageError.unsafeStorageLocation }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                fchmod(descriptor, 0o600) == 0
            else { throw CatalogStorageError.unsafeStorageLocation }
            guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
                throw CatalogStorageError.accountInUse
            }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    private func close() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}

actor CatalogRootPurger {
    static let shared = CatalogRootPurger()

    func purge(rootDirectory: URL) throws {
        guard rootDirectory.isFileURL else { throw CatalogStorageError.unsafeStorageLocation }
        var status = stat()
        if lstat(rootDirectory.path, &status) != 0 {
            guard errno == ENOENT else { throw CatalogStorageError.filesystem }
            return
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { throw CatalogStorageError.unsafeStorageLocation }
        let lock = try CatalogDirectoryLock(rootDirectory: rootDirectory, exclusive: true)
        try withExtendedLifetime(lock) {
            let entries = try FileManager.default.contentsOfDirectory(
                at: rootDirectory, includingPropertiesForKeys: nil
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var failure: (any Error)?
            for entry in entries where Self.isAccountDirectoryName(entry.lastPathComponent) {
                do {
                    var entryStatus = stat()
                    guard lstat(entry.path, &entryStatus) == 0, entryStatus.st_mode & S_IFMT == S_IFDIR else {
                        throw CatalogStorageError.unsafeStorageLocation
                    }
                    let account = try CatalogSQLiteDatabase(
                        directory: entry, rootDirectory: rootDirectory, openDatabase: false, rootLockAlreadyHeld: true
                    )
                    try account.purge()
                } catch { failure = failure ?? error }
            }
            if let failure { throw failure }
        }
    }

    private static func isAccountDirectoryName(_ name: String) -> Bool {
        name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
