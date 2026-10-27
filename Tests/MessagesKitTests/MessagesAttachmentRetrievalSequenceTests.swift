import AppleKit
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentRetrievalSequenceTests {
    private func membership(_ row: Int64 = 1) throws -> MessagesAttachmentMembership {
        let id = try #require(MessagesAttachmentRetrievalState.Identity(rowid: row, guid: "synthetic-\(row)"))
        return try #require(MessagesAttachmentMembership([id]))
    }

    @Test func pendingCompletesAfterExactlyOneAction() throws {
        let expected = try membership()
        var states: [MessagesAttachmentRetrievalState.Outcome] = [.pending, .pending, .missing, .downloaded]
        var actions = 0
        let sequence = MessagesAttachmentRetrievalSequence(observe: { _ in
            .init(membership: expected, outcome: states.removeFirst())
        }, requestDownload: { _ in actions += 1 }, pause: { _ in })
        let result = try sequence.run(expected: expected, deadline: .millisecondsFromNow(5000))
        #expect(result.category == .ack)
        #expect(result.detail == "attachment-retrieval-downloaded-verified")
        #expect(actions == 1)
        #expect(states.isEmpty)
    }

    @Test func alreadyDownloadedDoesNotPress() throws {
        let expected = try membership()
        var actions = 0
        let sequence = MessagesAttachmentRetrievalSequence(observe: { _ in .init(membership: expected, outcome: .downloaded) },
            requestDownload: { _ in actions += 1 })
        let result = try sequence.run(expected: expected, deadline: .millisecondsFromNow(5000))
        #expect(result.detail == "attachment-retrieval-already-downloaded-verified")
        #expect(actions == 0)
    }

    @Test func postActionFailureAndDriftNeverRetry() throws {
        let expected = try membership(), changed = try membership(2)
        for (membership, outcome) in [(expected, MessagesAttachmentRetrievalState.Outcome.failed),
                                     (expected, .unavailable), (changed, .downloaded)] {
            var reads = 0, actions = 0
            let sequence = MessagesAttachmentRetrievalSequence(observe: { _ in
                reads += 1
                return .init(membership: reads == 1 ? expected : membership, outcome: reads == 1 ? .pending : outcome)
            }, requestDownload: { _ in actions += 1 })
            let result = try sequence.run(expected: expected, deadline: .millisecondsFromNow(5000))
            #expect(result.category == .failed)
            #expect(actions == 1)
        }
    }

    @Test func uncertainActionAndCancellationPropagate() throws {
        let expected = try membership()
        var actions = 0
        let sequence = MessagesAttachmentRetrievalSequence(observe: { _ in .init(membership: expected, outcome: .pending) },
            requestDownload: { _ in actions += 1; throw WorkerProtocolError.cancelled })
        #expect(throws: WorkerProtocolError.cancelled) {
            try sequence.run(expected: expected, deadline: .millisecondsFromNow(5000))
        }
        #expect(actions == 1)
        #expect(throws: WorkerProtocolError.cancelled) {
            try sequence.run(expected: expected, deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
        #expect(actions == 1)
    }
    @Test(arguments: [MessagesAttachmentRetrievalState.Outcome.failed, .unavailable])
    func initialFailureNeverRequestsDownload(_ outcome: MessagesAttachmentRetrievalState.Outcome) throws {
        let expected = try membership()
        var actions = 0
        let sequence = MessagesAttachmentRetrievalSequence(observe: { _ in .init(membership: expected, outcome: outcome) },
            requestDownload: { _ in actions += 1 })
        let result = try sequence.run(expected: expected, deadline: .millisecondsFromNow(5000))
        #expect(result.category == .refused)
        #expect(actions == 0)
    }

}
