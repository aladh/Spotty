import Foundation
import SQLite3

/// Owned by one serialized catalog connection; each execution releases all bound values.
final class CatalogSQLiteStatement {
    private let handle: OpaquePointer

    init(connection: OpaquePointer, sql: String) throws {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw CatalogStorageError.database(result) }
        handle = statement
    }

    deinit { sqlite3_finalize(handle) }

    func rows(_ values: [CatalogSQLiteValue]) throws -> [[CatalogSQLiteValue]] {
        var result: [[CatalogSQLiteValue]] = []
        try forEachRow(values) { result.append($0) }
        return result
    }

    /// The callback consumes one copied row synchronously; no SQLite-backed values escape.
    func forEachRow(_ values: [CatalogSQLiteValue], _ consume: ([CatalogSQLiteValue]) throws -> Void) throws {
        defer { sqlite3_clear_bindings(handle) }
        do {
            try execute(values, consume)
            let reset = sqlite3_reset(handle)
            guard reset == SQLITE_OK else { throw CatalogStorageError.database(reset) }
        } catch {
            // A failed bind, step, or consumer must not poison the next use.
            sqlite3_reset(handle)
            throw error
        }
    }

    private func execute(_ values: [CatalogSQLiteValue], _ consume: ([CatalogSQLiteValue]) throws -> Void) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .integer(value): result = sqlite3_bind_int64(handle, index, value)
            case let .text(value):
                result = value.withCString {
                    sqlite3_bind_text(handle, index, $0, Int32(value.utf8.count), transient)
                }
            case let .blob(value):
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(handle, index, $0.baseAddress, Int32(value.count), transient)
                }
            case .null: result = sqlite3_bind_null(handle, index)
            }
            guard result == SQLITE_OK else { throw CatalogStorageError.database(result) }
        }
        while true {
            let step = sqlite3_step(handle)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw CatalogStorageError.database(step) }
            var row: [CatalogSQLiteValue] = []
            for column in 0..<sqlite3_column_count(handle) {
                switch sqlite3_column_type(handle, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(handle, column)))
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(handle, column) else {
                        throw CatalogStorageError.invalidStoredData
                    }
                    let count = Int(sqlite3_column_bytes(handle, column))
                    row.append(.text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(handle, column))
                    if let bytes = sqlite3_column_blob(handle, column) {
                        row.append(.blob(Data(bytes: bytes, count: count)))
                    } else {
                        row.append(.blob(Data()))
                    }
                default: row.append(.null)
                }
            }
            try consume(row)
        }
    }
}
