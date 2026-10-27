import Foundation

/// Pure observation logic. Callers must separately establish the exact message,
/// complete native join set, and confined file observations for one read attempt.
/// This result neither initiates retrieval nor proves causality or future access.
enum MessagesAttachmentRetrievalState {
    static let maximumAttachments = 1_024
    static let maximumGUIDBytes = 4_096

    struct Identity: Hashable, Sendable {
        let rowid: Int64
        let guid: Data

        init?(rowid: Int64, guid: String) {
            guard rowid > 0, !guid.isEmpty, guid.utf8.count <= maximumGUIDBytes,
                  !guid.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            self.rowid = rowid
            // Swift String equality is canonically equivalent; native identities
            // must instead retain their original UTF-8 bytes.
            self.guid = Data(guid.utf8)
        }
    }

    enum FileObservation: Equatable, Sendable {
        case readableRegularFile
        case missing
        case unavailable
    }

    struct Observation: Sendable {
        let identity: Identity
        let transfer: ChatDB.NativeAttachmentTransfer?
        let file: FileObservation
    }

    enum Outcome: Equatable, Sendable {
        case downloaded
        case pending
        case missing
        case failed
        case unavailable
    }

    /// `completeJoin` must come from a bounded integrity-preserving read, not
    /// from an inner join that can omit dangling attachment references.
    static func evaluate(expected: [Identity], observed: [Observation], completeJoin: Bool) -> Outcome {
        guard completeJoin, !expected.isEmpty, expected.count <= maximumAttachments,
              observed.count == expected.count,
              Set(expected.map(\.rowid)).count == expected.count,
              Set(expected.map(\.guid)).count == expected.count,
              Set(observed.map(\.identity)).count == observed.count,
              Set(observed.map(\.identity)) == Set(expected) else { return .unavailable }

        var pending = false
        var failed = false
        var missing = false
        for item in observed {
            guard item.file != .unavailable,
                  let transfer = item.transfer, transfer.status == "available",
                  let raw = transfer.raw, (0...9).contains(raw) else { return .unavailable }
            if (6...8).contains(raw) { failed = true }
            else if raw != 5 { pending = true }
            if item.file == .missing { missing = true }
        }
        if failed { return .failed }
        if pending { return .pending }
        if missing { return .missing }
        return .downloaded
    }
}
