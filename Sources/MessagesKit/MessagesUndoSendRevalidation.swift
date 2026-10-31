import Foundation

/// Compares two independently captured, bounded pre-action snapshots. Matching
/// evidence grants no action authority and is never post-action verification.
/// Callers must freshly establish time eligibility, sandbox policy and native
/// target identity immediately before any action.
enum MessagesUndoSendRevalidation {
    static func matches(_ baseline: MessagesUndoSendTargetSnapshot.Snapshot,
                        _ current: MessagesUndoSendTargetSnapshot.Snapshot) -> Bool {
        let before = baseline.part.observation
        let after = current.part.observation
        guard before.identity.matches(after.identity),
              before.isFromMe == after.isFromMe, before.isSent == after.isSent,
              before.error == after.error, before.serviceUTF8 == after.serviceUTF8,
              before.dateEdited == after.dateEdited, before.dateRetracted == after.dateRetracted,
              before.textUTF8 == after.textUTF8, before.attributedBody == after.attributedBody,
              before.summaryInfo == after.summaryInfo,
              sameBytes(baseline.part.fullText, current.part.fullText),
              samePart(baseline.part.selectedPart, current.part.selectedPart),
              baseline.part.nativeParts.count == current.part.nativeParts.count,
              zip(baseline.part.nativeParts, current.part.nativeParts).allSatisfy({ samePart($0, $1) }),
              baseline.part.selectedTextFragments.count == current.part.selectedTextFragments.count,
              zip(baseline.part.selectedTextFragments, current.part.selectedTextFragments).allSatisfy({ sameBytes($0, $1) }),
              baseline.attachments == current.attachments,
              baseline.selectedAttachment == current.selectedAttachment else { return false }
        return true
    }

    private static func samePart(_ lhs: NativeMessageParts.NativePart,
                                 _ rhs: NativeMessageParts.NativePart) -> Bool {
        guard lhs.index == rhs.index, lhs.utf16Ranges == rhs.utf16Ranges else { return false }
        switch (lhs.attachmentGUID, rhs.attachmentGUID) {
        case (nil, nil): return true
        case (let left?, let right?): return sameBytes(left, right)
        default: return false
        }
    }

    private static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}
