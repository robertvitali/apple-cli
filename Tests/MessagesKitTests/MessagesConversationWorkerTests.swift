import AppleKit
import Foundation
import Testing
import TestSupport
@testable import MessagesKit

private struct CreationWorkerFixture {
    let db: ChatFixture
    let baseline: MessagesConversationBaseline.Snapshot
    let payload: MessagesConversationRequest
    init(text: String = "apple-cli-test creation", recipients: [String] = ["+12125550100"]) throws {
        db = try ChatFixture()
        try db.exec("ALTER TABLE message ADD COLUMN is_sent INTEGER;")
        let result = try MessagesConversationPlan.build(inputs: recipients, message: text,
            service: "imessage", gate: .init(willExecute: true, sandboxActive: false,
                sandboxPrefix: "apple-cli-test", allowedRecipients: []), deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        guard case .ready(let plan) = result else { throw WorkerProtocolError.malformedFrame }
        baseline = try MessagesConversationBaseline.read(databasePath: db.path,
            recipients: plan.recipients.map(\.candidate.address), deadline: .millisecondsFromNow(5000))
        payload = try MessagesConversationRequest(plan: plan, baseline: baseline)
    }
    func envelope() throws -> MessagesConversationNativeEnvelope {
        let text = payload.initialText
        return try .init(recipientAddresses: payload.recipients, service: payload.service,
                         body: MessagesAXBodyTextSnapshot(text: text, characterCount: text.utf16.count))
    }

    func composer(send: @escaping () throws -> Void) -> MessagesConversationWorkerSequence.PreparedComposer {
        .init(readEnvelope: envelope, send: send)
    }

    func currentBaseline(_ deadline: WorkerDeadline) throws -> MessagesConversationBaseline.Snapshot {
        try MessagesConversationBaseline.read(databasePath: db.path, recipients: baseline.requestedRecipients,
                                              deadline: deadline)
    }
    func send(chat: Int = 3) throws {
        try db.exec("""
            INSERT INTO message(ROWID,guid,text,is_from_me,is_sent,error,service)
            VALUES(60,'synthetic-created-message','apple-cli-test creation',1,1,0,'iMessage');
            INSERT INTO chat_message_join VALUES(\(chat),60);
            """)
    }
    func observe(_ before: MessagesConversationBaseline.Snapshot, _ deadline: WorkerDeadline) throws -> MessagesConversationVerification.Evidence? {
        try MessagesConversationVerification.read(databasePath: db.path, baseline: before,
            initialText: payload.initialText, deadline: deadline)
    }
}

@Suite("Conversation creation journal binding")
struct MessagesConversationBindingTests {
    private let scratch = ScratchDirs("conversation-binding")

    @Test func distinctOperationAndCommandUseOneValidatedPayload() throws {
        let fx = try CreationWorkerFixture(), binding = try MessagesConversationBinding(fx.payload)
        let resolved = try binding.resolvedAction()
        #expect(resolved.command.name == "messages.conversations.create")
        #expect(resolved.command.payload == (try fx.payload.workerPayloadData()))
        #expect(resolved.journalRequest.operationType.rawValue == "conversationCreate")
        #expect(resolved.journalRequest.partDigest == nil)
        #expect(resolved.journalRequest.minimumEvidence.targetLength == resolved.command.payload?.count)
    }

    @Test func payloadChangesChangeJournalBinding() throws {
        let a = try CreationWorkerFixture(), b = try CreationWorkerFixture(text: "apple-cli-test different")
        let first = try MessagesConversationBinding(a.payload), second = try MessagesConversationBinding(b.payload)
        #expect(first.target.minimumEvidence != second.target.minimumEvidence)
        #expect(first.target.messageDigest != second.target.messageDigest)
        #expect(first.target.conversationDigest == second.target.conversationDigest)
    }

    @Test func journalRoundTripRetainsOnlyDigestsAndLength() throws {
        let fx = try CreationWorkerFixture(), action = try MessagesConversationBinding(fx.payload).resolvedAction()
        let root = try scratch.directory().appendingPathComponent("journal").path
        let operationID = try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(5000)) {
            try $0.begin(action.journalRequest)
        }
        try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(5000)) { lease in
            let pending = try #require(try lease.loadSnapshot().pending)
            #expect(pending.operationID == operationID)
            #expect(pending.operationType.rawValue == "conversationCreate")
            #expect(pending.minimumEvidence == action.journalRequest.minimumEvidence)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(AppleAutomationJournal.stateFileName))
        let text = String(decoding: data, as: UTF8.self)
        for raw in ["+12125550100", fx.payload.initialText, "iMessage;-;"] { #expect(!text.contains(raw)) }
    }

    @Test func wireAllowsOnlyClosedCreationResultStrings() {
        for detail in ["conversation-create-preflight-refused", "conversation-create-unverified", "conversation-create-persisted-verified"] {
            #expect(WorkerOperationResult(.failed, detail: detail).detail == detail)
            #expect(WorkerOperationResult(.failed, detail: detail + ":private").detail == nil)
            #expect(WorkerOperationResult(.failed, detail: detail + "\n").detail == nil)
        }
    }
}

@Suite("Conversation creation one-send worker sequence")
struct MessagesConversationWorkerTests {
    @Test func oneSendRequiresFreshBaselineAndPersistedEvidence() throws {
        let fx = try CreationWorkerFixture()
        var reads = 0, sends = 0, observations = 0
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: { deadline in
            reads += 1; return try fx.currentBaseline(deadline)
        }, prepare: { _, _ in
            fx.composer { sends += 1; try fx.send() }
        }, verify: { before, deadline in
            observations += 1; return try fx.observe(before, deadline)
        }, pause: { _ in })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .ack)
        #expect(result.detail == "conversation-create-persisted-verified")
        #expect(sends == 1 && reads == 1 && observations == 1)
    }

    @Test func staleInitialBaselinePreventsPreparation() throws {
        let fx = try CreationWorkerFixture()
        try fx.db.exec("INSERT INTO message(ROWID,guid) VALUES(99,'synthetic-concurrent');")
        var preparations = 0
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: fx.currentBaseline,
            prepare: { _, _ in preparations += 1; throw WorkerProtocolError.cancelled }, verify: fx.observe, pause: { _ in })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .refused)
        #expect(result.detail == "conversation-create-preflight-refused")
        #expect(preparations == 0)
    }

    @Test func newConversationDuringPreparationUsesOriginalBaseline() throws {
        let fx = try CreationWorkerFixture(recipients: ["+12125550199"])
        var sends = 0
        var observation: MessagesConversationVerification.Observation?
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: fx.currentBaseline,
            prepare: { _, _ in
                try fx.db.exec("""
                    INSERT INTO handle(ROWID,id) VALUES(99,'+12125550199');
                    INSERT INTO chat(ROWID,guid,style,service_name) VALUES(70,'synthetic-new-dm',45,'iMessage');
                    INSERT INTO chat_handle_join VALUES(70,99);
                    """)
                return fx.composer { sends += 1; try fx.send(chat: 70) }
            }, verify: { before, deadline in
                let evidence = try fx.observe(before, deadline); observation = evidence?.observation; return evidence
            }, pause: { _ in })
        #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .ack)
        #expect(sends == 1)
        #expect(observation == .firstObservedAfterBaseline)
    }

    @Test func cancellationDuringPreparationPreventsSend() throws {
        let fx = try CreationWorkerFixture()
        var sends = 0, cancelled = false
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: fx.currentBaseline,
            prepare: { _, _ in cancelled = true; return fx.composer { sends += 1 } },
            verify: fx.observe, isCancelled: { cancelled }, pause: { _ in })
        #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .failed)
        #expect(sends == 0)
    }

    @Test(arguments: ["recipient", "service", "body", "cancel", "unavailable"])
    func freshComposerEvidenceIsRequiredBeforeSend(_ condition: String) throws {
        let fx = try CreationWorkerFixture()
        var cancelled = false
        var events: [String] = []
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: fx.currentBaseline,
            prepare: { _, _ in
                events.append("prepare")
                return .init(readEnvelope: {
                    events.append("read")
                    if condition == "unavailable" { throw MessagesAXNavigationError.targetDrift }
                    if condition == "cancel" { cancelled = true }
                    let expected = try fx.envelope()
                    return .init(
                        recipientAddresses: condition == "recipient" ? ["+12125550199"] : expected.recipientAddresses,
                        service: condition == "service" ? "SMS" : expected.service,
                        body: condition == "body" ? nil : expected.body)
                }, send: { events.append("send") })
            }, verify: { _, _ in events.append("verify"); return nil },
            isCancelled: { cancelled }, pause: { _ in })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.detail == "conversation-create-unverified")
        #expect(events == ["prepare", "read"])
    }

    @Test(arguments: [false, true])
    func expiryDuringPreparationOrEnvelopeReadPreventsSend(duringEnvelopeRead: Bool) throws {
        let fx = try CreationWorkerFixture()
        var events: [String] = []
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: { _ in fx.baseline },
            prepare: { _, deadline in
                func waitForExpiry() {
                    while !deadline.expired {
                        Thread.sleep(forTimeInterval: Double(deadline.remainingNanoseconds) / 1_000_000_000)
                    }
                }
                events.append("prepare")
                if !duringEnvelopeRead { waitForExpiry() }
                return .init(readEnvelope: {
                    events.append("read")
                    if duringEnvelopeRead { waitForExpiry() }
                    return try fx.envelope()
                }, send: { events.append("send") })
            }, verify: { _, _ in events.append("verify"); return nil })
        let result = sequence.run(deadline: .millisecondsFromNow(1000))
        #expect(result.category == .failed)
        #expect(result.detail == "conversation-create-unverified")
        #expect(events == (duringEnvelopeRead ? ["prepare", "read"] : ["prepare"]))
    }

    @Test func throwingSendIsNeverRepeatedOrConvertedToSuccess() throws {
        let fx = try CreationWorkerFixture()
        var sends = 0, observations = 0
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: fx.currentBaseline,
            prepare: { _, _ in
                fx.composer { sends += 1; try fx.send(); throw WorkerProtocolError.deadlineExpired }
            }, verify: { before, deadline in observations += 1; return try fx.observe(before, deadline) }, pause: { _ in })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .failed)
        #expect(result.detail == "conversation-create-unverified")
        #expect(sends == 1 && observations == 0)
    }

    @Test func delayedPersistenceRepeatsOnlyReadObservation() throws {
        let fx = try CreationWorkerFixture()
        var sends = 0, observations = 0
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: fx.currentBaseline,
            prepare: { _, _ in fx.composer { sends += 1 } }, verify: { before, deadline in
                observations += 1
                if observations == 3 { try fx.send() }
                return try fx.observe(before, deadline)
            }, pause: { _ in })
        #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .ack)
        #expect(sends == 1 && observations == 3)
    }

    @Test func observationLimitLeavesUnverifiedAndNeverResends() throws {
        let fx = try CreationWorkerFixture()
        var sends = 0, observations = 0
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: fx.currentBaseline,
            prepare: { _, _ in fx.composer { sends += 1 } }, verify: { _, _ in
                observations += 1; return nil
            }, pause: { _ in })
        #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .failed)
        #expect(sends == 1 && observations == 60)
    }

    @Test func cancelledOrExpiredPreflightDoesNotReadOrPrepare() throws {
        let fx = try CreationWorkerFixture()
        for cancelled in [false, true] {
            var reads = 0, preparations = 0
            let sequence = MessagesConversationWorkerSequence(payload: fx.payload,
                readBaseline: { deadline in reads += 1; return try fx.currentBaseline(deadline) },
                prepare: { _, _ in preparations += 1; throw WorkerProtocolError.cancelled }, verify: fx.observe,
                isCancelled: { cancelled }, pause: { _ in })
            #expect(sequence.run(deadline: .millisecondsFromNow(cancelled ? 5000 : 0)).category == .refused)
            #expect(reads == 0 && preparations == 0)
        }
    }

    @Test func cancellationAfterSendDoesNotAcknowledgeOrRetry() throws {
        let fx = try CreationWorkerFixture()
        var cancelled = false, sends = 0, observations = 0
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: fx.currentBaseline,
            prepare: { _, _ in fx.composer { sends += 1; try fx.send(); cancelled = true } },
            verify: { before, deadline in observations += 1; return try fx.observe(before, deadline) },
            isCancelled: { cancelled }, pause: { _ in })
        #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .failed)
        #expect(sends == 1 && observations == 0)
    }

    @Test func ambiguousPersistenceIsTerminalForThisAttempt() throws {
        let fx = try CreationWorkerFixture()
        var sends = 0, observations = 0
        let sequence = MessagesConversationWorkerSequence(payload: fx.payload, readBaseline: fx.currentBaseline,
            prepare: { _, _ in fx.composer { sends += 1 } }, verify: { _, _ in
                observations += 1; throw MessagesConversationVerification.Failure.ambiguous
            }, pause: { _ in })
        #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .failed)
        #expect(sends == 1 && observations == 1)
    }
}
