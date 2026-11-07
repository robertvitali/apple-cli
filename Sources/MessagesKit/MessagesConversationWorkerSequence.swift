import AppleKit
import Foundation

/// One native send followed only by bounded persisted observations.
struct MessagesConversationWorkerSequence {
    typealias Baseline = MessagesConversationBaseline.Snapshot

    /// Both operations refer to the same retained composer. The adapter must
    /// revalidate its ownership and all control identities when reading the
    /// complete current envelope, then press only its retained Send control.
    struct PreparedComposer {
        let readEnvelope: () throws -> MessagesConversationNativeEnvelope
        let send: () throws -> Void
    }

    let payload: MessagesConversationRequest
    let readBaseline: (WorkerDeadline) throws -> Baseline
    let prepare: (Baseline, WorkerDeadline) throws -> PreparedComposer
    let verify: (Baseline, WorkerDeadline) throws -> MessagesConversationVerification.Evidence?
    var isCancelled: () -> Bool = { Task.isCancelled }
    var pause: (UInt64) throws -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) }

    func run(deadline: WorkerDeadline) -> WorkerOperationResult {
        let baseline: Baseline
        do {
            try checkpoint(deadline)
            baseline = try readBaseline(deadline)
            try checkpoint(deadline)
            guard try payload.matches(baseline) else { throw MessagesAXNavigationError.targetDrift }
            try checkpoint(deadline)
        } catch { return .refused("conversation-create-preflight-refused") }
        do {
            // Keep the original baseline through composition. A new conversation
            // may appear before send; recapturing it would erase that evidence.
            let composer = try prepare(baseline, deadline)
            try checkpoint(deadline)
            try composer.readEnvelope().validate(request: payload)
            try checkpoint(deadline)
            try composer.send()
            for attempt in 0..<60 {
                try checkpoint(deadline)
                let evidence = try verify(baseline, deadline)
                try checkpoint(deadline)
                if evidence != nil { return .init(.ack, detail: "conversation-create-persisted-verified") }
                if attempt < 59 { try pause(min(50_000_000, deadline.remainingNanoseconds)) }
            }
        } catch {
            // A throw may follow a send. Do not repeat the action or turn a later
            // matching observation into ACK after this attempt became uncertain.
        }
        return .failed("conversation-create-unverified")
    }

    private func checkpoint(_ deadline: WorkerDeadline) throws {
        if isCancelled() { throw WorkerProtocolError.cancelled }
        if deadline.expired { throw WorkerProtocolError.deadlineExpired }
    }
}
