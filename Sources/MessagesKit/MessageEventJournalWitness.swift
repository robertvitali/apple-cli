import Foundation
import SQLite3

extension MessageEventJournalSchema {
    /// Logical state observed on one pinned snapshot, before any comparison with
    /// a durable checkpoint. The journal format supplies its digest domain.
    struct StateWitness: Equatable {
        let generation, head, memberships, events: Int64
        let digest: Data
    }

    func stateWitness(domain: StaticString, allowMissingWitness: Bool = false,
                      checkpoint: () throws -> Void) throws -> StateWitness {
        guard sqlite3_get_autocommit(database) == 0,
              sqlite3_txn_state(database, "main") != SQLITE_TXN_NONE else {
            throw MessageEventReplayReader.Failure.snapshotRequired
        }
        var generation: Int64 = 0, head: Int64 = 0
        var validator = MessageEventSummaryRecord.Validator(allowMissingWitness: allowMissingWitness)
        let result = try MessageEventStateDigest.compute(domain: domain) { table, digest in
            let sql: String
            switch table {
            case .metadata: sql = "SELECT id,format,initialized,stream_id,source_epoch,filter_bytes,filter_digest,source_identity,schema_digest,generation,head FROM meta ORDER BY id"
            case .baseline: sql = "SELECT * FROM baseline ORDER BY id"
            case .events: sql = "SELECT * FROM events ORDER BY sequence"
            }
            try checkpoint()
            try rows(sql) { row in
                try checkpoint()
                try digest.beginRow()
                var hashes = Data(), availability = Data(), record = Data()
                for column in 0..<sqlite3_column_count(row) {
                    switch sqlite3_column_type(row, column) {
                    case SQLITE_INTEGER:
                        let value = sqlite3_column_int64(row, column)
                        try digest.integer(value)
                        if table == .metadata {
                            if column == 9 { generation = value }
                            if column == 10 { head = value }
                        }
                    case SQLITE_BLOB:
                        let size = Int(sqlite3_column_bytes(row, column))
                        guard (1...263_174).contains(size) else { throw MessageEventStateDigest.Failure.invalidRow }
                        guard let bytes = sqlite3_column_blob(row, column) else { throw Failure.sqliteCode(SQLITE_NOMEM) }
                        let data = Data(bytes: bytes, count: size)
                        try digest.blob(data)
                        if table == .metadata, column == 7, !MessageEventSourceAnchor.isValidStoredIdentity(data) {
                            throw PersistedEventMetadataFailure.invalidMetadata
                        }
                        if table == .baseline {
                            switch column {
                            case 1, 2:
                                guard (try? MessageEventGUID(storedBytes: data)) != nil else {
                                    throw MessageEventStateDigest.Failure.invalidRow
                                }
                            case 5: hashes = data
                            case 6:
                                guard data.allSatisfy({ $0 < 7 }) else { throw MessageEventStateDigest.Failure.invalidRow }
                                availability = data
                            case 7: record = data
                            case 8: try validator.validate(projection: data, hashes: hashes, availability: availability, record: record)
                            default: break
                            }
                        }
                    default: throw MessageEventStateDigest.Failure.invalidRow
                    }
                }
            }
        }
        try checkpoint()
        return StateWitness(generation: generation, head: head, memberships: Int64(result.memberships),
                            events: Int64(result.events), digest: result.digest)
    }
}
