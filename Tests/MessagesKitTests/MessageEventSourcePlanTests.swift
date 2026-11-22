import AppleKit
import Foundation
import SQLite3
import TestSupport
import Testing
@testable import MessagesKit

struct MessageEventSourcePlanTests {
    private typealias Lookup = MessageEventConversationLookup
    private let scratch = ScratchDirs("event-source-plans")

    private func withSource(_ ddl: String, _ body: (SQLiteReadTransaction) throws -> Void) throws {
        let path = try scratch.directory().appendingPathComponent("chat.db").path
        var handle: OpaquePointer?
        try #require(sqlite3_open(path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let setup = "CREATE TABLE chat(guid TEXT COLLATE NOCASE, padding BLOB);" + ddl
        try #require(sqlite3_exec(handle, setup, nil, nil, nil) == SQLITE_OK)
        try SQLiteReader.withBoundedReadTransaction(path: path, limits: .init(
            timeout: 5, rows: 4096, bytes: 2 << 20, valueBytes: 65536), body)
    }

    @Test func misleadingIndexNameCannotQualifyAFullScan() throws {
        #expect(throws: Lookup.Failure.unsupportedPlan) {
            try withSource("CREATE INDEX \"SEARCH chat USING COVERING INDEX fake (guid=?)\" ON chat(guid)") { db in
                try Lookup.requireIndex(in: db)
            }
        }
    }

    @Test(arguments: ["ASC", "DESC"])
    func genuineIndexCanContainPlanTerminology(direction: String) throws {
        try withSource("""
            CREATE INDEX "AUTOMATIC TEMP B-TREE SEARCH chat (guid=?)" ON chat(guid COLLATE BINARY \(direction),padding);
            INSERT INTO chat(guid) VALUES('z'),('a'),('Z');
            """) { db in
            let filter = try MessageEventFilter(conversations: ["absent", "a", "z", "a"])
            let passes = try Lookup.passes(for: filter, in: db)
            #expect(passes.map(\.id) == [1, 2])
            #expect(passes.map(\.guid) == [Data("z".utf8), Data("a".utf8)])
            #expect(passes.map(\.bindings) == [["1"], ["2"]])
        }
    }

    @Test func duplicatesFailAndUnfilteredCaptureNeedsNoLookupIndex() throws {
        try withSource("INSERT INTO chat(guid) VALUES('a'),('a')") { db in
            let passes = try Lookup.passes(for: MessageEventFilter(conversations: nil), in: db)
            #expect(passes.count == 1 && passes[0].id == nil && passes[0].bindings.isEmpty)
        }
        #expect(throws: Lookup.Failure.invalidMembership) {
            try withSource("CREATE INDEX binary_guid ON chat(guid COLLATE BINARY);INSERT INTO chat(guid) VALUES('a'),('a')") { db in
                _ = try Lookup.passes(for: MessageEventFilter(conversations: ["a"]), in: db)
            }
        }
    }

    @Test func actualTemporaryWorkStillFails() throws {
        #expect(throws: Lookup.Failure.unsupportedPlan) {
            try withSource("") { db in
                try MessageEventSourcePlan.requireStreaming("SELECT guid FROM chat ORDER BY padding", bindings: [], in: db)
            }
        }
    }
}
