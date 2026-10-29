import Foundation

/// Persisted transition predicate over two strict reader snapshots. The caller
/// must additionally require the matching worker acknowledgement under the
/// automation lock. This predicate neither sends an edit nor proves causality.
enum MessagesEditVerification {
    private typealias Context = ChatDB.ExactNativeEditContext
    private typealias Snapshot = MessagesEditTargetResolver.Snapshot

    static func matches(before: MessagesEditTargetResolver.Snapshot,
                        after: MessagesEditTargetResolver.Snapshot, replacement: String) -> Bool {
        guard !replacement.isEmpty, replacement.utf8.count <= 65_536,
              sameTarget(before: before, after: after),
              same(after.partText, replacement), bodyMatches(before: before, after: after, replacement: replacement),
              noRetractions(before.editContext), noRetractions(after.editContext),
              originalPartsMatch(before: before, after: after),
              before.editContext.summary_info.status == "available", after.editContext.summary_info.status == "available",
              let oldEdited = editedParts(before.editContext.summary_info.edited_parts),
              let newEdited = editedParts(after.editContext.summary_info.edited_parts),
              newEdited == oldEdited.union([Int64(before.partIndex)]),
              MessagesEditHistoryTransition.matches(before: before.editContext.summary_info.edit_history,
                after: after.editContext.summary_info.edit_history, originalPartIndex: Int64(before.partIndex),
                previousText: before.partText, replacementText: replacement) else { return false }
        let stamp = after.editContext.date_edited
        guard stamp.status == "available", let seconds = stamp.normalized_seconds,
              let event = after.editContext.summary_info.edit_history.entries?
                .first(where: { $0.original_part_index == Int64(before.partIndex) })?.events?.last,
              event.timestamp.normalized_seconds == seconds else { return false }
        let sent = NativeMessageStatusDecoder.timestamp(raw: before.sentDateRaw)
        guard let sentSeconds = sent.normalized_seconds, seconds >= sentSeconds else { return false }
        let oldStamp = before.editContext.date_edited
        if oldStamp.status != "zero-sentinel" {
            guard oldStamp.status == "available", let oldSeconds = oldStamp.normalized_seconds,
                  seconds >= oldSeconds else { return false }
        }
        return true
    }

    /// These bindings cannot change while waiting for edit persistence.
    static func sameTarget(before: MessagesEditTargetResolver.Snapshot,
                           after: MessagesEditTargetResolver.Snapshot) -> Bool {
        before.chatRowid == after.chatRowid && same(before.chatGUID, after.chatGUID)
            && before.messageRowid == after.messageRowid && same(before.messageGUID, after.messageGUID)
            && before.sentDateRaw == after.sentDateRaw && before.chatStyle == after.chatStyle
            && before.partIndex == after.partIndex
            && before.participantHandles.count == after.participantHandles.count
            && zip(before.participantHandles, after.participantHandles).allSatisfy({ same($0, $1) })
    }

    private static func bodyMatches(before: Snapshot, after: Snapshot, replacement: String) -> Bool {
        guard before.nativeParts.count == after.nativeParts.count,
              Set(before.nativeParts.map(\.index)).count == before.nativeParts.count,
              Set(after.nativeParts.map(\.index)).count == after.nativeParts.count,
              let selected = before.nativeParts.first(where: { $0.index == before.partIndex }),
              selected.attachmentGUID == nil, selected.utf16Ranges.count == 1,
              let interval = selected.utf16Ranges.first, interval.location >= 0, interval.length >= 0,
              interval.location <= before.fullText.utf16.count,
              interval.length <= before.fullText.utf16.count - interval.location,
              let range = Range(NSRange(location: interval.location, length: interval.length), in: before.fullText),
              same(String(before.fullText[range]), before.partText) else { return false }
        let expected = String(before.fullText[..<range.lowerBound]) + replacement + String(before.fullText[range.upperBound...])
        guard same(expected, after.fullText) else { return false }
        let end = interval.location + interval.length
        let growth = replacement.utf16.count - interval.length
        for old in before.nativeParts {
            guard let new = after.nativeParts.first(where: { $0.index == old.index }),
                  sameOptional(old.attachmentGUID, new.attachmentGUID) else { return false }
            if old.index == before.partIndex {
                guard new.utf16Ranges == [.init(location: interval.location, length: replacement.utf16.count)] else { return false }
            } else {
                var expectedRanges: [NativeMessageParts.UTF16Range] = []
                for other in old.utf16Ranges {
                    guard other.location >= 0, other.length >= 0,
                          other.location <= before.fullText.utf16.count,
                          other.length <= before.fullText.utf16.count - other.location else { return false }
                    if other.location >= end {
                        expectedRanges.append(.init(location: other.location + growth, length: other.length))
                    } else if other.location + other.length <= interval.location {
                        expectedRanges.append(other)
                    } else { return false }
                }
                guard new.utf16Ranges == expectedRanges else { return false }
            }
        }
        return true
    }

    static func baselineOriginalPartsAreConsistent(_ context: ChatDB.ExactNativeEditContext,
                                                   partIndex: Int, currentText: String) -> Bool {
        guard let originals = originalParts(context.summary_info.original_parts),
              let counts = MessagesEditHistoryTransition.priorEditCounts(context.summary_info.edit_history) else { return false }
        for index in counts.keys {
            guard let original = originals[index],
                  let firstText = context.summary_info.edit_history.entries?
                    .first(where: { $0.original_part_index == index })?.events?.first?.body.text,
                  original.length_raw == Int64(firstText.utf16.count) else { return false }
        }
        if counts[Int64(partIndex)] == nil, let selected = originals[Int64(partIndex)] {
            guard selected.length_raw == Int64(currentText.utf16.count) else { return false }
        }
        return true
    }

    private static func originalPartsMatch(before: Snapshot, after: Snapshot) -> Bool {
        guard let old = originalParts(before.editContext.summary_info.original_parts),
              let new = originalParts(after.editContext.summary_info.original_parts),
              let selected = new[Int64(before.partIndex)],
              let firstText = after.editContext.summary_info.edit_history.entries?
                .first(where: { $0.original_part_index == Int64(before.partIndex) })?.events?.first?.body.text,
              selected.length_raw == Int64(firstText.utf16.count),
              Set(new.keys) == Set(old.keys).union([Int64(before.partIndex)]),
              old.allSatisfy({ new[$0.key] == $0.value }) else { return false }
        if old[Int64(before.partIndex)] == nil {
            guard let part = before.nativeParts.first(where: { $0.index == before.partIndex }),
                  part.utf16Ranges.count == 1, let range = part.utf16Ranges.first,
                  selected.location_raw == Int64(range.location),
                  selected.length_raw == Int64(range.length) else { return false }
        }
        return true
    }

    private static func originalParts(_ container: Context.Container<Context.OriginalPart>) -> [Int64: Context.OriginalPart]? {
        if container.status == "missing-key", container.reason == nil, container.entries == nil { return [:] }
        guard container.status == "available", container.reason == nil, let entries = container.entries,
              entries.count <= 256 else { return nil }
        var result: [Int64: Context.OriginalPart] = [:]
        for entry in entries {
            guard entry.status == "available", let index = entry.original_part_index,
                  (0...Int64(Int32.max)).contains(index), same(entry.source_key, String(index)),
                  let location = entry.location_raw, let length = entry.length_raw,
                  location >= 0, length >= 0, !location.addingReportingOverflow(length).overflow,
                  result[index] == nil else { return nil }
            result[index] = entry
        }
        return result
    }

    private static func noRetractions(_ context: Context) -> Bool {
        context.date_retracted.status == "zero-sentinel" && context.date_retracted.raw == 0
            && editedParts(context.summary_info.retracted_parts) == []
    }

    private static func editedParts(_ container: Context.Container<Context.PartIndex>) -> Set<Int64>? {
        if container.status == "missing-key", container.reason == nil, container.entries == nil { return [] }
        guard container.status == "available", container.reason == nil, let entries = container.entries,
              entries.count <= 256 else { return nil }
        var indices = Set<Int64>()
        for (position, entry) in entries.enumerated() {
            guard entry.position == position, entry.status == "available", let index = entry.original_part_index,
                  (0...Int64(Int32.max)).contains(index), entry.raw_integer == index,
                  indices.insert(index).inserted else { return nil }
        }
        return indices
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    private static func sameOptional(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let lhs?, let rhs?): return same(lhs, rhs)
        default: return false
        }
    }
}
