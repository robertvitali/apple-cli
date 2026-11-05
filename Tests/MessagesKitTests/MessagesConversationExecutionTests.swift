import Foundation
import Testing
import TestSupport
@testable import AppleKit
@testable import MessagesKit

@Suite("Conversation creation parent orchestration")
struct MessagesConversationExecutionTests {
    private let scratch = ScratchDirs("conversation-execution")
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("ALTER TABLE message ADD COLUMN is_sent INTEGER;")
        return fx
    }
    private func session(_ fx: ChatFixture, inputs: [String] = ["+12125550100"], execute: Bool = true,
                         root: String = "/synthetic-unused", deadline: WorkerDeadline = .millisecondsFromNow(5000),
                         cancelled: @escaping () -> Bool = { false },
                         contacts: @escaping (WorkerObservedContext) throws -> [MessagesConversationRawContacts.Record] = { _ in [] }) -> MessagesConversationExecution {
        MessagesConversationExecution(inputs: inputs, message: "apple-cli-test creation", service: "imessage",
            gate: .init(willExecute: execute, sandboxActive: false, sandboxPrefix: "apple-cli-test", allowedRecipients: []),
            databasePath: fx.path, stateRoot: root, deadline: deadline, isCancelled: cancelled, loadContacts: contacts)
    }
    private func context() -> WorkerObservedContext { .init(deadline: .millisecondsFromNow(5000), isCancelled: { false }) }
    private func ack() -> WorkerResponse {
        WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack,
                       detail: "conversation-create-persisted-verified")
    }
    private func send(_ fx: ChatFixture) throws {
        try fx.exec("""
            INSERT INTO message(ROWID,guid,text,is_from_me,is_sent,error,service)
            VALUES(60,'synthetic-created','apple-cli-test creation',1,1,0,'iMessage');
            INSERT INTO chat_message_join VALUES(3,60);
            """)
    }

    @Test func constructionDefersContactsAndBaselineUntilResolution() throws {
        let fx = try fixture()
        var contactReads = 0
        let operation = session(fx, inputs: ["Alice Example"], contacts: { _ in
            contactReads += 1
            return [.init(fullName: "Alice Example", nickname: "", rawAddress: "+12125550100")]
        })
        let action = operation.action()
        #expect(contactReads == 0)
        // Arrives after session construction; authoritative resolution must see it.
        try fx.exec("INSERT INTO message(ROWID,guid) VALUES(100,'synthetic-before-lock');")
        let resolved = try action.resolve()
        let request = try MessagesConversationRequest.decodeWorkerPayload(try #require(resolved.command.payload))
        let current = try MessagesConversationBaseline.read(databasePath: fx.path,
            recipients: [MessagesConversationAddress.parse("+12125550100")], deadline: .millisecondsFromNow(5000))
        #expect(try request.matches(current))
        #expect(contactReads == 1)
    }

    @Test func pendingJournalBlocksResolutionInRealLauncher() throws {
        let fx = try fixture(), root = try scratch.directory().appendingPathComponent("journal").path
        let seed = try session(fx).action().resolve()
        let id = try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(5000)) {
            try $0.begin(seed.journalRequest)
        }
        var reads = 0
        let operation = session(fx, inputs: ["Alice"], root: root, contacts: { _ in reads += 1; return [] })
        let outcome = try WorkerLauncher().launchObserved(operation.action())
        guard case .requestNotSent(let reason) = outcome else { Issue.record("Expected pending refusal"); return }
        #expect(reason == "pending-operation-exists:" + id.uuidString)
        #expect(reads == 0)
        #expect(operation.verifiedEvidence == nil)
        try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(5000)) { lease in
            let snapshot = try lease.loadSnapshot()
            #expect(snapshot.pending?.operationID == id)
        }
    }

    @Test func initialSendIsRequiredEvenWhenConversationAlreadyExists() throws {
        let fx = try fixture(), operation = session(fx), action = operation.action()
        let resolved = try action.resolve()
        #expect(try action.preflight(resolved, context()) == .requiresMutation)
    }

    @Test func parentRequiresItsOwnPersistedReadAfterWorkerAck() throws {
        let fx = try fixture(), operation = session(fx), action = operation.action()
        let resolved = try action.resolve()
        #expect(try action.verify(resolved, ack(), context()) == nil)
        #expect(operation.verifiedEvidence == nil)
        try send(fx)
        #expect(try action.verify(resolved, ack(), context()) != nil)
        #expect(operation.verifiedEvidence?.messageRowid == 60)
        #expect(operation.verifiedEvidence?.conversation.rowid == 3)
        #expect(operation.verifiedEvidence?.creationAttribution == "unproven")
    }

    @Test func mismatchedBindingOrResponseCannotPublishEvidence() throws {
        let fx = try fixture(), operation = session(fx), action = operation.action()
        let resolved = try action.resolve()
        try send(fx)
        #expect(try action.verify(resolved, ack(), context()) != nil)
        let other = try session(fx).action().resolve()
        #expect(try action.verify(other, ack(), context()) == nil)
        #expect(operation.verifiedEvidence == nil)
        let refused = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .refused,
                                     detail: "conversation-create-preflight-refused")
        #expect(try action.verify(resolved, refused, context()) == nil)
        #expect(throws: (any Error).self) { try action.preflight(other, context()) }
    }

    @Test func lateConcurrentMatchInvalidatesParentUniqueness() throws {
        let fx = try fixture(), operation = session(fx), action = operation.action()
        let resolved = try action.resolve()
        try send(fx)
        try fx.exec("""
            INSERT INTO message(ROWID,guid,text,is_from_me,is_sent,error,service)
            VALUES(61,'synthetic-concurrent','apple-cli-test creation',1,1,0,'iMessage');
            INSERT INTO chat_message_join VALUES(3,61);
            """)
        #expect(try action.verify(resolved, ack(), context()) == nil)
        #expect(operation.verifiedEvidence == nil)
    }

    @Test func previewPostureCannotBuildMutationBinding() throws {
        let fx = try fixture()
        var reads = 0
        let operation = session(fx, inputs: ["Alice"], execute: false, contacts: { _ in reads += 1; return [] })
        #expect(throws: (any Error).self) { try operation.action().resolve() }
        #expect(reads == 0)
    }

    @Test func resolutionIsOneShotAndUsesSharedDeadline() throws {
        let fx = try fixture(), deadline = WorkerDeadline.millisecondsFromNow(5000)
        var reads = 0
        let operation = session(fx, inputs: ["Alice Example"], deadline: deadline, contacts: { context in
            reads += 1; #expect(context.deadline == deadline)
            return [.init(fullName: "Alice Example", nickname: "", rawAddress: "+12125550100")]
        })
        _ = try operation.action().resolve()
        #expect(throws: (any Error).self) { try operation.action().resolve() }
        #expect(reads == 1)
    }

    @Test func unresolvedNamesDoNotCaptureBaselineOrExposeErrorsWithInput() throws {
        let fx = try fixture()
        try fx.exec("DROP TABLE message;")
        let operation = session(fx, inputs: ["Alice Example"])
        #expect(throws: MessagesConversationExecution.Failure.unresolvedRecipients) { try operation.action().resolve() }
        #expect(operation.unresolvedRecipients.count == 1)
    }

    @Test func dependencyFailureDetailsDoNotEscapeResolution() throws {
        let fx = try fixture(), operation = session(fx, inputs: ["Alice"], contacts: { _ in
            throw NSError(domain: "synthetic-private-path", code: 1, userInfo: [NSLocalizedDescriptionKey: "synthetic-private-text"])
        })
        #expect(throws: MessagesConversationExecution.Failure.preflightUnavailable) { try operation.action().resolve() }
    }

    @Test func cancelledResolutionAndExpiredVerificationCannotAdvance() throws {
        let fx = try fixture()
        var reads = 0
        let stopped = session(fx, inputs: ["Alice"], cancelled: { true }, contacts: { _ in reads += 1; return [] })
        #expect(throws: WorkerProtocolError.cancelled) { try stopped.action().resolve() }
        #expect(reads == 0)
        let operation = session(fx), action = operation.action(), resolved = try action.resolve()
        try send(fx)
        #expect(try action.verify(resolved, ack(), .init(deadline: .millisecondsFromNow(0), isCancelled: { false })) == nil)
        #expect(operation.verifiedEvidence == nil)
    }
}
