import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only, WAL-aware SQLite reader shared by domains that read Apple's local stores
/// (Messages `chat.db`, Mail Envelope Index, Notes `NoteStore.sqlite`). Opens read-only;
/// callers MUST use parameter binds (never string-interpolated SQL). `copyToTemp` snapshots
/// the DB (+ `-wal`/`-shm`) to a temp file first — prefer it for hot/locked stores.
public final class SQLiteReader {
    public enum DBError: Error, CustomStringConvertible {
        case open(String), prepare(String), step(String)
        public var description: String {
            switch self {
            case .open(let m): return "sqlite open failed: \(m)"
            case .prepare(let m): return "sqlite prepare failed: \(m)"
            case .step(let m): return "sqlite step failed: \(m)"
            }
        }
    }

    private var db: OpaquePointer?
    private let tempURL: URL?

    public init(path: String, copyToTemp: Bool = false) throws {
        var openPath = path
        var temp: URL?
        if copyToTemp {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-cli-\(UUID().uuidString).sqlite")
            try FileManager.default.copyItem(atPath: path, toPath: dest.path)
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                try? FileManager.default.copyItem(atPath: path + suffix, toPath: dest.path + suffix)
            }
            openPath = dest.path
            temp = dest
        }
        self.tempURL = temp

        var handle: OpaquePointer?
        guard sqlite3_open_v2(openPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let opened = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open \(openPath)"
            sqlite3_close(handle)
            if let temp { try? FileManager.default.removeItem(at: temp) }
            throw DBError.open(msg)
        }
        self.db = opened
    }

    deinit {
        if let db { sqlite3_close(db) }
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
    }

    /// Run a parameter-bound query. `binds` bind as positional text params (?1, ?2, …).
    /// Rows come back as `[columnName: value?]` (text; callers convert types).
    @discardableResult
    public func query(_ sql: String, _ binds: [String] = []) throws -> [[String: String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, SQLITE_TRANSIENT)
        }
        let columnCount = Int(sqlite3_column_count(stmt))
        var rows: [[String: String?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
            var row: [String: String?] = [:]
            for column in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(stmt, Int32(column)))
                if let text = sqlite3_column_text(stmt, Int32(column)) {
                    row[name] = String(cString: text)
                } else {
                    row[name] = String?.none
                }
            }
            rows.append(row)
        }
        return rows
    }
}
