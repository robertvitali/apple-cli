import AppleKit
import Foundation

/// Exact native body mapping from one captured database observation. Attachment
/// GUIDs here are body metadata only; their database membership still requires
/// validation in that observation's transaction. This is not UI target proof.
enum MessagesUndoSendPart {
    enum Failure: Error { case invalidIndex, unavailableBody, invalidMapping, textMismatch }

    struct Snapshot: Sendable {
        let observation: MessagesUndoSendObservation.Snapshot
        let fullText: String
        let nativeParts: [NativeMessageParts.NativePart]
        let selectedPart: NativeMessageParts.NativePart
        let selectedTextFragments: [String]
    }

    static func resolve(_ observation: MessagesUndoSendObservation.Snapshot,
                        partIndex: Int, deadline: WorkerDeadline,
                        isCancelled: () -> Bool = { false }) throws -> Snapshot {
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            try checkMessagesAXDeadline(deadline)
        }
        try checkpoint()
        guard (0...Int(Int32.max)).contains(partIndex) else { throw Failure.invalidIndex }
        guard case .value(let blob) = observation.attributedBody else { throw Failure.unavailableBody }
        // The decoder enforces fixed blob/object/depth/text/run budgets. A second
        // checkpoint prevents its bounded synchronous work outliving authority.
        let decoded = NativeMessageParts.decode(blob, requireExactText: true)
        try checkpoint()
        guard decoded.status == .decoded, decoded.nativePartsAvailable,
              let parts = decoded.nativeParts, !parts.isEmpty,
              let text = decoded.text else { throw Failure.unavailableBody }
        switch observation.textUTF8 {
        case .null: break
        case .value(let bytes):
            guard bytes == Data(text.utf8) else { throw Failure.textMismatch }
        case .wrongType: throw Failure.textMismatch
        }
        var seen = Set<Int>()
        var selected: NativeMessageParts.NativePart?
        var selectedFragments: [String] = []
        let units = text.utf16.count
        for part in parts {
            try checkpoint()
            guard (0...Int(Int32.max)).contains(part.index), seen.insert(part.index).inserted,
                  !part.utf16Ranges.isEmpty else { throw Failure.invalidMapping }
            var end = 0
            var fragments: [String] = []
            for span in part.utf16Ranges {
                guard span.location >= end, span.location <= units, span.length > 0,
                      span.length <= units - span.location,
                      let range = Range(NSRange(location: span.location, length: span.length), in: text) else {
                    throw Failure.invalidMapping
                }
                end = span.location + span.length
                fragments.append(String(text[range]))
            }
            if part.index == partIndex {
                selected = part
                selectedFragments = fragments
            }
        }
        guard let selected else { throw Failure.invalidIndex }
        try checkpoint()
        return Snapshot(observation: observation, fullText: text, nativeParts: parts,
                        selectedPart: selected, selectedTextFragments: selectedFragments)
    }
}
