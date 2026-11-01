import Foundation

enum MessagesUndoSendSummaryTransition {
    enum Failure: Error { case invalid }
    private typealias Value = MessageSummaryPlist.Value
    private struct Original {
        let location: Int64
        let length: Int64
    }
    private struct Parsed {
        let fields: [String: Value]
        let retracted: Set<Int>
        let edited: Set<Int>
        let originals: [Int: Original]?
        let historyIndices: Set<Int>
    }

    static func matches(before: MessagesUndoSendPart.Snapshot,
                        after: MessagesUndoSendObservation.Snapshot,
                        budget: inout NativeEditContextDecoder.Budget,
                        checkpoint: () throws -> Void) throws -> Bool {
        let pre = try parse(before.observation.summaryInfo, allowNull: true, budget: &budget, checkpoint: checkpoint)
        let post = try parse(after.summaryInfo, allowNull: false, budget: &budget, checkpoint: checkpoint)
        try checkpoint()
        let live = Set(before.nativeParts.map(\.index))
        let selected = before.selectedPart.index
        guard live.count == before.nativeParts.count, live.contains(selected),
              live.isDisjoint(with: pre.retracted), !pre.retracted.contains(selected) else { return false }
        let domain = live.union(pre.retracted)
        let survivors = live.subtracting([selected])
        guard post.fields["rp"] != nil, post.retracted == pre.retracted.union([selected]),
              survivors.isDisjoint(with: post.retracted),
              pre.edited.isSubset(of: domain), post.edited.isSubset(of: domain),
              pre.historyIndices.isSubset(of: domain), post.historyIndices.isSubset(of: domain),
              pre.edited == post.edited,
              (pre.fields["ep"] == nil) == (post.fields["ep"] == nil) else { return false }
        let pristine = before.observation.dateEdited == .value(0) && pre.edited.isEmpty &&
            pre.retracted.isEmpty && pre.historyIndices.isEmpty &&
            before.nativeParts.allSatisfy { $0.utf16Ranges.count == 1 }
        guard let postOriginals = post.originals,
              valid(postOriginals, domain: domain) else { return false }
        if let preOriginals = pre.originals {
            guard valid(preOriginals, domain: domain) else { return false }
            if pristine, !coherent(preOriginals, parts: before.nativeParts) { return false }
            guard let a = pre.fields["otr"], let b = post.fields["otr"],
                  try MessagesUndoSendMetadataComparison.equal(a, b, budget: &budget.plist, checkpoint: checkpoint) else {
                return false
            }
        } else {
            guard pristine else { return false }
            var expected: [String: Value] = [:]
            for part in before.nativeParts {
                try checkpoint()
                guard let range = part.utf16Ranges.first else { return false }
                expected[String(part.index)] = .dictionary(["lo": .integer(Int64(range.location)),
                                                            "le": .integer(Int64(range.length))])
            }
            guard let actual = post.fields["otr"],
                  try MessagesUndoSendMetadataComparison.equal(.dictionary(expected), actual,
                    budget: &budget.plist, checkpoint: checkpoint) else { return false }
        }
        guard try historyMatches(pre.fields["ec"], post.fields["ec"], selected: selected,
                                 budget: &budget.plist, checkpoint: checkpoint) else { return false }
        let mutable: Set<String> = ["rp", "ep", "otr", "ec"]
        let oldUnknown = pre.fields.filter { !mutable.contains($0.key) }
        let newUnknown = post.fields.filter { !mutable.contains($0.key) }
        return try MessagesUndoSendMetadataComparison.equal(.dictionary(oldUnknown), .dictionary(newUnknown),
                                                              budget: &budget.plist, checkpoint: checkpoint)
    }

    private static func parse(_ field: MessagesUndoSendObservation.Field<Data>, allowNull: Bool,
                              budget: inout NativeEditContextDecoder.Budget,
                              checkpoint: () throws -> Void) throws -> Parsed {
        try checkpoint()
        if case .null = field, allowNull {
            return .init(fields: [:], retracted: [], edited: [], originals: nil, historyIndices: [])
        }
        guard case .value(let data) = field else { throw Failure.invalid }
        let root = try MessageSummaryPlist.decode(data, budget: &budget.plist, checkCancellation: checkpoint)
        guard case .dictionary(let fields) = root else { throw Failure.invalid }
        let summary = try NativeEditContextDecoder.decode(data, budget: &budget,
            requireExactHistoryText: true, checkCancellation: checkpoint)
        guard summary.status == "available",
              [summary.edited_parts.status, summary.retracted_parts.status,
               summary.original_parts.status, summary.edit_history.status].allSatisfy({
                  $0 == "available" || $0 == "missing-key"
              }) else { throw Failure.invalid }
        func indexes(_ entries: [ChatDB.ExactNativeEditContext.PartIndex]?) throws -> Set<Int> {
            var result = Set<Int>()
            for entry in entries ?? [] {
                try checkpoint()
                guard entry.status == "available", let value = entry.original_part_index,
                      (0...Int64(Int32.max)).contains(value), result.insert(Int(value)).inserted else { throw Failure.invalid }
            }
            return result
        }
        let retracted = try indexes(summary.retracted_parts.entries)
        let edited = try indexes(summary.edited_parts.entries)
        var originals: [Int: Original]?
        if summary.original_parts.status == "available" {
            originals = [:]
            for entry in summary.original_parts.entries ?? [] {
                try checkpoint()
                guard entry.status == "available", let index = entry.original_part_index,
                      (0...Int64(Int32.max)).contains(index),
                      let location = entry.location_raw, let length = entry.length_raw,
                      location >= 0, length > 0, !location.addingReportingOverflow(length).overflow,
                      originals?[Int(index)] == nil else { throw Failure.invalid }
                originals?[Int(index)] = .init(location: location, length: length)
            }
        }
        var history = Set<Int>()
        for entry in summary.edit_history.entries ?? [] {
            try checkpoint()
            guard entry.status == "available", let index = entry.original_part_index,
                  (0...Int64(Int32.max)).contains(index), history.insert(Int(index)).inserted else { throw Failure.invalid }
        }
        return .init(fields: fields, retracted: retracted, edited: edited,
                     originals: originals, historyIndices: history)
    }

    private static func valid(_ originals: [Int: Original], domain: Set<Int>) -> Bool {
        guard Set(originals.keys) == domain else { return false }
        var end: Int64 = 0
        for range in originals.values.sorted(by: { $0.location < $1.location }) {
            guard range.location >= end, range.length > 0,
                  !range.location.addingReportingOverflow(range.length).overflow else { return false }
            end = range.location + range.length
        }
        return true
    }

    private static func coherent(_ originals: [Int: Original], parts: [NativeMessageParts.NativePart]) -> Bool {
        parts.allSatisfy { part in
            guard part.utf16Ranges.count == 1, let actual = originals[part.index],
                  let expected = part.utf16Ranges.first else { return false }
            return actual.location == Int64(expected.location) && actual.length == Int64(expected.length)
        }
    }

    private static func historyMatches(_ before: Value?, _ after: Value?, selected: Int,
                                       budget: inout MessageSummaryPlist.Budget,
                                       checkpoint: () throws -> Void) throws -> Bool {
        guard let before else { return after == nil }
        guard case .dictionary(let fields) = before else { return false }
        // Validate even subtrees that disappear. Equality with itself still
        // traverses every typed value, refusing nonfinite scalars within the
        // shared request budget before any selected history is removed.
        guard try MessagesUndoSendMetadataComparison.equal(before, before,
            budget: &budget, checkpoint: checkpoint) else { return false }
        var removed = fields
        removed.removeValue(forKey: String(selected))
        guard let after else { return removed.isEmpty }
        guard case .dictionary = after else { return false }
        if try MessagesUndoSendMetadataComparison.equal(before, after, budget: &budget, checkpoint: checkpoint) {
            return true
        }
        return try MessagesUndoSendMetadataComparison.equal(.dictionary(removed), after,
                                                               budget: &budget, checkpoint: checkpoint)
    }
}
