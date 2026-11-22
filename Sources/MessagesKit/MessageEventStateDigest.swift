import CryptoKit
import Foundation

/// Computes a journal format's logical-state digest, independently of SQLite's page layout.
enum MessageEventStateDigest {
    enum Failure: Error { case invalidRow, limitExceeded }
    enum Table: String, CaseIterable {
        case metadata = "meta", baseline, events

        fileprivate var rowLimit: Int {
            switch self {
            case .metadata: return 1
            case .baseline: return MessageEventJournalLimits.memberships
            case .events: return MessageEventJournalLimits.events
            }
        }

        fileprivate var columns: [Column] {
            switch self {
            case .metadata:
                return [.integer, .integer, .integer, .blob(36...36), .blob(36...36), .blob(6...263_174), .blob(32...32),
                        .blob(29...29), .blob(32...32), .integer, .integer]
            case .baseline:
                return [.integer, .blob(1...1_024), .blob(1...1_024), .integer, .integer, .blob(256...256), .blob(8...8),
                        .blob(100...100), .blob(1...65_536)]
            case .events: return [.integer, .payload]
            }
        }
    }

    fileprivate enum Column { case integer, blob(ClosedRange<Int>), payload }

    struct Result {
        let digest: Data
        let memberships, events: Int
    }

    struct Rows {
        private let table: Table
        private let columns: [Column]
        private var next: Int
        private var payloadBytes = 0
        fileprivate private(set) var count = 0
        fileprivate var hash: SHA256
        fileprivate var bytes: Int

        fileprivate init(_ table: Table, hash: SHA256, bytes: Int) {
            self.table = table
            columns = table.columns
            next = columns.count
            self.hash = hash
            self.bytes = bytes
        }

        mutating func beginRow() throws {
            guard next == columns.count else { throw Failure.invalidRow }
            guard count < table.rowLimit else { throw Failure.limitExceeded }
            count += 1
            next = 0
        }

        mutating func integer(_ value: Int64) throws {
            guard next < columns.count, case .integer = columns[next] else { throw Failure.invalidRow }
            try consume(17)
            put(UInt8(ascii: "i"))
            put(Int64(8).bigEndian)
            put(value.bigEndian)
            next += 1
        }

        mutating func blob(_ data: Data) throws {
            guard next < columns.count, !data.isEmpty else { throw Failure.invalidRow }
            switch columns[next] {
            case .integer: throw Failure.invalidRow
            case .blob(let lengths):
                guard lengths.contains(data.count) else { throw Failure.invalidRow }
            case .payload:
                guard data.count <= 65_536, data.count <= MessageEventJournalLimits.eventBytes - payloadBytes else { throw Failure.limitExceeded }
            }
            try consume(9 + data.count)
            if case .payload = columns[next] { payloadBytes += data.count }
            put(UInt8(ascii: "b"))
            put(Int64(data.count).bigEndian)
            hash.update(data: data)
            next += 1
        }

        fileprivate mutating func finish() throws {
            guard next == columns.count, table != .metadata || count == 1 else { throw Failure.invalidRow }
            try consume(9)
            put(UInt8(ascii: "#"))
            put(Int64(count).bigEndian)
        }

        fileprivate mutating func consume(_ n: Int) throws {
            guard n <= (512 << 20) - bytes else { throw Failure.limitExceeded }
            bytes += n
        }

        private mutating func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value) { hash.update(bufferPointer: $0) }
        }
    }

    /// The format supplies its fixed domain prefix. The caller supplies complete
    /// rows in primary-key order from one pinned snapshot, excluding the stored digest.
    static func compute(domain: StaticString, scan: (Table, inout Rows) throws -> Void) throws -> Result {
        var hash = SHA256()
        guard domain.utf8CodeUnitCount <= 512 << 20 else { throw Failure.limitExceeded }
        let prefix = domain.withUTF8Buffer { Data($0) }
        hash.update(data: prefix)
        var bytes = prefix.count
        var memberships = 0, events = 0
        for table in Table.allCases {
            var rows = Rows(table, hash: hash, bytes: bytes)
            let name = Data(table.rawValue.utf8)
            try rows.consume(name.count)
            rows.hash.update(data: name)
            try scan(table, &rows)
            try rows.finish()
            hash = rows.hash
            bytes = rows.bytes
            switch table {
            case .metadata: break
            case .baseline: memberships = rows.count
            case .events: events = rows.count
            }
        }
        return Result(digest: Data(hash.finalize()), memberships: memberships, events: events)
    }
}
