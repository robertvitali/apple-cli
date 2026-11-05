import Foundation
import Testing
import TestSupport
import os
@testable import AppleKit
@testable import MessagesKit

@Suite("Conversation creation lease ordering")
struct MessagesConversationLeaseTests {
    private let scratch = ScratchDirs("conversation-lease")
    private enum Stop: Error { case captured, unexpectedHandoff }
    private struct Observations: Sendable {
        var cancellationChecks = 0
        var contactReads = 0
        var payload: Data?
        var outcome: String?
        var failed = false
    }

    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("ALTER TABLE message ADD COLUMN is_sent INTEGER;")
        return fx
    }
    private func baseline(_ path: String) throws -> MessagesConversationBaseline.Snapshot {
        try MessagesConversationBaseline.read(databasePath: path,
            recipients: [MessagesConversationAddress.parse("+12125550100")], deadline: .millisecondsFromNow(5000))
    }

    @Test(arguments: [false, true])
    func waiterResolvesOnlyAfterLeaseAndPendingCheck(_ leavePending: Bool) throws {
        let fx = try fixture(), path = fx.path
        let root = try scratch.directory().appendingPathComponent("journal").path
        let before = try baseline(path)
        let state = OSAllocatedUnfairLock(initialState: Observations())
        let contending = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var pendingID: UUID?

        try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(5000)) { lease in
            DispatchQueue.global().async {
                defer { finished.signal() }
                do {
                    let deadline = WorkerDeadline.millisecondsFromNow(5000)
                    let session = MessagesConversationExecution(inputs: ["Alice Example"],
                        message: "apple-cli-test after lease", service: "imessage",
                        gate: .init(willExecute: true, sandboxActive: false, allowedRecipients: []),
                        databasePath: path, stateRoot: root, deadline: deadline, loadContacts: { _ in
                            state.withLock { $0.contactReads += 1 }
                            return [.init(fullName: "Alice Example", nickname: "", rawAddress: "+12125550100")]
                        })
                    let creation = session.action()
                    let probe = WorkerObservedAction(stateRoot: root, deadline: deadline, isCancelled: {
                        let count = state.withLock { $0.cancellationChecks += 1; return $0.cancellationChecks }
                        // Launcher checks once before entering the journal. The
                        // third check occurs on a repeated lock-acquisition pass
                        // while this test still holds the first invocation's lease.
                        if count == 3 { contending.signal() }
                        return false
                    }, resolve: {
                        let resolved = try creation.resolve()
                        let payload = resolved.command.payload
                        state.withLock { $0.payload = payload }
                        // Observe authoritative binding, then refuse before any
                        // journal begin, subprocess, or native action is possible.
                        throw Stop.captured
                    }, preflight: { _, _ in
                        Issue.record("lease probe reached mutation preflight")
                        throw Stop.unexpectedHandoff
                    }, verify: { _, _, _ in
                        Issue.record("lease probe reached mutation verification")
                        return nil
                    })
                    let outcome = try WorkerLauncher().launchObserved(probe).description
                    state.withLock { $0.outcome = outcome }
                } catch { state.withLock { $0.failed = true } }
            }
            #expect(contending.wait(timeout: .now() + 2) == .success)
            #expect(state.withLock { $0.contactReads } == 0)
            #expect(state.withLock { $0.payload } == nil)
            try fx.exec("INSERT INTO message(ROWID,guid) VALUES(100,'synthetic-first-invocation');")
            if leavePending {
                let planResult = try MessagesConversationPlan.build(inputs: ["+12125550100"],
                    message: "apple-cli-test pending", service: "imessage",
                    gate: .init(willExecute: true, sandboxActive: false, allowedRecipients: []),
                    deadline: .millisecondsFromNow(5000), loadContacts: { [] })
                guard case .ready(let plan) = planResult else { throw Stop.unexpectedHandoff }
                let request = try MessagesConversationRequest(plan: plan, baseline: before)
                pendingID = try lease.begin(MessagesConversationBinding(request).resolvedAction().journalRequest)
            }
        }
        #expect(finished.wait(timeout: .now() + 6) == .success)
        let observed = state.withLock { $0 }
        #expect(!observed.failed)
        if let pendingID {
            #expect(observed.contactReads == 0)
            #expect(observed.payload == nil)
            #expect(observed.outcome == "requestNotSent(pending-operation-exists:" + pendingID.uuidString + ")")
            try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(1000)) { lease in
                let snapshot = try lease.loadSnapshot()
                #expect(snapshot.pending?.operationID == pendingID)
            }
        } else {
            #expect(observed.contactReads == 1)
            #expect(observed.outcome == "requestNotSent(captured)")
            let payload = try #require(observed.payload)
            let request = try MessagesConversationRequest.decodeWorkerPayload(payload)
            #expect(try !request.matches(before))
            #expect(try request.matches(baseline(path)))
        }
    }

    @Test func expiredWaitDoesNotResolveContactsOrCaptureBaseline() throws {
        let root = try scratch.directory().appendingPathComponent("journal").path
        var reads = 0
        try AppleAutomationJournal.withLockedJournal(root: root, deadline: .millisecondsFromNow(1000)) { _ in
            let session = MessagesConversationExecution(inputs: ["Alice Example"],
                message: "apple-cli-test after lease", service: "imessage",
                gate: .init(willExecute: true, sandboxActive: false, allowedRecipients: []),
                databasePath: "/synthetic-unavailable", stateRoot: root,
                deadline: .millisecondsFromNow(40), loadContacts: { _ in reads += 1; return [] })
            let outcome = try WorkerLauncher().launchObserved(session.action())
            guard case .timedOut = outcome else { Issue.record("Expected lease timeout"); return }
            #expect(reads == 0)
            #expect(session.verifiedEvidence == nil)
            #expect(session.unresolvedRecipients.isEmpty)
        }
    }
}
