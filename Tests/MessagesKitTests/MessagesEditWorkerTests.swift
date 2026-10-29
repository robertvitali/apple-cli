import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesEditWorkerTests {
    @Test func diagnosticsPreserveFailureAndNeverRetryNativeAction() throws {
        let before = try snapshot(edited: false)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        let diagnostic = MessagesEditDiagnostic()
        var actions = 0, reads = 0
        let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in
            reads += 1; return before
        }, perform: { _, _, _ in
            actions += 1
            diagnostic.record(.confirmation)
            throw MessagesAXNavigationError.axFailure
        }, diagnostic: diagnostic, now: { now }, pause: { _ in })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .failed)
        #expect(result.detail == "edit-unverified:confirmation:ax-failure")
        #expect(actions == 1)
        #expect(reads == 1)
    }

    @Test func diagnosticsSeparatePersistenceFromNativeAction() throws {
        let before = try snapshot(edited: false)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        let diagnostic = MessagesEditDiagnostic()
        var reads = 0, actions = 0
        let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in
            reads += 1
            if reads > 1 { throw MessagesAXNavigationError.deadlineExpired }
            return before
        }, perform: { _, _, _ in actions += 1 }, diagnostic: diagnostic, now: { now }, pause: { _ in })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .failed)
        #expect(result.detail == "edit-unverified:persistence:deadline-expired")
        #expect(actions == 1)
        #expect(reads == 2)
    }

    private func snapshot(edited: Bool, originals: Any? = nil, originalText: String = "original") throws -> MessagesEditTargetResolver.Snapshot {
        let text = edited ? "replacement" : originalText
        var fields: [String: Any] = [:]
        if edited {
            fields = ["ep": [0], "otr": ["0": ["lo": 0, "le": 8]], "ec": ["0": ["original", "replacement"].map {
                ["d": 800_000_001, "t": NSArchiver.archivedData(withRootObject: NSAttributedString(string: $0))] as [String: Any]
            }]]
        }
        if let originals { fields["otr"] = originals }
        var budget = NativeEditContextDecoder.Budget()
        let summary = try NativeEditContextDecoder.decode(PropertyListSerialization.data(fromPropertyList: fields,
            format: .binary, options: 0), budget: &budget, requireExactHistoryText: true)
        return .init(chatRowid: 3, chatGUID: "synthetic-chat", messageRowid: 60, messageGUID: "synthetic-message",
            sentDateRaw: 800_000_000_000_000_000, chatStyle: 45, partIndex: 0, partText: text, fullText: text,
            nativeParts: [.init(index: 0, utf16Ranges: [.init(location: 0, length: text.utf16.count)], attachmentGUID: nil)],
            participantHandles: ["person@example.com"], editContext: .init(
                date_edited: NativeMessageStatusDecoder.timestamp(raw: edited ? 800_000_001 : 0),
                date_retracted: NativeMessageStatusDecoder.timestamp(raw: 0), summary_info: summary))
    }
    private var now: Date { Date(timeIntervalSince1970: 800_000_002 + MessageTime.appleUnixOffset) }

    @Test func acknowledgesOnlyAfterMatchingPersistedTransition() throws {
        let before = try snapshot(edited: false), after = try snapshot(edited: true)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        var committed = false, actions = 0, reads = 0
        let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in
            reads += 1; return committed ? after : before
        }, perform: { _, _, validate in
            actions += 1
            try validate(); try validate(); try validate()
            committed = true
        }, now: { now }, pause: { _ in })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .ack)
        #expect(result.detail == "edit-persisted-verified")
        #expect(actions == 1)
        #expect(reads == 5)
    }

    @Test func driftBeforeActionRefusesWithoutInvokingUI() throws {
        let before = try snapshot(edited: false), after = try snapshot(edited: true)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        var actions = 0
        let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in after },
            perform: { _, _, _ in actions += 1 }, now: { now }, pause: { _ in })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .refused)
        #expect(actions == 0)
    }

    @Test func oversizedOriginalNeverInvokesUI() throws {
        for original in [String(repeating: "a", count: 4097), String(repeating: "é", count: 2049)] {
            let before = try snapshot(edited: false, originalText: original)
            let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
            var actions = 0
            let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in before },
                perform: { _, _, _ in actions += 1 }, now: { now }, pause: { _ in })
            #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .refused)
            #expect(actions == 0)
        }
    }

    @Test func invalidOriginalMetadataNeverInvokesUI() throws {
        let before = try snapshot(edited: false, originals: "wrong-type")
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        var actions = 0
        let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in before },
            perform: { _, _, _ in actions += 1 }, now: { now }, pause: { _ in })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .refused)
        #expect(actions == 0)
    }

    @Test func missingPostconditionAndNativeFailureNeverRetryAction() throws {
        let before = try snapshot(edited: false)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        for fails in [false, true] {
            var actions = 0
            let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in before },
                perform: { _, _, _ in actions += 1; if fails { throw MessagesAXNavigationError.axFailure } },
                now: { now }, pause: { _ in })
            #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .failed)
            #expect(actions == 1)
        }
    }

    @Test func driftAtEveryMutationCheckpointStopsSubsequentWork() throws {
        let before = try snapshot(edited: false), after = try snapshot(edited: true)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        for failingRead in 2...4 {
            var reads = 0, completedSteps = 0, actions = 0
            let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in
                reads += 1
                return reads == failingRead ? after : before
            }, perform: { _, _, validate in
                actions += 1
                for _ in 0..<3 { try validate(); completedSteps += 1 }
            }, now: { now }, pause: { _ in })
            let result = sequence.run(deadline: .millisecondsFromNow(5000))
            #expect(result.category == .failed)
            #expect(result.detail == "edit-unverified")
            #expect(completedSteps == failingRead - 2)
            #expect(actions == 1)
            #expect(reads == failingRead)
        }
    }

    @Test func expiredAndUnchangedEditsNeverReachUI() throws {
        let before = try snapshot(edited: false)
        for unchanged in [false, true] {
            let request = try MessagesEditRequest(snapshot: before,
                replacement: unchanged ? "original" : "replacement", sandboxPrefix: nil)
            var actions = 0
            let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in before },
                perform: { _, _, _ in actions += 1 },
                now: { unchanged ? now : now.addingTimeInterval(900) }, pause: { _ in })
            #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .refused)
            #expect(actions == 0)
        }
    }

    @Test func sandboxLabelMustSurviveBeforeAnyMutation() throws {
        let before = try snapshot(edited: false)
        // Synthetic prefix exercises preservation without permitting a mutation
        // first and discovering the missing label in a postcondition read.
        for preserves in [false, true] {
            let request = try MessagesEditRequest(snapshot: before,
                replacement: preserves ? "original replacement" : "replacement", sandboxPrefix: "original")
            var actions = 0
            let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in before },
                perform: { _, _, _ in actions += 1; throw MessagesAXNavigationError.axFailure },
                now: { now }, pause: { _ in })
            let result = sequence.run(deadline: .millisecondsFromNow(5000))
            #expect(result.category == (preserves ? .failed : .refused))
            #expect(actions == (preserves ? 1 : 0))
        }
    }

    @Test(arguments: ["chat-row", "chat-guid", "message-row", "message-guid",
                      "sent-date", "chat-style", "part-index", "participants"])
    func postMutationIdentityDriftCannotBePolledAway(_ field: String) throws {
        let before = try snapshot(edited: false), after = try snapshot(edited: true)
        let drift = MessagesEditTargetResolver.Snapshot(
            chatRowid: field == "chat-row" ? 4 : after.chatRowid,
            chatGUID: field == "chat-guid" ? "other-chat" : after.chatGUID,
            messageRowid: field == "message-row" ? 61 : after.messageRowid,
            messageGUID: field == "message-guid" ? "other-message" : after.messageGUID,
            sentDateRaw: field == "sent-date" ? after.sentDateRaw + 1 : after.sentDateRaw,
            chatStyle: field == "chat-style" ? 43 : after.chatStyle,
            partIndex: field == "part-index" ? 1 : after.partIndex,
            partText: after.partText, fullText: after.fullText, nativeParts: after.nativeParts,
            participantHandles: field == "participants" ? ["other@example.com"] : after.participantHandles,
            editContext: after.editContext)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        var reads = 0, actions = 0, pauses = 0
        let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in
            reads += 1
            if reads == 1 { return before }
            return reads == 2 ? drift : after
        }, perform: { _, _, _ in actions += 1 }, now: { now }, pause: { _ in pauses += 1 })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .failed)
        #expect(result.detail == "edit-unverified")
        #expect(reads == 2)
        #expect(actions == 1)
        #expect(pauses == 0)
    }

    @Test func unchangedBaselineCanWaitForPersistedEdit() throws {
        let before = try snapshot(edited: false), after = try snapshot(edited: true)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        var reads = 0, actions = 0, pauses = 0
        let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in
            reads += 1
            return reads < 3 ? before : after
        }, perform: { _, _, _ in actions += 1 }, now: { now }, pause: { _ in pauses += 1 })
        let result = sequence.run(deadline: .millisecondsFromNow(5000))
        #expect(result.category == .ack)
        #expect(reads == 3)
        #expect(actions == 1)
        #expect(pauses == 1)
    }

    @Test func postconditionPollingHasAnAttemptBound() throws {
        let before = try snapshot(edited: false)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        var reads = 0, pauses = 0, actions = 0
        let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in
            reads += 1; return before
        }, perform: { _, _, _ in actions += 1 }, now: { now }, pause: { duration in
            #expect(duration > 0 && duration <= 50_000_000)
            pauses += 1
        })
        #expect(sequence.run(deadline: .millisecondsFromNow(5000)).category == .failed)
        #expect(reads == 61)
        #expect(pauses == 59)
        #expect(actions == 1)
    }

    @Test func expiredDeadlineDoesNotReadOrMutate() throws {
        let before = try snapshot(edited: false)
        let request = try MessagesEditRequest(snapshot: before, replacement: "replacement", sandboxPrefix: nil)
        var reads = 0, actions = 0
        let sequence = MessagesEditWorkerSequence(payload: request, read: { _ in
            reads += 1; return before
        }, perform: { _, _, _ in actions += 1 }, now: { now }, pause: { _ in })
        #expect(sequence.run(deadline: .millisecondsFromNow(0)).category == .refused)
        #expect(reads == 0)
        #expect(actions == 0)
    }
}
