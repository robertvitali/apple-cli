import AppleKit
import Foundation

/// Attribute-preservation component only. Identity, text/mapping conservation,
/// summary markers and attachment membership must also pass independently.
enum MessagesUndoSendAttributeTransition {
    static func matches(before: MessagesUndoSendPart.Snapshot,
                        after: MessagesUndoSendObservation.Snapshot,
                        deadline: WorkerDeadline, budget: inout MessageSummaryPlist.Budget,
                        isCancelled: () -> Bool = { false }) throws -> Bool {
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            try checkMessagesAXDeadline(deadline)
        }
        try checkpoint()
        guard case .value(let blob) = before.observation.attributedBody else { return false }
        let pre = NativeMessageParts.decodeWithAttributes(blob)
        try checkpoint()
        guard pre.body.status == .decoded, let preRuns = pre.runs, let text = pre.body.text,
              text.utf8.elementsEqual(before.fullText.utf8), let parts = pre.body.nativeParts else { return false }
        let selected = parts.filter { $0.index == before.selectedPart.index }
        guard selected.count == 1 else { return false }
        let removals = selected[0].utf16Ranges.sorted { $0.location < $1.location }
        let length = text.utf16.count
        var end = 0
        for range in removals {
            try checkpoint()
            guard range.location >= end, range.length > 0, range.location <= length,
                  range.length <= length - range.location else { return false }
            end = range.location + range.length
        }
        guard !removals.isEmpty, contiguous(preRuns, length: length) else { return false }
        var expected: [NativeMessageParts.AttributeRun] = []
        var removalIndex = 0
        var outputLength = 0
        for run in preRuns {
            var cursor = run.range.location
            let runEnd = cursor + run.range.length
            while cursor < runEnd {
                try checkpoint()
                while removalIndex < removals.count,
                      cursor >= removals[removalIndex].location + removals[removalIndex].length {
                    removalIndex += 1
                }
                if removalIndex < removals.count, cursor >= removals[removalIndex].location {
                    cursor = min(runEnd, removals[removalIndex].location + removals[removalIndex].length)
                    continue
                }
                let pieceEnd = removalIndex < removals.count ? min(runEnd, removals[removalIndex].location) : runEnd
                let count = pieceEnd - cursor
                guard count > 0, expected.count < 2 * NativeMessageParts.Limits.default.maxRuns else { return false }
                expected.append(.init(range: .init(location: outputLength, length: count), values: run.values))
                outputLength += count
                cursor = pieceEnd
            }
        }
        if expected.isEmpty {
            try checkpoint()
            return after.attributedBody == .null && after.textUTF8 == .null
        }
        guard case .value(let postBlob) = after.attributedBody else { return false }
        let post = NativeMessageParts.decodeWithAttributes(postBlob)
        try checkpoint()
        guard post.body.status == .decoded || post.body.status == .noNativeKeys,
              let actual = post.runs, let postText = post.body.text,
              postText.utf16.count == outputLength,
              contiguous(actual, length: outputLength) else { return false }
        // Compare at the union of run boundaries. This permits harmless run
        // coalescing without ignoring any retained attribute on any text unit.
        var leftIndex = 0, rightIndex = 0, position = 0
        while position < outputLength {
            try checkpoint()
            guard leftIndex < expected.count, rightIndex < actual.count else { return false }
            let left = expected[leftIndex], right = actual[rightIndex]
            guard try MessagesUndoSendAttributeComparison.equal(.dictionary(left.values), .dictionary(right.values),
                budget: &budget, checkpoint: checkpoint) else { return false }
            let leftEnd = left.range.location + left.range.length
            let rightEnd = right.range.location + right.range.length
            let next = min(leftEnd, rightEnd)
            guard next > position else { return false }
            position = next
            if position == leftEnd { leftIndex += 1 }
            if position == rightEnd { rightIndex += 1 }
        }
        try checkpoint()
        return leftIndex == expected.count && rightIndex == actual.count
    }

    private static func contiguous(_ runs: [NativeMessageParts.AttributeRun], length: Int) -> Bool {
        guard runs.count <= NativeMessageParts.Limits.default.maxRuns else { return false }
        var end = 0
        for run in runs {
            guard run.range.location == end, run.range.length > 0,
                  end <= length, run.range.length <= length - end else { return false }
            end += run.range.length
        }
        return end == length
    }
}
