import Foundation
import SQLite3
import Testing

@testable import SpottyCatalogStorage

struct CatalogSQLiteStatementChecks {
    @Test func executionsClearBindingsIncludingAfterBindFailure() throws {
        try withConnection { connection in
            let statement = try CatalogSQLiteStatement(connection: connection, sql: "SELECT ?, ?, ?")
            let first = try #require(statement.rows([.text("first"), .integer(42), .blob(Data([1, 2]))]).first)
            #expect(first[0].text == "first")
            #expect(first[1].integer == 42)
            #expect(first[2].blob == Data([1, 2]))

            let second = try #require(statement.rows([.text("second")]).first)
            #expect(second[0].text == "second")
            #expect(isNull(second[1]) && isNull(second[2]))

            #expect(throws: CatalogStorageError.database(SQLITE_RANGE)) {
                try statement.rows([.text("discarded"), .integer(99), .blob(Data([3])), .null])
            }
            #expect(try statement.rows([]).first?.allSatisfy(isNull) == true)
        }
    }

    @Test func failedStepDoesNotPoisonTheNextExecutionAndDeinitFinalizes() throws {
        try withConnection { connection in
            do {
                let create = try CatalogSQLiteStatement(
                    connection: connection, sql: "CREATE TABLE fixture(value INTEGER UNIQUE)")
                _ = try create.rows([])
                let insert = try CatalogSQLiteStatement(connection: connection, sql: "INSERT INTO fixture VALUES(?)")
                _ = try insert.rows([.integer(1)])
                #expect(throws: CatalogStorageError.database(SQLITE_CONSTRAINT)) {
                    try insert.rows([.integer(1)])
                }
                _ = try insert.rows([.integer(2)])
                let read = try CatalogSQLiteStatement(
                    connection: connection, sql: "SELECT value FROM fixture ORDER BY value")
                #expect(try read.rows([]).compactMap { $0.first?.integer } == [1, 2])
                withExtendedLifetime(read) { #expect(sqlite3_next_stmt(connection, nil) != nil) }
            }
            #expect(sqlite3_next_stmt(connection, nil) == nil)
        }
    }

    @Test func connectionClosesStatementsBeforeReleasingOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spotty-statements-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("synthetic")
        let database = try CatalogSQLiteDatabase(directory: directory, rootDirectory: root)
        // Exercise more distinct statements than the cache retains, then reuse one with new input.
        for index in 0..<100 {
            #expect(
                try database.rows("SELECT ?, \(index)", [.integer(Int64(index))]).first?.first?.integer == Int64(index))
        }
        #expect(try database.rows("SELECT ?, 0", [.integer(101)]).first?.first?.integer == 101)
        database.close()
        #expect(throws: CatalogStorageError.retired) { try database.rows("SELECT 1") }
        let reopened = try CatalogSQLiteDatabase(directory: directory, rootDirectory: root)
        #expect(try reopened.rows("SELECT 2").first?.first?.integer == 2)
        try reopened.purge()
        #expect(throws: CatalogStorageError.retired) { try reopened.rows("SELECT 2") }
        for name in CatalogSQLiteDatabase.filenames {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
    }

    private func isNull(_ value: CatalogSQLiteValue) -> Bool {
        if case .null = value { true } else { false }
    }

    private func withConnection(_ body: (OpaquePointer) throws -> Void) throws {
        var connection: OpaquePointer?
        #expect(sqlite3_open(":memory:", &connection) == SQLITE_OK)
        let opened = try #require(connection)
        defer { #expect(sqlite3_close(opened) == SQLITE_OK) }
        try body(opened)
    }
}
