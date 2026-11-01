import AppleKit
import Foundation

/// Verifies only the body component of a persisted retraction transition.
/// Metadata, identity, attachment membership and native target proof remain
/// separate requirements. A true result alone never establishes Undo Send.
enum MessagesUndoSendBodyTransition {
    private struct Span {
        let range: NativeMessageParts.UTF16Range
        let index: Int
    }

    static func matches(before: MessagesUndoSendPart.Snapshot,
                        after: MessagesUndoSendObservation.Snapshot,
                        deadline: WorkerDeadline, isCancelled: () -> Bool = { false }) throws -> Bool {
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            try checkMessagesAXDeadline(deadline)
        }
        try checkpoint()
        let limits = NativeMessageParts.Limits.default
        guard before.fullText.utf16.count <= limits.maxTextUTF16Units,
              !before.nativeParts.isEmpty, before.nativeParts.count <= limits.maxRuns else { return false }
        let units = Array(before.fullText.utf16)
        var spans: [Span] = []
        var indices = Set<Int>()
        var expectedParts: [Int: NativeMessageParts.NativePart] = [:]
        let selected = before.selectedPart.index
        for part in before.nativeParts {
            try checkpoint()
            guard (0...Int(Int32.max)).contains(part.index), indices.insert(part.index).inserted,
                  !part.utf16Ranges.isEmpty,
                  part.utf16Ranges.count <= limits.maxRuns - spans.count else { return false }
            for range in part.utf16Ranges {
                guard range.location >= 0, range.length > 0, range.location <= units.count,
                      range.length <= units.count - range.location,
                      boundary(range.location, in: units),
                      boundary(range.location + range.length, in: units) else { return false }
                spans.append(.init(range: range, index: part.index))
            }
            if part.index != selected {
                expectedParts[part.index] = .init(index: part.index, utf16Ranges: [],
                                                 attachmentGUID: part.attachmentGUID)
            }
        }
        guard indices.contains(selected) else { return false }
        spans.sort { $0.range.location < $1.range.location }
        var end = 0
        var deleted = 0
        var selectedSpans: [NativeMessageParts.UTF16Range] = []
        for span in spans {
            try checkpoint()
            guard span.range.location >= end else { return false }
            end = span.range.location + span.range.length
            if span.index == selected {
                selectedSpans.append(span.range)
                deleted += span.range.length
            } else {
                expectedParts[span.index]?.utf16Ranges.append(.init(
                    location: span.range.location - deleted, length: span.range.length))
            }
        }
        var projected: [UInt16] = []
        projected.reserveCapacity(units.count - deleted)
        var removalIndex = 0
        for offset in units.indices {
            if offset % 1024 == 0 { try checkpoint() }
            while removalIndex < selectedSpans.count,
                  offset >= selectedSpans[removalIndex].location + selectedSpans[removalIndex].length {
                removalIndex += 1
            }
            let removed = removalIndex < selectedSpans.count && offset >= selectedSpans[removalIndex].location
            if !removed { projected.append(units[offset]) }
        }
        try checkpoint()
        if expectedParts.isEmpty {
            return projected.isEmpty && after.attributedBody == .null && after.textUTF8 == .null
        }
        guard case .value(let blob) = after.attributedBody else { return false }
        let decoded = NativeMessageParts.decode(blob, requireExactText: true)
        try checkpoint()
        guard decoded.status == .decoded, decoded.nativePartsAvailable,
              let parts = decoded.nativeParts, let text = decoded.text,
              parts.count == expectedParts.count,
              Data(text.utf8) == Data(String(decoding: projected, as: UTF16.self).utf8) else { return false }
        var seen = Set<Int>()
        for part in parts {
            try checkpoint()
            guard seen.insert(part.index).inserted, let expected = expectedParts[part.index],
                  part.utf16Ranges == expected.utf16Ranges else { return false }
            switch (part.attachmentGUID, expected.attachmentGUID) {
            case (nil, nil): break
            case (let actual?, let wanted?):
                guard actual.utf8.elementsEqual(wanted.utf8) else { return false }
            default: return false
            }
        }
        let consistent = try MessagesUndoSendBodyConsistency.matches(after.textUTF8,
            fullText: text, nativeParts: parts, checkpoint: checkpoint)
        try checkpoint()
        return consistent
    }

    private static func boundary(_ offset: Int, in units: [UInt16]) -> Bool {
        guard offset > 0, offset < units.count else { return true }
        return !((0xd800...0xdbff).contains(units[offset - 1]) && (0xdc00...0xdfff).contains(units[offset]))
    }
}
