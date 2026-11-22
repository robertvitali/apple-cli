import AppleKit
import Foundation

/// Source capture reads must stream without a temporary sort, table or automatic index.
enum MessageEventSourcePlan {
    enum Failure: Error { case unsupportedPlan, invalidMembership }

    @discardableResult
    static func requireStreaming(_ sql: String, bindings: [String], in db: SQLiteReadTransaction,
                                 inspect: (String, SQLiteReader.Row) throws -> Void = { _, _ in }) throws -> [String] {
        var details: [String] = []
        try db.forEachRow("EXPLAIN QUERY PLAN " + sql, bindings) { row in
            guard case .text(let detail)? = row.values["detail"], !detail.hasPrefix("USE TEMP B-TREE") else {
                throw Failure.unsupportedPlan
            }
            details.append(detail)
        }
        var sawInstruction = false
        try db.forEachRow("EXPLAIN " + sql, bindings) { row in
            guard case .text(let opcode)? = row.values["opcode"] else { throw Failure.unsupportedPlan }
            switch opcode {
            case "SorterOpen", "SorterSort", "OpenEphemeral", "OpenAutoindex", "Sort": throw Failure.unsupportedPlan
            default: try inspect(opcode, row)
            }
            sawInstruction = true
        }
        guard sawInstruction, !details.isEmpty else { throw Failure.unsupportedPlan }
        return details
    }
}

enum MessageEventConversationLookup {
    typealias Failure = MessageEventSourcePlan.Failure

    struct Pass {
        let id: Int64?
        let guid: Data?
        var bindings: [String] { id.map { [String($0)] } ?? [] }
    }

    private static let sql = """
        SELECT _rowid_ AS cid, CAST(guid AS BLOB) AS cg, typeof(guid) AS kind
        FROM chat WHERE guid COLLATE BINARY=?1 LIMIT 2
        """

    /// The index name in EXPLAIN QUERY PLAN can contain arbitrary words and punctuation.
    /// Require the planner's operation and an equality range over the bound key in the bytecode.
    static func requireIndex(in db: SQLiteReadTransaction) throws {
        var key: Int64?
        var cursor: Int64?
        var endOpcode: String?
        var bounded = false
        let details = try MessageEventSourcePlan.requireStreaming(sql, bindings: ["plan"], in: db) { opcode, row in
            switch opcode {
            case "Rewind", "Last": throw Failure.unsupportedPlan
            case "Variable":
                guard row.values["p1"] == .integer(1), case .integer(let register)? = row.values["p2"] else {
                    throw Failure.unsupportedPlan
                }
                key = register
            case "SeekGE", "SeekLE":
                guard let key, row.values["p3"] == .integer(key), row.values["p4"] == .text("1"),
                      case .integer(let id)? = row.values["p1"] else { throw Failure.unsupportedPlan }
                cursor = id
                endOpcode = opcode == "SeekGE" ? "IdxGT" : "IdxLT"
            case "IdxGT", "IdxLT":
                guard let cursor, let key, opcode == endOpcode, row.values["p1"] == .integer(cursor),
                      row.values["p3"] == .integer(key), row.values["p4"] == .text("1") else {
                    throw Failure.unsupportedPlan
                }
                bounded = true
            default: break
            }
        }
        guard bounded, details.count == 1, let detail = details.first,
              detail.hasPrefix("SEARCH chat USING "), detail.hasSuffix(" (guid=?)") else { throw Failure.unsupportedPlan }
    }

    static func passes(for filter: MessageEventFilter, in db: SQLiteReadTransaction) throws -> [Pass] {
        guard let members = filter.conversations else { return [Pass(id: nil, guid: nil)] }
        try requireIndex(in: db)
        var seen = Set<Int64>()
        var matches: [(id: Int64, guid: Data)] = []
        for member in members {
            var hit: (id: Int64, guid: Data)?
            try db.forEachRow(sql, [member.rawValue]) { row in
                guard hit == nil, case .integer(let id)? = row.values["cid"], id > 0,
                      row.values["kind"] == .text("text"), case .blob(let bytes)? = row.values["cg"],
                      bytes == member.bytes, seen.insert(id).inserted else { throw Failure.invalidMembership }
                hit = (id, bytes)
            }
            if let hit { matches.append(hit) }
        }
        return matches.sorted { $0.id < $1.id }.map { Pass(id: $0.id, guid: $0.guid) }
    }
}
