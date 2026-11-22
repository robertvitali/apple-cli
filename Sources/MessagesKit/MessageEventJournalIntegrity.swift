import Foundation
import SQLite3

extension MessageEventJournalSchema {
    enum IntegrityFailure: Error, Equatable { case invalidDigest, invalidPages }

    enum IntegrityBudgetFailure: String, Error {
        case capacity = "integrity-validation-capacity"
        case deadline, cancelled
    }

    /// One physical check on an exclusively owned connection. SQLite cannot return
    /// a previously installed progress handler, so its owner supplies the restoration.
    struct IntegrityBudget {
        let deadline: ContinuousClock.Instant
        var maximumCallbacks = 131_072
        var isCancelled: () -> Bool = { false }
        let restoreProgressHandler: () -> Void

        private var stopReason: IntegrityBudgetFailure? {
            if isCancelled() { return .cancelled }
            return ContinuousClock.now >= deadline ? .deadline : nil
        }

        private final class Counter {
            let budget: IntegrityBudget
            var remaining: Int
            var interrupted: IntegrityBudgetFailure?

            init(_ budget: IntegrityBudget) {
                self.budget = budget
                remaining = budget.maximumCallbacks
            }

            func interrupt() -> Int32 {
                if let reason = budget.stopReason { interrupted = reason }
                else if remaining <= 0 { interrupted = .capacity }
                else { remaining -= 1 }
                return interrupted == nil ? 0 : 1
            }
        }

        fileprivate func run(on db: OpaquePointer, check: () throws -> Void) throws {
            let counter = Counter(self)
            if let failure = stopReason { throw failure }
            guard maximumCallbacks > 0 else { throw IntegrityBudgetFailure.capacity }
            sqlite3_progress_handler(db, 256, { context in
                guard let context else { return 1 }
                return Unmanaged<Counter>.fromOpaque(context).takeUnretainedValue().interrupt()
            }, Unmanaged.passUnretained(counter).toOpaque())
            defer {
                sqlite3_progress_handler(db, 0, nil, nil)
                restoreProgressHandler()
                withExtendedLifetime(counter) {}
            }
            do { try check() } catch { throw counter.interrupted ?? error }
            if let failure = counter.interrupted { throw failure }
            if let failure = stopReason { throw failure }
        }
    }

    /// Call in a validated journal snapshot, with the normal data limits restored.
    /// Check bounded logical rows first: SQLite's page check may read overflow
    /// pages for a record the row validator can reject from its declared length.
    /// A matching digest covers table rows. Recheck indexes on this snapshot
    /// even when a previous connection already checked the same logical state.
    func verifiedStateDigest(budget: IntegrityBudget, scan: () throws -> Data) throws -> Data {
        var stored: Data?
        try rows("SELECT state_digest FROM meta WHERE id=1") { row in
            guard stored == nil, sqlite3_column_type(row, 0) == SQLITE_BLOB,
                  sqlite3_column_bytes(row, 0) == 32,
                  let bytes = sqlite3_column_blob(row, 0) else { throw IntegrityFailure.invalidDigest }
            stored = Data(bytes: bytes, count: 32)
        }
        guard let stored, try scan() == stored else { throw IntegrityFailure.invalidDigest }
        try verifyPageIntegrity(budget: budget)
        return stored
    }

    /// Validate every retained event in this snapshot before exposing its replay window.
    /// Empty retention is valid even when earlier events have advanced the head.
    func validatedOldestSequence(metadata: PersistedEventMetadata, checkpoint: () throws -> Void) throws -> Int64? {
        try checkpoint()
        guard sqlite3_get_autocommit(database) == 0, sqlite3_txn_state(database, "main") != SQLITE_TXN_NONE else {
            throw MessageEventReplayReader.Failure.snapshotRequired
        }
        let reader = MessageEventDelivery.Reader(metadata: metadata)
        var oldest: Int64?
        var previous: Int64?
        var count = 0
        var bytes = 0
        try rows("SELECT sequence,payload FROM events ORDER BY sequence") { row in
            try checkpoint()
            guard sqlite3_column_type(row, 0) == SQLITE_INTEGER else { throw MessageEventReplayReader.Failure.invalidSequence }
            let sequence = sqlite3_column_int64(row, 0)
            guard sequence > 0, sequence <= metadata.head,
                  previous.map({ sequence - 1 == $0 }) ?? true else { throw MessageEventReplayReader.Failure.invalidSequence }
            guard sqlite3_column_type(row, 1) == SQLITE_BLOB else { throw MessageEventReplayReader.Failure.invalidPayload }
            let length = Int(sqlite3_column_bytes(row, 1))
            guard (1...65_536).contains(length) else { throw MessageEventReplayReader.Failure.invalidPayload }
            guard count < MessageEventJournalLimits.events, length <= MessageEventJournalLimits.eventBytes - bytes else {
                throw MessageEventStateDigest.Failure.limitExceeded
            }
            guard let payload = sqlite3_column_blob(row, 1) else { throw MessageEventJournalSchema.Failure.sqliteCode(SQLITE_NOMEM) }
            try autoreleasepool {
                try reader.validateStoredEvent(Data(bytes: payload, count: length), sequence: sequence)
            }
            if oldest == nil { oldest = sequence }
            previous = sequence
            count += 1
            bytes += length
        }
        try checkpoint()
        if let previous, previous != metadata.head { throw MessageEventReplayReader.Failure.invalidSequence }
        return oldest
    }

    /// The caller has validated the logical rows and metadata in this transaction.
    /// Verify the pages before using the retained window to advise resynchronization.
    func validateReplayCursor(_ cursor: MessageEventCursor, metadata: PersistedEventMetadata,
                              budget: IntegrityBudget) throws {
        guard sqlite3_get_autocommit(database) == 0, sqlite3_txn_state(database, "main") != SQLITE_TXN_NONE else {
            throw MessageEventReplayReader.Failure.snapshotRequired
        }
        guard metadata.initialized else { throw PersistedEventMetadataFailure.invalidMetadata }
        try verifyPageIntegrity(budget: budget)
        var oldest: Int64?
        try rows("SELECT sequence FROM events ORDER BY sequence LIMIT 1") { row in
            guard sqlite3_column_type(row, 0) == SQLITE_INTEGER else {
                throw MessageEventCursorFailure.invalidRetentionBounds
            }
            oldest = sqlite3_column_int64(row, 0)
        }
        try cursor.validateReplay(stream: metadata.stream, filter: metadata.filter.digest,
                                  head: metadata.head, oldestRetained: oldest)
    }

    func verifyPageIntegrity(budget: IntegrityBudget) throws {
        try budget.run(on: database) { try checkPages() }
    }

    private func checkPages() throws {
        var seen = false
        try rows("PRAGMA main.integrity_check(1)") { row in
            guard !seen, sqlite3_column_type(row, 0) == SQLITE_TEXT,
                  let text = sqlite3_column_text(row, 0), sqlite3_column_bytes(row, 0) == 2,
                  text[0] == 111, text[1] == 107 else { throw IntegrityFailure.invalidPages }
            seen = true
        }
        guard seen else { throw IntegrityFailure.invalidPages }
    }
}
