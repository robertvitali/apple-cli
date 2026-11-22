import Foundation
import SQLite3

/// Copies bounded pages from one validated journal version. The caller owns the
/// connection, its lease and snapshot setup. Output can block, so a page is only
/// returned after the caller releases the SQLite snapshot.
struct MessageEventReplayReader {
    enum Failure: Error, Equatable {
        case snapshotRequired, snapshotStillOpen, journalChanged, invalidSequence, invalidPayload
    }

    struct Row {
        let sequence: Int64
        let payload: Data
    }

    private let journal: MessageEventJournalSchema
    private let initialVersion: Int64

    init(journal: MessageEventJournalSchema) throws {
        try Self.requirePinnedRead(journal.database)
        initialVersion = try Self.dataVersion(journal)
        self.journal = journal
    }

    func checkVersion() throws {
        guard try Self.dataVersion(journal) == initialVersion else { throw Failure.journalChanged }
    }

    func page(after: Int64, through head: Int64, checkpoint: () throws -> Void,
              releaseSnapshot: () throws -> Void) throws -> [Row] {
        try checkpoint()
        guard after >= 0, head >= after else { throw Failure.invalidSequence }
        try Self.requirePinnedRead(journal.database)
        try checkVersion()
        let rows = try copyRows(after: after, through: head, checkpoint: checkpoint)
        try releaseSnapshot()
        guard sqlite3_get_autocommit(journal.database) != 0,
              sqlite3_txn_state(journal.database, "main") == SQLITE_TXN_NONE else {
            throw Failure.snapshotStillOpen
        }
        // A writer may commit as soon as the read lock is released. Compare on
        // the same connection again before publishing the page or a ready control.
        try checkVersion()
        try checkpoint()
        return rows
    }

    /// Start in the validated read snapshot. Each bounded page is copied before
    /// releasing the snapshot, and all output runs with the transaction closed.
    func replay(after cursor: Int64, through head: Int64, checkpoint: () throws -> Void,
                validateLease: () throws -> Void, beginSnapshot: () throws -> Void,
                releaseSnapshot: () throws -> Void, onReady: (() throws -> Void)?,
                write: (Row) throws -> Void) throws -> Int64 {
        var last = cursor
        var notify = onReady
        while true {
            try validateLease()
            let rows = try page(after: last, through: head, checkpoint: checkpoint, releaseSnapshot: releaseSnapshot)
            try validateLease()
            if let ready = notify {
                try ready()
                notify = nil
                // A control record can block just like an event. The copied page
                // is still unpublished, so recheck before exposing any of it.
                try checkpoint()
                try validateLease()
                try checkVersion()
            }
            for row in rows {
                try checkpoint()
                try write(row)
                last = row.sequence
            }
            try validateLease()
            try checkVersion()
            try checkpoint()
            if last == head { return last }
            try beginSnapshot()
        }
    }

    private func copyRows(after: Int64, through head: Int64, checkpoint: () throws -> Void) throws -> [Row] {
        let sql = "SELECT sequence,length(payload),payload FROM events WHERE sequence>? AND sequence<=? ORDER BY sequence LIMIT 64"
        return try journal.withStatement(sql) { statement in
            for (index, value) in [(Int32(1), after), (2, head)] {
                let result = sqlite3_bind_int64(statement, index, value)
                guard result == SQLITE_OK else { throw MessageEventJournalSchema.Failure.sqliteCode(result) }
            }
            var rows: [Row] = []
            var bytes = 0
            var previous = after
            while rows.count < 64 {
                try checkpoint()
                switch journal.step(statement) {
                case SQLITE_DONE:
                    guard previous == head else { throw Failure.invalidSequence }
                    return rows
                case SQLITE_ROW:
                    guard previous < head, sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                          sqlite3_column_int64(statement, 0) == previous + 1 else { throw Failure.invalidSequence }
                    guard sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                          sqlite3_column_type(statement, 2) == SQLITE_BLOB else { throw Failure.invalidPayload }
                    let length = sqlite3_column_int64(statement, 1)
                    guard (1...65_536).contains(length) else { throw Failure.invalidPayload }
                    if length > 131_072 - bytes { return rows }
                    guard sqlite3_column_bytes(statement, 2) == length,
                          let pointer = sqlite3_column_blob(statement, 2) else { throw Failure.invalidPayload }
                    let payload = Data(bytes: pointer, count: Int(length))
                    previous += 1
                    bytes += payload.count
                    rows.append(Row(sequence: previous, payload: payload))
                case let error: throw MessageEventJournalSchema.Failure.sqliteCode(error)
                }
            }
            return rows
        }
    }

    private static func requirePinnedRead(_ db: OpaquePointer) throws {
        guard sqlite3_get_autocommit(db) == 0, sqlite3_txn_state(db, "main") == SQLITE_TXN_READ else {
            throw Failure.snapshotRequired
        }
    }

    private static func dataVersion(_ journal: MessageEventJournalSchema) throws -> Int64 {
        try journal.withStatement("PRAGMA main.data_version") { statement in
            let first = journal.step(statement)
            guard first == SQLITE_ROW else { throw MessageEventJournalSchema.Failure.sqliteCode(first) }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw Failure.journalChanged }
            let value = sqlite3_column_int64(statement, 0)
            let end = journal.step(statement)
            guard end == SQLITE_DONE else { throw MessageEventJournalSchema.Failure.sqliteCode(end) }
            return value
        }
    }

}
