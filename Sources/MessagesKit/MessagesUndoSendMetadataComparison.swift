import Foundation

/// Bounded, type-preserving equality for retained decoded metadata. Swift's
/// String equality permits canonical equivalence, so it cannot establish byte
/// preservation for keys or values. Callers share this budget with decoding.
enum MessagesUndoSendMetadataComparison {
    static func equal(_ lhs: MessageSummaryPlist.Value, _ rhs: MessageSummaryPlist.Value,
                      budget: inout MessageSummaryPlist.Budget,
                      checkpoint: () throws -> Void) throws -> Bool {
        try equal(lhs, rhs, depth: 1, budget: &budget, checkpoint: checkpoint)
    }

    private static func equal(_ lhs: MessageSummaryPlist.Value, _ rhs: MessageSummaryPlist.Value,
                              depth: Int, budget: inout MessageSummaryPlist.Budget,
                              checkpoint: () throws -> Void) throws -> Bool {
        try checkpoint()
        guard depth <= 32 else { throw MessageSummaryPlist.Failure.resourceLimit }
        guard budget.remainingVisits > 0 else { throw MessageSummaryPlist.Failure.requestLimit }
        budget.remainingVisits -= 1
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.real(let a), .real(let b)), (.date(let a), .date(let b)):
            return a.isFinite && b.isFinite && a.bitPattern == b.bitPattern
        case (.string(let a), .string(let b)):
            try charge(a.utf8.count, b.utf8.count, budget: &budget)
            return a.utf8.elementsEqual(b.utf8)
        case (.data(let a), .data(let b)):
            try charge(a.count, b.count, budget: &budget)
            return a == b
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            guard a.count <= 4096 else { throw MessageSummaryPlist.Failure.resourceLimit }
            for (left, right) in zip(a, b) {
                if try !equal(left, right, depth: depth + 1, budget: &budget, checkpoint: checkpoint) { return false }
            }
            return true
        case (.dictionary(let a), .dictionary(let b)):
            guard a.count == b.count else { return false }
            guard a.count <= 4096 else { throw MessageSummaryPlist.Failure.resourceLimit }
            // Charge all keys before sorting; total key bytes stay within the
            // same request budget even when a mismatch is found subsequently.
            for key in a.keys { try checkpoint(); try charge(key.utf8.count, 0, budget: &budget) }
            for key in b.keys { try checkpoint(); try charge(key.utf8.count, 0, budget: &budget) }
            let leftKeys = a.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let rightKeys = b.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (leftKey, rightKey) in zip(leftKeys, rightKeys) {
                try checkpoint()
                guard leftKey.utf8.elementsEqual(rightKey.utf8),
                      let left = a[leftKey], let right = b[rightKey] else { return false }
                if try !equal(left, right, depth: depth + 1, budget: &budget, checkpoint: checkpoint) { return false }
            }
            return true
        default: return false
        }
    }

    private static func charge(_ first: Int, _ second: Int,
                               budget: inout MessageSummaryPlist.Budget) throws {
        guard first <= budget.remainingBytes else { throw MessageSummaryPlist.Failure.requestLimit }
        budget.remainingBytes -= first
        guard second <= budget.remainingBytes else { throw MessageSummaryPlist.Failure.requestLimit }
        budget.remainingBytes -= second
    }
}
