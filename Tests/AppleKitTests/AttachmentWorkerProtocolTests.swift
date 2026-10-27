import Testing
@testable import AppleKit

@Suite struct AttachmentWorkerProtocolTests {
    @Test func retrievalHasDistinctJournalOperation() {
        let operation = AppleAutomationJournal.PendingOperation.OperationType(rawValue: "attachmentRetrieve")
        #expect(operation != nil)
        #expect(operation != .replySend)
        #expect(operation != .reactionSet)
    }

    @Test func onlyFixedRetrievalDetailsSurviveSanitization() {
        for detail in ["attachment-retrieval-downloaded-verified", "attachment-retrieval-already-downloaded-verified",
                       "attachment-retrieval-unavailable", "attachment-retrieval-failed", "attachment-retrieval-membership-drift"] {
            #expect(WorkerOperationResult(.ack, detail: detail).detail == detail)
        }
        #expect(WorkerOperationResult(.ack, detail: "attachment-retrieval-downloaded-verified:/private/example").detail == nil)
        #expect(WorkerOperationResult(.ack, detail: "attachment-retrieval-downloaded-verified\nextra").detail == nil)
        #expect(WorkerOperationResult.ack.detail == nil)
    }
}
