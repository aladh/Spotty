import Darwin
import Foundation
import SQLite3

enum CatalogSQLiteValue {
    case integer(Int64)
    case text(String)
    case blob(Data)
    case null

    var integer: Int64? { if case let .integer(value) = self { value } else { nil } }
    var text: String? { if case let .text(value) = self { value } else { nil } }
    var blob: Data? { if case let .blob(value) = self { value } else { nil } }
}

/// Actor-confined connection. Its lock also prevents an old owner purging a replacement database.
final class CatalogSQLiteDatabase {
    static let filenames = ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm", "catalog.sqlite-journal"]
    private var connection: OpaquePointer?
    private var lockDescriptor: Int32 = -1
    private var rootLock: CatalogDirectoryLock?
    private let directory: URL

    init(directory: URL, rootDirectory: URL, openDatabase: Bool = true, rootLockAlreadyHeld: Bool = false) throws {
        self.directory = directory
        do {
            try Self.prepareDirectory(rootDirectory)
            if !rootLockAlreadyHeld {
                rootLock = try CatalogDirectoryLock(rootDirectory: rootDirectory, exclusive: false)
            }
            try Self.prepareDirectory(directory)
            let lockURL = directory.appendingPathComponent("ownership.lock")
            lockDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockDescriptor >= 0 else { throw CatalogStorageError.unsafeStorageLocation }
            var status = stat()
            guard fstat(lockDescriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                fchmod(lockDescriptor, 0o600) == 0
            else { throw CatalogStorageError.unsafeStorageLocation }
            guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw CatalogStorageError.accountInUse
            }
            for name in Self.filenames {
                try Self.checkRegularFileIfPresent(directory.appendingPathComponent(name))
            }
            guard openDatabase else { return }
            let file = directory.appendingPathComponent(Self.filenames[0])
            let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CatalogStorageError.filesystem }
            let permissionResult = fchmod(descriptor, 0o600)
            Darwin.close(descriptor)
            guard permissionResult == 0 else { throw CatalogStorageError.filesystem }
            // macOS's normal /var and /tmp parents are links. Resolve only the already-validated
            // parent directories; keep the final component subject to SQLite's no-follow check.
            guard let canonicalParent = realpath(directory.path, nil) else { throw CatalogStorageError.filesystem }
            let databasePath = String(cString: canonicalParent) + "/" + Self.filenames[0]
            free(canonicalParent)
            let result = sqlite3_open_v2(
                databasePath, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil
            )
            guard result == SQLITE_OK else { throw CatalogStorageError.database(result) }
            sqlite3_busy_timeout(connection, 1_000)
            try execute("PRAGMA foreign_keys=ON")
            let version = try rows("PRAGMA user_version").first?.first?.integer ?? -1
            guard version == 0 || version == 1 else {
                throw CatalogStorageError.unsupportedSchema(Int32(clamping: version))
            }
            if version == 0 {
                try transaction {
                    try execute(
                        "CREATE TABLE entities(kind INTEGER NOT NULL, uri TEXT NOT NULL, data BLOB NOT NULL, touched INTEGER NOT NULL, PRIMARY KEY(kind, uri))"
                    )
                    try execute(
                        "CREATE TABLE collections(key TEXT PRIMARY KEY NOT NULL, data BLOB NOT NULL, touched INTEGER NOT NULL)"
                    )
                    try execute(
                        "CREATE TABLE occurrences(collection_key TEXT NOT NULL REFERENCES collections(key) ON DELETE CASCADE, position INTEGER NOT NULL, requested_uri TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(collection_key, position))"
                    )
                    try execute("CREATE INDEX occurrence_entity ON occurrences(requested_uri)")
                    try execute("PRAGMA user_version=1")
                }
            }
            // Validate the complete supported schema before enabling writes after a reopen.
            _ = try rows("SELECT kind, uri, data, touched FROM entities LIMIT 0")
            _ = try rows("SELECT key, data, touched FROM collections LIMIT 0")
            _ = try rows("SELECT collection_key, position, requested_uri, data FROM occurrences LIMIT 0")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA journal_size_limit=4194304")
            try execute("PRAGMA wal_autocheckpoint=256")
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        if let connection { sqlite3_close_v2(connection) }
        connection = nil
        if lockDescriptor >= 0 {
            flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
        rootLock = nil
    }

    /// Keeps the stable empty lock file so an opener cannot lock an unlinked inode.
    func purge() throws {
        if let connection { sqlite3_close_v2(connection) }
        connection = nil
        var failed = false
        for name in Self.filenames {
            let file = directory.appendingPathComponent(name)
            do {
                try Self.checkRegularFileIfPresent(file)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            } catch { failed = true }
        }
        guard !failed else { throw CatalogStorageError.filesystem }
        close()
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, _ values: [CatalogSQLiteValue] = []) throws {
        _ = try rows(sql, values)
    }

    func rows(_ sql: String, _ values: [CatalogSQLiteValue] = []) throws -> [[CatalogSQLiteValue]] {
        guard let connection else { throw CatalogStorageError.retired }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw CatalogStorageError.database(prepared) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .integer(value): result = sqlite3_bind_int64(statement, index, value)
            case let .text(value):
                result = value.withCString {
                    sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient)
                }
            case let .blob(value):
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient)
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw CatalogStorageError.database(result) }
        }
        var result: [[CatalogSQLiteValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw CatalogStorageError.database(step) }
            var row: [CatalogSQLiteValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(statement, column) else {
                        throw CatalogStorageError.invalidStoredData
                    }
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row.append(.text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column) {
                        row.append(.blob(Data(bytes: bytes, count: count)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default: row.append(.null)
                }
            }
            result.append(row)
        }
    }

    private static func prepareDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw CatalogStorageError.unsafeStorageLocation }
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CatalogStorageError.unsafeStorageLocation
            }
        } else {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func checkRegularFileIfPresent(_ url: URL) throws {
        // lstat also sees dangling links, unlike fileExists(atPath:).
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else { throw CatalogStorageError.filesystem }
            return
        }
        guard status.st_mode & S_IFMT == S_IFREG else { throw CatalogStorageError.unsafeStorageLocation }
    }
}
