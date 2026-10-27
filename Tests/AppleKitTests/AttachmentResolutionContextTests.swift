@testable import AppleKit
import Testing

@Suite struct AttachmentResolutionContextTests {
    @Test func resolverReceivesLiveCancellation() throws {
        var cancelled = false
        var observed = false
        let action = WorkerObservedAction(stateRoot: "/unused", deadline: .millisecondsFromNow(5000),
            isCancelled: { cancelled }, resolveWithContext: { context in
                observed = context.isCancelled
                throw WorkerProtocolError.cancelled
            }, preflight: { _, _ in .requiresMutation }, verify: { _, _, _ in nil })
        cancelled = true
        #expect(throws: WorkerProtocolError.cancelled) { try action.resolve() }
        #expect(observed)
    }

    @Test func resolverReceivesOriginalDeadline() throws {
        var expired = false
        let action = WorkerObservedAction(stateRoot: "/unused", deadline: .millisecondsFromNow(0),
            resolveWithContext: { context in
                expired = context.deadline.expired
                throw WorkerProtocolError.deadlineExpired
            }, preflight: { _, _ in .requiresMutation }, verify: { _, _, _ in nil })
        #expect(throws: WorkerProtocolError.deadlineExpired) { try action.resolve() }
        #expect(expired)
    }
}
