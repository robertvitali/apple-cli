import Foundation

/// Exact typed equality with the same request budget used by metadata checks.
enum MessagesUndoSendAttributeComparison {
    typealias Value = NativeMessageParts.AttributeValue

    static func equal(_ lhs: Value, _ rhs: Value, budget: inout MessageSummaryPlist.Budget,
                      checkpoint: () throws -> Void, depth: Int = 1) throws -> Bool {
        try checkpoint()
        guard depth <= 32 else { throw MessageSummaryPlist.Failure.resourceLimit }
        guard budget.remainingVisits > 0 else { throw MessageSummaryPlist.Failure.requestLimit }
        budget.remainingVisits -= 1
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.integer(let a), .integer(let b)): return a == b
        case (.string(let a), .string(let b)), (.data(let a), .data(let b)):
            try charge(a.count, budget: &budget)
            try charge(b.count, budget: &budget)
            return a == b
        case (.url(let a, let left), .url(let b, let right)):
            guard a == b else { return false }
            return try equal(left, right, budget: &budget, checkpoint: checkpoint, depth: depth + 1)
        case (.dictionary(let a), .dictionary(let b)):
            guard a.count == b.count else { return false }
            guard a.count <= NativeMessageParts.Limits.default.maxDictEntries else {
                throw MessageSummaryPlist.Failure.resourceLimit
            }
            for key in a.keys { try checkpoint(); try charge(key.count, budget: &budget) }
            for key in b.keys { try checkpoint(); try charge(key.count, budget: &budget) }
            let ak = a.keys.sorted { $0.lexicographicallyPrecedes($1) }
            let bk = b.keys.sorted { $0.lexicographicallyPrecedes($1) }
            for (leftKey, rightKey) in zip(ak, bk) {
                try checkpoint()
                guard leftKey == rightKey, let left = a[leftKey], let right = b[rightKey] else { return false }
                if try !equal(left, right, budget: &budget, checkpoint: checkpoint, depth: depth + 1) { return false }
            }
            return true
        default: return false
        }
    }

    private static func charge(_ count: Int, budget: inout MessageSummaryPlist.Budget) throws {
        guard count <= budget.remainingBytes else { throw MessageSummaryPlist.Failure.requestLimit }
        budget.remainingBytes -= count
    }
}
