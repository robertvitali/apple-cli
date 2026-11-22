import SQLite3

/// Limits the schema-only phase of a private event journal. The caller owns the connection
/// and its trace/progress callbacks exclusively, and installs its ordinary handler after this scope.
enum MessageEventCatalogBudget {
    enum Failure: Error { case workLimit, deadline, unavailable }

    private final class Counter {
        let deadline: ContinuousClock.Instant
        var remaining = 1024
        var failure: Failure?
        private var statementRows: [UnsafeMutableRawPointer: Int] = [:]
        private var totalRows = 0

        // The fixed v1 catalog has five objects. The inventory reads at most six rows,
        // including the first unexpected one. SQLite may also trace its internal schema
        // load before the inventory begins. Count those rows without reading SQL or data.
        func trace(_ event: UInt32, statement: UnsafeMutableRawPointer) {
            if event == UInt32(SQLITE_TRACE_PROFILE) {
                statementRows.removeValue(forKey: statement)
            } else if event == UInt32(SQLITE_TRACE_ROW), failure == nil {
                let count = statementRows[statement, default: 0]
                guard count < 6, totalRows < 64 else { failure = .workLimit; return }
                statementRows[statement] = count + 1
                totalRows += 1
            }
        }

        init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

        func interrupt() -> Int32 {
            if failure != nil { return 1 }
            if ContinuousClock.now >= deadline { failure = .deadline }
            else if remaining == 0 { failure = .workLimit }
            else { remaining -= 1 }
            return failure == nil ? 0 : 1
        }
    }

    static func run<T>(on db: OpaquePointer, until deadline: ContinuousClock.Instant,
                       _ operation: () throws -> T) throws -> T {
        guard ContinuousClock.now < deadline else { throw Failure.deadline }
        let previous = sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1)
        // In the v1 journal, the largest catalog entry is the meta table. Its DDL
        // is 1,139 UTF-8 bytes and it has 12 columns. Allow UTF-16 and the record header.
        let length = min(previous, 4096)
        let previousColumns = sqlite3_limit(db, SQLITE_LIMIT_COLUMN, -1)
        let columns = min(previousColumns, 32)
        guard length > 0, columns > 0 else { throw Failure.unavailable }
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, length)
        sqlite3_limit(db, SQLITE_LIMIT_COLUMN, columns)
        defer {
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, previous)
            sqlite3_limit(db, SQLITE_LIMIT_COLUMN, previousColumns)
        }
        guard sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1) == length,
              sqlite3_limit(db, SQLITE_LIMIT_COLUMN, -1) == columns else { throw Failure.unavailable }

        let counter = Counter(deadline: deadline)
        let context = Unmanaged.passUnretained(counter).toOpaque()
        let traceResult = sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_ROW | SQLITE_TRACE_PROFILE), { event, raw, statement, _ in
            guard let raw, let statement else { return 0 }
            Unmanaged<Counter>.fromOpaque(raw).takeUnretainedValue().trace(event, statement: statement)
            return 0
        }, context)
        guard traceResult == SQLITE_OK else { throw Failure.unavailable }
        sqlite3_progress_handler(db, 1, { context in
            guard let context else { return 1 }
            return Unmanaged<Counter>.fromOpaque(context).takeUnretainedValue().interrupt()
        }, context)
        defer {
            sqlite3_trace_v2(db, 0, nil, nil)
            sqlite3_progress_handler(db, 0, nil, nil)
            withExtendedLifetime(counter) {}
        }
        let value: T
        do { value = try operation() } catch { throw counter.failure ?? error }
        if let failure = counter.failure { throw failure }
        guard ContinuousClock.now < deadline else { throw Failure.deadline }
        return value
    }
}
