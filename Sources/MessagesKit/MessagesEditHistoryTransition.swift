/// One component of edit verification, not evidence of worker acknowledgement,
/// target identity, eligibility, or the current database body. Callers must read
/// both snapshots with requireExactHistoryText enabled.
enum MessagesEditHistoryTransition {
    private typealias Context = ChatDB.ExactNativeEditContext

    static func matches(
        before: ChatDB.ExactNativeEditContext.Container<ChatDB.ExactNativeEditContext.HistoryGroup>,
        after: ChatDB.ExactNativeEditContext.Container<ChatDB.ExactNativeEditContext.HistoryGroup>,
        originalPartIndex: Int64, previousText: String, replacementText: String
    ) -> Bool {
        guard (0...Int64(Int32.max)).contains(originalPartIndex),
              !sameText(previousText, replacementText),
              let old = validated(before, allowMissing: true),
              let new = validated(after, allowMissing: false),
              let revisions = new[originalPartIndex],
              sameText(revisions.last?.body.text, replacementText) else { return false }
        // Changes to another part cannot be attributed to this edit.
        guard Set(old.keys.filter { $0 != originalPartIndex }) == Set(new.keys.filter { $0 != originalPartIndex }),
              old.allSatisfy({ index, events in
                  index == originalPartIndex || new[index].map { sameEvents(events, $0) } == true
              }) else { return false }
        if let previous = old[originalPartIndex] {
            return sameText(previous.last?.body.text, previousText)
                && revisions.count == previous.count + 1
                && sameEvents(previous, Array(revisions.dropLast()))
        }
        return revisions.count == 2 && sameText(revisions.first?.body.text, previousText)
    }

    /// Counts only complete original-plus-revision histories. The native Edit
    /// action remains the authority for whether another edit is currently allowed.
    static func priorEditCounts(_ history: ChatDB.ExactNativeEditContext.Container<ChatDB.ExactNativeEditContext.HistoryGroup>) -> [Int64: Int]? {
        guard let groups = validated(history, allowMissing: true) else { return nil }
        var result: [Int64: Int] = [:]
        for (index, events) in groups {
            guard events.count >= 2 else { return nil }
            result[index] = events.count - 1
        }
        return result
    }

    private static func validated(_ container: Context.Container<Context.HistoryGroup>,
                                  allowMissing: Bool) -> [Int64: [Context.HistoryEvent]]? {
        if allowMissing && container.status == "missing-key" && container.reason == nil && container.entries == nil {
            return [:]
        }
        guard container.status == "available", container.reason == nil,
              let groups = container.entries, groups.count <= 256 else { return nil }
        var result: [Int64: [Context.HistoryEvent]] = [:]
        var remainingEvents = 256
        var remainingText = 1_048_576
        for group in groups {
            guard group.status == "available", let index = group.original_part_index,
                  (0...Int64(Int32.max)).contains(index), sameText(group.source_key, String(index)),
                  result[index] == nil, let events = group.events, !events.isEmpty,
                  events.count <= remainingEvents else { return nil }
            remainingEvents -= events.count
            for (position, event) in events.enumerated() {
                guard event.position == position, event.status == "available",
                      event.timestamp.status == "available", event.body.status == "available",
                      event.body.reason == nil, let text = event.body.text else { return nil }
                let count = text.utf16.count
                guard count <= remainingText else { return nil }
                remainingText -= count
            }
            result[index] = events
        }
        return result
    }

    private static func sameEvents(_ lhs: [Context.HistoryEvent], _ rhs: [Context.HistoryEvent]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.position == $1.position && $0.timestamp == $1.timestamp && sameText($0.body.text, $1.body.text)
        }
    }

    private static func sameText(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.utf8.elementsEqual(rhs.utf8)
    }
}
