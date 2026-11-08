import AppleKit

enum MessagesNativeTargetLookup {
    // A positive ID can be hidden in a REAL that truncates to it, or a TEXT/BLOB key.
    // Unary + keeps the numeric bound free of affinity even on untyped join columns.
    // Both range endpoints can then constrain the index before CAST filters candidates.
    static func membershipPredicate(column: String, id: Int64) -> String {
        let ceiling = id == .max ? "''" : "(CAST(?1 AS INTEGER) + 1)"
        return """
            (\(column) BETWEEN +CAST(?1 AS INTEGER) AND \(ceiling) OR \(column) >= '')
            AND (\(column) = CAST(?1 AS INTEGER) OR CAST(\(column) AS INTEGER) = CAST(?1 AS INTEGER))
            """
    }

    static func one(_ scope: SQLiteReadTransaction, _ sql: String, _ binds: [String]) throws -> SQLiteReader.Row {
        var result: SQLiteReader.Row?
        try scope.forEachRow(sql, binds) { row in
            guard result == nil else { throw MessagesAXNavigationError.targetDrift }
            result = row
        }
        guard let result else { throw MessagesAXNavigationError.targetDrift }
        return result
    }
}
