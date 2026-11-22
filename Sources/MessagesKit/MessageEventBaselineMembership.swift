import Foundation
import SQLite3

extension MessageEventJournalSchema {
    enum MembershipFailure: Error, Equatable { case invalidMembership }

    static let membershipScan = """
        SELECT message_rowid,chat_rowid,message_guid,chat_guid FROM baseline INDEXED BY baseline_locator ORDER BY message_rowid,chat_rowid
        """

    /// Check a completed baseline on the pinned snapshot. Reconciliation may temporarily
    /// reuse a physical locator before it removes a disappeared membership. Compare the
    /// index walk to the independent row count from the table digest in this transaction.
    func validateBaselineMemberships(filter: MessageEventFilter, expectedCount: Int64, checkpoint: () throws -> Void) throws {
        try checkpoint()
        guard sqlite3_get_autocommit(database) == 0, sqlite3_txn_state(database, "main") != SQLITE_TXN_NONE else {
            throw MessageEventReplayReader.Failure.snapshotRequired
        }
        guard expectedCount >= 0 else { throw MembershipFailure.invalidMembership }
        guard expectedCount <= MessageEventJournalLimits.memberships else { throw MessageEventStateDigest.Failure.limitExceeded }
        let allowedChats = filter.conversations.map { Set($0.map(\.bytes)) }
        var previousMessage: Int64 = 0
        var previousChat: Int64 = 0
        var previousGUID = Data()
        var count: Int64 = 0
        try rows(Self.membershipScan) { row in
            try checkpoint()
            guard count < expectedCount else { throw MembershipFailure.invalidMembership }
            guard sqlite3_column_type(row, 0) == SQLITE_INTEGER, sqlite3_column_type(row, 1) == SQLITE_INTEGER else {
                throw MembershipFailure.invalidMembership
            }
            let message = sqlite3_column_int64(row, 0), chat = sqlite3_column_int64(row, 1)
            guard message > 0, chat > 0 else { throw MembershipFailure.invalidMembership }
            let guid = try membershipGUID(row, column: 2)
            let chatGUID = try membershipGUID(row, column: 3)
            guard allowedChats?.contains(chatGUID) != false else { throw MembershipFailure.invalidMembership }
            if message == previousMessage {
                guard chat > previousChat, guid == previousGUID else { throw MembershipFailure.invalidMembership }
            } else {
                guard message > previousMessage else { throw MembershipFailure.invalidMembership }
                previousMessage = message
                previousGUID = guid
            }
            previousChat = chat
            count += 1
        }
        try checkpoint()
        guard count == expectedCount else { throw MembershipFailure.invalidMembership }
    }

    private func membershipGUID(_ row: OpaquePointer, column: Int32) throws -> Data {
        guard sqlite3_column_type(row, column) == SQLITE_BLOB else { throw MembershipFailure.invalidMembership }
        let size = Int(sqlite3_column_bytes(row, column))
        guard (1...1_024).contains(size) else { throw MembershipFailure.invalidMembership }
        guard let bytes = sqlite3_column_blob(row, column) else { throw Failure.sqliteCode(SQLITE_NOMEM) }
        return try MessageEventGUID(storedBytes: Data(bytes: bytes, count: size)).bytes
    }
}
