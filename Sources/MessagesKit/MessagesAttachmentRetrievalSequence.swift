import AppleKit
import Foundation

/// Runs only after the parent has acquired the automation lease and recorded
/// its pending operation. Even an already-downloaded result must pass that gate.
/// The action closure must revalidate the exact target and retained AX route.
struct MessagesAttachmentRetrievalSequence {
    let observe: (WorkerDeadline) throws -> MessagesAttachmentObservation.Result
    let requestDownload: (WorkerDeadline) throws -> Void
    let pause: (UInt64) throws -> Void
    let diagnostic: MessagesAttachmentDiagnostic?

    init(observe: @escaping (WorkerDeadline) throws -> MessagesAttachmentObservation.Result,
         requestDownload: @escaping (WorkerDeadline) throws -> Void,
         pause: @escaping (UInt64) throws -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) },
         diagnostic: MessagesAttachmentDiagnostic? = nil) {
        self.observe = observe
        self.requestDownload = requestDownload
        self.pause = pause
        self.diagnostic = diagnostic
    }

    func run(expected: MessagesAttachmentMembership, deadline: WorkerDeadline,
             isCancelled: () -> Bool = { false }) throws -> WorkerOperationResult {
        let bounded = WorkerDeadline.millisecondsFromNow(min(60_000, deadline.remainingNanoseconds / 1_000_000))
        func checkpoint() throws {
            if isCancelled() { throw WorkerProtocolError.cancelled }
            if deadline.expired || bounded.expired { throw WorkerProtocolError.deadlineExpired }
        }
        diagnostic?.record(.initialRead)
        try checkpoint()
        let first = try observe(bounded)
        try checkpoint()
        guard first.membership == expected else { return .refused("attachment-retrieval-membership-drift") }
        diagnostic?.record(.initialState)
        if first.outcome == .unavailable || first.outcome == .failed {
            return .refused(diagnostic?.detail(category: first.outcome == .failed ? .failed : .unavailable)
                ?? "attachment-retrieval-unavailable")
        }
        if first.outcome == .downloaded {
            return WorkerOperationResult(.ack, detail: "attachment-retrieval-already-downloaded-verified")
        }
        // Exactly one invocation. Any throw or later uncertain observation exits
        // without retrying the native action or clearing the parent's journal.
        try requestDownload(bounded)
        try checkpoint()
        for attempt in 0..<61 {
            diagnostic?.record(.verificationRead)
            let current = try observe(bounded)
            try checkpoint()
            guard current.membership == expected else { return .failed("attachment-retrieval-membership-drift") }
            diagnostic?.record(.verificationState)
            switch current.outcome {
            case .downloaded:
                return WorkerOperationResult(.ack, detail: "attachment-retrieval-downloaded-verified")
            case .failed: return .failed(diagnostic?.detail(category: .failed) ?? "attachment-retrieval-failed")
            case .unavailable: return .failed(diagnostic?.detail(category: .unavailable) ?? "attachment-retrieval-unavailable")
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
