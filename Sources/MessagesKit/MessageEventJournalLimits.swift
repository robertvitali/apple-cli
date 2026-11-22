import SQLite3

enum MessageEventJournalLimits {
    static let memberships = 250_000
    static let events = 100_000
    static let eventBytes = 64 << 20

    /// A capture must fit in retention on its own. Older committed events can be
    /// evicted only after this complete capture succeeds.
    struct CaptureWindow {
        private(set) var eventCount = 0
        private(set) var payloadBytes = 0

        init() {}

        func appending(payloadSize: Int) throws -> Self {
            guard eventCount < MessageEventJournalLimits.events else { throw MessageEventCaptureLimit.captureEvents }
            guard payloadSize > 0 else { throw MessageEventDelivery.Failure.invalidRecord }
            guard payloadSize <= MessageEventJournalLimits.eventBytes - payloadBytes else {
                throw MessageEventCaptureLimit.captureEventBytes
            }
            var next = self
            next.eventCount += 1
            next.payloadBytes += payloadSize
            return next
        }
    }

    // The largest v1 record is metadata: at most 263,174 filter bytes plus fixed fields.
    // SQLite applies this limit to individual values and to encoded table rows during writes.
    static let sqliteLength: Int32 = 512 * 1024

    /// Configure a newly opened, exclusively owned private event journal before preparing any SQL.
    /// A lower limit inherited from the linked library or caller is preserved.
    static func configure(_ database: OpaquePointer) throws {
        guard sqlite3_get_autocommit(database) != 0, sqlite3_next_stmt(database, nil) == nil else {
            throw Failure.activeConnection
        }
        let previous = sqlite3_limit(database, SQLITE_LIMIT_LENGTH, -1)
        let limit = min(previous, sqliteLength)
        guard limit > 0 else { throw Failure.unavailable }
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, limit)
        guard sqlite3_limit(database, SQLITE_LIMIT_LENGTH, -1) == limit else { throw Failure.unavailable }
    }

    enum Failure: Error { case activeConnection, unavailable }
}
