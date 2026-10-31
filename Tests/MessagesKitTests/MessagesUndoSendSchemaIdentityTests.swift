import AppleKit
import Testing
@testable import MessagesKit

/// Schema identity must be established before SQLite row aliases are trusted.
@Suite struct MessagesUndoSendSchemaIdentityTests {
    private func read(_ fixture: ChatFixture) throws -> MessagesUndoSendIdentity.Snapshot {
        try MessagesUndoSendIdentity.read(databasePath: fixture.path,
            chat: .rowid(3), message: .rowid(2),
            deadline: .millisecondsFromNow(5000))
    }

    private func expectUnsupportedSchema(_ fixture: ChatFixture) {
        do {
            _ = try read(fixture)
            Issue.record("Unsafe schema was accepted")
        } catch MessagesUndoSendIdentity.Failure.unsupportedSchema {
            // Require the schema guard, not a later accidental target mismatch.
        } catch {
            Issue.record("Expected unsupportedSchema, received \(error)")
        }
    }

    @Test(arguments: ["chat", "message", "handle", "chat_message_join", "chat_handle_join"])
    func generatedRowAliasIsRejected(table: String) throws {
        let fixture = try ChatFixture()
        let original = try read(fixture)
        #expect(original.messageRowid == 2)
        // Mixed case also exercises SQLite's case-insensitive name resolution.
        // table_info omits generated columns; table_xinfo must expose this one.
        try fixture.exec("ALTER TABLE \(table) ADD COLUMN _RoWiD_ INTEGER GENERATED ALWAYS AS (1) VIRTUAL")
        expectUnsupportedSchema(fixture)
    }

    @Test(arguments: ["chat", "message", "handle", "chat_message_join", "chat_handle_join"])
    func viewCannotSubstituteForIdentityTable(table: String) throws {
        let fixture = try ChatFixture()
        _ = try read(fixture)
        // Retain all original rows and column values behind the synthetic view.
        // A data-shaped replacement still must not pass the physical-table guard.
        try fixture.exec("ALTER TABLE \(table) RENAME TO retained_\(table)")
        try fixture.exec("CREATE VIEW \(table) AS SELECT * FROM retained_\(table)")
        expectUnsupportedSchema(fixture)
    }
}
