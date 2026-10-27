import AppleKit
import Foundation

/// Runs only after the parent has acquired the automation lease and recorded
/// its pending operation. Even an already-downloaded result must pass that gate.
/// The action closure must revalidate the exact target and retained AX route.
struct MessagesAttachmentRetrievalSequence {
    let observe: (WorkerDeadline) throws -> MessagesAttachmentObservation.Result
    let requestDownload: (WorkerDeadline) throws -> Void
    let pause: (UInt64) throws -> Void

    init(observe: @escaping (WorkerDeadline) throws -> MessagesAttachmentObservation.Result,
         requestDownload: @escaping (WorkerDeadline) throws -> Void,
         pause: @escaping (UInt64) throws -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) }) {
        self.observe = observe
        self.requestDownload = requestDownload
        self.pause = pause
    }

    func run(expected: MessagesAttachmentMembership, deadline: WorkerDeadline,
             isCancelled: () -> Bool = { false }) throws -> WorkerOperationResult {
        let bounded = WorkerDeadline.millisecondsFromNow(min(60_000, deadline.remainingNanoseconds / 1_000_000))
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            if deadline.expired || bounded.expired { throw WorkerProtocolError.deadlineExpired }
        }
        try checkpoint()
        let first = try observe(bounded)
        try checkpoint()
        guard first.membership == expected else { return .refused("attachment-retrieval-membership-drift") }
        if first.outcome == .unavailable || first.outcome == .failed { return .refused("attachment-retrieval-unavailable") }
        if first.outcome == .downloaded {
            return WorkerOperationResult(.ack, detail: "attachment-retrieval-already-downloaded-verified")
        }
        // Exactly one invocation. Any throw or later uncertain observation exits
        // without retrying the native action or clearing the parent's journal.
        try requestDownload(bounded)
        try checkpoint()
        for attempt in 0..<61 {
            let current = try observe(bounded)
            try checkpoint()
            guard current.membership == expected else { return .failed("attachment-retrieval-membership-drift") }
            switch current.outcome {
            case .downloaded:
                return WorkerOperationResult(.ack, detail: "attachment-retrieval-downloaded-verified")
            case .failed: return .failed("attachment-retrieval-failed")
            case .unavailable: return .failed("attachment-retrieval-unavailable")
            case .pending, .missing: break
            }
            if attempt < 60 {
                try pause(min(1_000_000_000, bounded.remainingNanoseconds))
                try checkpoint()
            }
        }
        throw WorkerProtocolError.deadlineExpired
    }
}
