import Foundation

/// Conservative database preflight for Apple's documented fifteen-minute,
/// five-edit limit. `.eligible` does not authorize a mutation: fresh native Edit
/// action availability and owned-editor checks are required at the commit point.
enum MessagesEditEligibility {
    enum Assessment: Equatable {
        case eligible, expired, invalidTimestamp, historyUnavailable, editLimitReached, unsupportedText
    }

    static func assess(sentDateRaw: Int64, partIndex: Int, currentText: String,
                       context: ChatDB.ExactNativeEditContext, now: Date) -> Assessment {
        guard supportsEditorText(currentText) else { return .unsupportedText }
        // Modern Messages stores this column as Apple-epoch nanoseconds. Do not
        // apply the display reader's unit heuristic to mutation eligibility.
        let nowApple = now.timeIntervalSince1970 - MessageTime.appleUnixOffset
        guard sentDateRaw > 9_999_999_999, nowApple.isFinite,
              nowApple >= Double(sentDateRaw) / 1_000_000_000 else { return .invalidTimestamp }
        // Whole-second lower bound deliberately expires up to one second early;
        // floating point rounding must not extend the documented window.
        guard nowApple - Double(sentDateRaw / 1_000_000_000) < 900 else { return .expired }
        guard (0...Int(Int32.max)).contains(partIndex), context.summary_info.status == "available",
              context.date_retracted.status == "zero-sentinel", context.date_retracted.raw == 0,
              indices(context.summary_info.retracted_parts) == [],
              MessagesEditVerification.baselineOriginalPartsAreConsistent(context,
                  partIndex: partIndex, currentText: currentText),
              let counts = MessagesEditHistoryTransition.priorEditCounts(context.summary_info.edit_history),
              let edited = indices(context.summary_info.edited_parts), edited == Set(counts.keys) else {
            return .historyUnavailable
        }
        if counts.isEmpty {
            guard context.date_edited.status == "zero-sentinel", context.date_edited.raw == 0 else { return .historyUnavailable }
        } else {
            guard context.date_edited.status == "available" else { return .historyUnavailable }
        }
        let count = counts[Int64(partIndex)] ?? 0
        if count > 0 {
            guard let last = context.summary_info.edit_history.entries?
                .first(where: { $0.original_part_index == Int64(partIndex) })?.events?.last?.body.text,
                  last.utf8.elementsEqual(currentText.utf8) else { return .historyUnavailable }
        }
        // The documented cap belongs to the message, not independently to each
        // part. Conservatively count every recorded revision across its parts.
        let messageEditCount = counts.values.reduce(0, +)
        return messageEditCount < 5 ? .eligible : .editLimitReached
    }

    static func supportsEditorText(_ text: String) -> Bool {
        (try? MessagesAXBodyTextSnapshot(text: text, characterCount: text.utf16.count)) != nil
    }

    private static func indices(_ container: ChatDB.ExactNativeEditContext.Container<ChatDB.ExactNativeEditContext.PartIndex>) -> Set<Int64>? {
        if container.status == "missing-key", container.reason == nil, container.entries == nil { return [] }
        guard container.status == "available", container.reason == nil, let entries = container.entries,
              entries.count <= 256 else { return nil }
        var values = Set<Int64>()
        for (position, entry) in entries.enumerated() {
            guard entry.position == position, entry.status == "available", let index = entry.original_part_index,
                  (0...Int64(Int32.max)).contains(index), entry.raw_integer == index,
                  values.insert(index).inserted else { return nil }
        }
        return values
    }
}
