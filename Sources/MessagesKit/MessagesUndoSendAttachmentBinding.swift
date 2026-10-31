import Foundation

/// Correlates decoded part GUID bytes with a complete attachment identity set.
/// The caller must capture both inputs in one pinned transaction. This pure
/// check cannot establish database snapshot consistency or native UI identity.
enum MessagesUndoSendAttachmentBinding {
    enum Failure: Error { case invalidMembership, invalidMapping, missingPart, missingAttachment }

    static func bind(nativeParts: [NativeMessageParts.NativePart], selectedIndex: Int,
                     members: [MessagesAttachmentRetrievalState.Identity]) throws
        -> MessagesAttachmentRetrievalState.Identity? {
        guard members.count <= MessagesAttachmentRetrievalState.maximumAttachments,
              Set(members.map(\.rowid)).count == members.count,
              Set(members.map(\.guid)).count == members.count else { throw Failure.invalidMembership }
        guard (0...Int(Int32.max)).contains(selectedIndex),
              !nativeParts.isEmpty, nativeParts.count <= NativeMessageParts.Limits.default.maxRuns else {
            throw Failure.invalidMapping
        }
        let byGUID = Dictionary(uniqueKeysWithValues: members.map { ($0.guid, $0) })
        var indices = Set<Int>()
        var mappedGUIDs = Set<Data>()
        var selectedFound = false
        var selected: MessagesAttachmentRetrievalState.Identity?
        for part in nativeParts {
            guard (0...Int(Int32.max)).contains(part.index), indices.insert(part.index).inserted else {
                throw Failure.invalidMapping
            }
            let attachment: MessagesAttachmentRetrievalState.Identity?
            if let guid = part.attachmentGUID {
                let bytes = Data(guid.utf8)
                guard mappedGUIDs.insert(bytes).inserted else { throw Failure.invalidMapping }
                guard let member = byGUID[bytes] else { throw Failure.missingAttachment }
                attachment = member
            } else {
                attachment = nil
            }
            if part.index == selectedIndex {
                selectedFound = true
                selected = attachment
            }
        }
        guard selectedFound else { throw Failure.missingPart }
        return selected
    }
}
