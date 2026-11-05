import AppleKit
import Foundation

/// Creation-only raw evidence. Never falls back to stale immutable reads or skips
/// a failed source: either the supplied source set is read completely or it fails.
/// Source discovery and name resolution remain separate from this reader.
enum MessagesConversationRawContacts {
    enum Failure: Error { case invalidSources, invalidRecord, limitExceeded }

    struct Record: Sendable {
        let fullName: String
        let nickname: String
        let rawAddress: String
    }

    private static let phoneQuery = """
        SELECT r.ZFIRSTNAME AS first_name, r.ZLASTNAME AS last_name,
               r.ZNICKNAME AS nickname, p.ZFULLNUMBER AS raw_address
        FROM ZABCDRECORD r JOIN ZABCDPHONENUMBER p ON r.Z_PK = p.ZOWNER
        WHERE p.ZFULLNUMBER IS NOT NULL
        """
    private static let emailQuery = """
        SELECT r.ZFIRSTNAME AS first_name, r.ZLASTNAME AS last_name,
               r.ZNICKNAME AS nickname, e.ZADDRESS AS raw_address
        FROM ZABCDRECORD r JOIN ZABCDEMAILADDRESS e ON r.Z_PK = e.ZOWNER
        WHERE e.ZADDRESS IS NOT NULL
        """

    /// Paths are the complete source set supplied by the creation-specific discovery
    /// layer, not the legacy best-effort AddressBook loader. Each database has one
    /// pinned transaction for both address tables; there is no cross-database snapshot.
    /// The total capture has cooperative deadlines and selected-value/row bounds,
    /// not a hard bound on SQLite allocations or synchronous kernel I/O duration.
    static func read(paths: [String], deadline: WorkerDeadline,
                     isCancelled: @escaping () -> Bool = { false }) throws -> [Record] {
        guard (1...64).contains(paths.count), paths.allSatisfy({ path in
            let bytes = Array(path.utf8.prefix(4097))
            return bytes.count <= 4096 && bytes.first == 47 && !bytes.contains(0)
        }), Set(paths).count == paths.count else { throw Failure.invalidSources }
        let captureEnd = ContinuousClock.now.advanced(by: .seconds(5))
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            if deadline.expired || ContinuousClock.now >= captureEnd {
                throw WorkerProtocolError.deadlineExpired
            }
        }
        var records: [Record] = []
        var selectedRows = 0, selectedBytes = 0
        for path in paths {
            try checkpoint()
            let seconds = min(5, Double(deadline.remainingNanoseconds) / 1_000_000_000)
            try SQLiteReader.withBoundedReadTransaction(path: path,
                limits: .init(timeout: seconds, rows: 8193, bytes: 8_388_608, valueBytes: 1_048_576),
                isCancelled: { isCancelled() || deadline.expired || ContinuousClock.now >= captureEnd }) { scope in
                for query in [phoneQuery, emailQuery] {
                    try scope.forEachRow(query) { row in
                        try checkpoint()
                        guard selectedRows < 8192 else { throw Failure.limitExceeded }
                        selectedRows += 1
                        let first = try field("first_name", row, nullable: true)
                        let last = try field("last_name", row, nullable: true)
                        let nickname = try field("nickname", row, nullable: true)
                        let raw = try field("raw_address", row, nullable: false)
                        selectedBytes += first.utf8.count + last.utf8.count + nickname.utf8.count + raw.utf8.count
                        guard selectedBytes <= 8_388_608 else { throw Failure.limitExceeded }
                        let fullName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
                        // Match legacy name construction, but never normalize or discard
                        // an address based on its syntax, including an empty address.
                        if !fullName.trimmingCharacters(in: .whitespaces).isEmpty {
                            records.append(Record(fullName: fullName,
                                nickname: nickname.trimmingCharacters(in: .whitespaces), rawAddress: raw))
                        }
                    }
                }
            }
        }
        try checkpoint()
        return records
    }

    private static func field(_ name: String, _ row: SQLiteReader.Row, nullable: Bool) throws -> String {
        switch row.values[name] {
        case .text(let value):
            guard value.utf8.prefix(513).count <= 512 else { throw Failure.limitExceeded }
            return value
        case .null where nullable: return ""
        default: throw Failure.invalidRecord
        }
    }
}
