import AppleKit
import Foundation

/// Verifies one persisted exact-part retraction transition. This never proves
/// causal UI selection or authorizes a native action; those remain separate.
enum MessagesUndoSendTransition {
    enum Reason: String, Equatable, Sendable {
        case identity, storage, timestamp, membership, metadata, body, attributes, resources, unchanged
    }
    enum Assessment: Equatable, Sendable {
        case verified
        case unverified(Reason)
    }

    static func assess(before: MessagesUndoSendTargetSnapshot.Snapshot,
                       after: MessagesUndoSendPostSnapshot.Snapshot,
                       deadline: WorkerDeadline, isCancelled: () -> Bool = { false }) throws -> Assessment {
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            try checkMessagesAXDeadline(deadline)
        }
        try checkpoint()
        let pre = before.part.observation, post = after.observation
        guard pre.identity.matches(post.identity) else { return .unverified(.identity) }
        for observation in [pre, post] {
            guard observation.isFromMe == .value(1), observation.isSent == .value(1),
                  observation.error == .value(0), observation.serviceUTF8 == .value(Data("iMessage".utf8)) else {
                return .unverified(.storage)
            }
        }
        if pre.dateEdited == post.dateEdited, pre.dateRetracted == post.dateRetracted,
           pre.textUTF8 == post.textUTF8, pre.attributedBody == post.attributedBody,
           pre.summaryInfo == post.summaryInfo, before.attachments == after.attachments {
            return .unverified(.unchanged)
        }
        guard pre.dateRetracted == .value(0), post.dateRetracted == .value(0),
              case .value(let oldEdited) = pre.dateEdited, case .value(let newEdited) = post.dateEdited,
              pre.identity.sentDateRaw > 9_999_999_999,
              oldEdited == 0 || oldEdited > 9_999_999_999,
              newEdited > 9_999_999_999, newEdited >= oldEdited,
              newEdited >= pre.identity.sentDateRaw else { return .unverified(.timestamp) }
        let selected: MessagesAttachmentRetrievalState.Identity?
        do {
            selected = try MessagesUndoSendAttachmentBinding.bind(nativeParts: before.part.nativeParts,
                selectedIndex: before.part.selectedPart.index, members: before.attachments)
        } catch is MessagesUndoSendAttachmentBinding.Failure {
            return .unverified(.membership)
        }
        guard selected == before.selectedAttachment else { return .unverified(.membership) }
        let expected = before.attachments.filter { $0 != selected }.sorted { $0.rowid < $1.rowid }
        guard after.attachments.count <= MessagesAttachmentRetrievalState.maximumAttachments,
              Set(after.attachments.map(\.rowid)).count == after.attachments.count,
              Set(after.attachments.map(\.guid)).count == after.attachments.count,
              after.attachments.sorted(by: { $0.rowid < $1.rowid }) == expected else { return .unverified(.membership) }
        var budget = NativeEditContextDecoder.Budget()
        do {
            guard try MessagesUndoSendSummaryTransition.matches(before: before.part, after: post,
                budget: &budget, checkpoint: checkpoint) else { return .unverified(.metadata) }
            guard try MessagesUndoSendBodyTransition.matches(before: before.part, after: post,
                deadline: deadline, isCancelled: isCancelled) else { return .unverified(.body) }
            guard try MessagesUndoSendAttributeTransition.matches(before: before.part, after: post,
                deadline: deadline, budget: &budget.plist, isCancelled: isCancelled) else { return .unverified(.attributes) }
        } catch is MessagesUndoSendSummaryTransition.Failure {
            return .unverified(.metadata)
        } catch let failure as MessageSummaryPlist.Failure {
            switch failure {
            case .resourceLimit, .requestLimit: return .unverified(.resources)
            case .corrupt, .unsupportedFormat: return .unverified(.metadata)
            }
        }
        try checkpoint()
        return .verified
    }
}
