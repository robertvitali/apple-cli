import AppleKit
import Foundation

/// Coordinates one mutation attempt with strict baseline revalidation and a
/// bounded, read-only persisted-transition check. UI completion alone is not ACK.
struct MessagesEditWorkerSequence {
    typealias Snapshot = MessagesEditTargetResolver.Snapshot
    let payload: MessagesEditRequest
    let read: (WorkerDeadline) throws -> Snapshot
    let perform: (Snapshot, WorkerDeadline, () throws -> Void) throws -> Void
    var diagnostic: MessagesEditDiagnostic? = nil
    var now: () -> Date = Date.init
    var pause: (UInt64) throws -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) }

    func run(deadline: WorkerDeadline) -> WorkerOperationResult {
        let baseline: Snapshot
        do {
            baseline = try validated(deadline: deadline)
        } catch {
            return .refused("edit-preflight-refused")
        }
        do {
            // A throwing action may already have changed native state. Never
            // retry it, and never turn that uncertainty into a success response.
            try perform(baseline, deadline) {
                _ = try validated(deadline: deadline)
            }
            diagnostic?.record(.persistence)
            for attempt in 0..<60 {
                try checkpoint(deadline)
                let observed = try read(deadline)
                try checkpoint(deadline)
                guard MessagesEditVerification.sameTarget(before: baseline, after: observed) else {
                    throw MessagesAXNavigationError.targetDrift
                }
                if MessagesEditVerification.matches(before: baseline, after: observed,
                                                     replacement: payload.replacement) {
                    return .init(.ack, detail: "edit-persisted-verified")
                }
                if attempt < 59 { try pause(min(50_000_000, deadline.remainingNanoseconds)) }
            }
        } catch {
            // Only closed diagnostic categories cross the protocol; never error descriptions.
            if let diagnostic { return .failed(diagnostic.detail(error)) }
        }
        return .failed("edit-unverified")
    }

    private func checkpoint(_ deadline: WorkerDeadline) throws {
        try Task.checkCancellation()
        try checkMessagesAXDeadline(deadline)
    }

    private func validated(deadline: WorkerDeadline) throws -> Snapshot {
        try checkpoint(deadline)
        let snapshot = try read(deadline)
        try checkpoint(deadline)
        guard try payload.matches(snapshot),
              !snapshot.partText.utf8.elementsEqual(payload.replacement.utf8),
              MessagesEditEligibility.assess(sentDateRaw: snapshot.sentDateRaw,
                partIndex: snapshot.partIndex, currentText: snapshot.partText,
                context: snapshot.editContext, now: now()) == .eligible,
              payload.preservesSandbox(snapshot) else { throw MessagesAXNavigationError.targetDrift }
        return snapshot
    }

}
