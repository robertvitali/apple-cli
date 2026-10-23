import Foundation
import SQLite3

/// A synchronous, closure-scoped read transaction. Not safe to share across threads.
/// Rows are delivered individually; limits count selected values, not total process memory.
public final class SQLiteReadTransaction {
    public struct Limits: Sendable {
        public let timeout: TimeInterval
        public let rows: Int
        public let bytes: Int
        public let valueBytes: Int

        /// `valueBytes` also sets SQLite's length limit during expression evaluation.
        /// It is not a cap on the combined size of separately projected column values.
        public init(timeout: TimeInterval, rows: Int, bytes: Int, valueBytes: Int) {
            self.timeout = timeout
            self.rows = rows
            self.bytes = bytes
            self.valueBytes = valueBytes
        }
    }

    /// Diagnostics intentionally omit SQL, file paths and selected values.
    public enum Failure: Error, Equatable {
        case invalidLimits, couldNotOpen, inactive, reentrant, cancelled, deadline
        case invalidQuery, invalidBindings, rowLimit, byteLimit, valueLimit, invalidText
        case database(Int32)
    }

    private let limits: Limits
    private let deadline: ContinuousClock.Instant
    private let isCancelled: () -> Bool
    private var handle: OpaquePointer?
    private var reading = false
    private var checkingCancellation = false
    private var rowCount = 0
    private var byteCount = 0
    private var interruption: Failure?
    private var queryFailure: Error?

    init(limits: Limits, isCancelled: @escaping () -> Bool) throws {
        guard limits.timeout.isFinite, limits.timeout > 0, limits.timeout <= 60,
              (1...1_000_000).contains(limits.rows),
              (1...1_073_741_824).contains(limits.bytes),
              (1...16_777_216).contains(limits.valueBytes),
              limits.valueBytes <= limits.bytes else { throw Failure.invalidLimits }
        self.limits = limits
        self.isCancelled = isCancelled
        self.deadline = ContinuousClock.now.advanced(by: .seconds(limits.timeout))
    }

    func checkpoint() throws {
        if let queryFailure { throw queryFailure }
        if let interruption { throw interruption }
        checkingCancellation = true
        let cancelled = isCancelled()
        checkingCancellation = false
        // A predicate can call back into this scope and swallow its refusal.
        if let queryFailure { throw queryFailure }
        if cancelled { interruption = .cancelled; throw Failure.cancelled }
        if ContinuousClock.now >= deadline { interruption = .deadline; throw Failure.deadline }
    }

    private func shouldInterrupt() -> Bool {
        do { try checkpoint(); return false } catch { return true }
    }

    func run<T>(on db: OpaquePointer, _ body: (SQLiteReadTransaction) throws -> T) throws -> T {
        handle = db
        let context = Unmanaged.passUnretained(self).toOpaque()
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 1 }
            return Unmanaged<SQLiteReadTransaction>.fromOpaque(context)
                .takeUnretainedValue().shouldInterrupt() ? 1 : 0
        }, context)
        sqlite3_busy_handler(db, { context, _ in
            guard let context else { return 0 }
            let scope = Unmanaged<SQLiteReadTransaction>.fromOpaque(context).takeUnretainedValue()
            guard !scope.shouldInterrupt() else { return 0 }
            sqlite3_sleep(1)
            return scope.shouldInterrupt() ? 0 : 1
        }, context)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(limits.valueBytes))
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 65_536)
        sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 128)
        sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, 512)
        defer {
            handle = nil
            sqlite3_set_authorizer(db, nil, nil)
            sqlite3_progress_handler(db, 0, nil, nil)
            sqlite3_busy_handler(db, nil, nil)
            // Read-only rollback releases the snapshot even when cancellation is latched.
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
        try checkpoint()
        try executeInternal("BEGIN", on: db)
        // BEGIN is deferred. Reading the schema establishes the snapshot before body runs.
        try executeInternal("SELECT rootpage FROM sqlite_schema LIMIT 1", on: db)
        let rc = sqlite3_set_authorizer(db, { _, action, _, function, _, _ in
            switch action {
            case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE: return SQLITE_OK
            case SQLITE_FUNCTION:
                guard let function, String(cString: function).lowercased() != "load_extension"
                else { return SQLITE_DENY }
                return SQLITE_OK
            default: return SQLITE_DENY
            }
        }, nil)
        guard rc == SQLITE_OK else { throw Failure.database(rc) }
        let result = try body(self)
        try checkpoint()
        return result
    }

    private func executeInternal(_ sql: String, on db: OpaquePointer) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), expecting: SQLITE_OK)
        while true {
            try checkpoint()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            try check(result, expecting: SQLITE_ROW)
        }
        try checkpoint()
    }

    private func check(_ result: Int32, expecting expected: Int32) throws {
        try checkpoint()
        guard result == expected else {
            if result == SQLITE_TOOBIG { throw Failure.valueLimit }
            throw Failure.database(result)
        }
    }

    /// Call with fixed SQL and positional text parameters. The consumer must return promptly.
    /// Every query or consumer error fails the complete capture, even when the caller catches it.
    public func forEachRow(
        _ sql: String, _ binds: [String] = [],
        _ consume: (SQLiteReader.Row) throws -> Void
    ) throws {
        do { try readRows(sql, binds, consume) }
        catch {
            queryFailure = error
            throw error
        }
    }

    private func readRows(
        _ sql: String, _ binds: [String], _ consume: (SQLiteReader.Row) throws -> Void
    ) throws {
        guard let db = handle else { throw Failure.inactive }
        guard !reading, !checkingCancellation else { throw Failure.reentrant }
        reading = true
        defer { reading = false }
        try checkpoint()
        guard !sql.utf8.contains(0), sql.utf8.count <= 65_536 else { throw Failure.invalidQuery }
        guard binds.count <= 512,
              binds.allSatisfy({ $0.utf8.count <= min(limits.valueBytes, 65_536) }),
              binds.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
            throw Failure.invalidBindings
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try sql.withCString { source in
            var tail: UnsafePointer<CChar>?
            try check(sqlite3_prepare_v2(db, source, -1, &statement, &tail), expecting: SQLITE_OK)
            guard statement != nil, let tail,
                  String(cString: tail).utf8.allSatisfy({ [9, 10, 13, 32].contains($0) }),
                  sqlite3_stmt_readonly(statement) != 0 else { throw Failure.invalidQuery }
        }
        guard sqlite3_bind_parameter_count(statement) == binds.count else { throw Failure.invalidBindings }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, bind) in binds.enumerated() {
            try bind.withCString {
                try check(sqlite3_bind_text(statement, Int32(index + 1), $0,
                                            Int32(bind.utf8.count), transient), expecting: SQLITE_OK)
            }
        }
        let columns = sqlite3_column_count(statement)
        guard (1...128).contains(columns) else { throw Failure.invalidQuery }
        let names = (0..<columns).map { String(cString: sqlite3_column_name(statement, $0)) }
        guard names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 }),
              Set(names).count == names.count else { throw Failure.invalidQuery }
        while true {
            try checkpoint()
            let result = sqlite3_step(statement)
            try checkpoint()
            if result == SQLITE_DONE { break }
            try check(result, expecting: SQLITE_ROW)
            guard rowCount < limits.rows else { throw Failure.rowLimit }
            rowCount += 1
            var values: [String: SQLiteReader.Row.Value] = [:]
            for column in 0..<columns {
                try checkpoint()
                let type = sqlite3_column_type(statement, column)
                let count: Int
                switch type {
                case SQLITE_INTEGER, SQLITE_FLOAT: count = 8
                case SQLITE_TEXT, SQLITE_BLOB: count = Int(sqlite3_column_bytes(statement, column))
                default: count = 0
                }
                guard count <= limits.valueBytes else { throw Failure.valueLimit }
                guard count <= limits.bytes - byteCount else { throw Failure.byteLimit }
                byteCount += count
                let name = names[Int(column)]
                switch type {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    guard let pointer = sqlite3_column_text(statement, column) else {
                        throw Failure.database(SQLITE_NOMEM)
                    }
                    guard let text = String(data: Data(bytes: pointer, count: count), encoding: .utf8)
                    else { throw Failure.invalidText }
                    values[name] = .text(text)
                case SQLITE_BLOB:
                    if count == 0 { values[name] = .blob(Data()) }
                    else if let pointer = sqlite3_column_blob(statement, column) {
                        values[name] = .blob(Data(bytes: pointer, count: count))
                    } else { throw Failure.database(SQLITE_NOMEM) }
                default: values[name] = .null
                }
            }
            try consume(SQLiteReader.Row(values: values))
            try checkpoint()
        }
    }
}
