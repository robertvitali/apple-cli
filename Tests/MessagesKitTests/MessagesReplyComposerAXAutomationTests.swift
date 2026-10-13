import Foundation
import CoreFoundation
import Testing
import TestSupport
@testable import AppleKit
@testable import MessagesKit

@Suite("Messages reply composer probe AX automation")
struct MessagesReplyComposerAXAutomationTests {
    private let scratch = ScratchDirs("reply-composer-probe")

    private func request(phase: String = "replyInspect",
                         participantHandles: [String] = ["+12125550100"],
                         isFromMe: Bool = false,
                         body: String = "apple-cli-test target",
                         requiredBodyPrefix: String = "apple-cli-test") throws -> MessagesReplyComposerProbeRequest {
        try MessagesReplyComposerProbeRequest(chatGUID: "iMessage;-;+12125550100",
                                             messageGUID: "message-guid",
                                             nativePartIndex: 2,
                                             nativePartGUID: "p:2/message-guid",
                                             phase: phase,
                                             expectedChatRowID: 3,
                                             expectedMessageRowID: 70,
                                             expectedParticipantHandles: participantHandles,
                                             expectedIsFromMe: isFromMe,
                                             expectedBodySHA256: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: body).value,
                                             expectedBodyUTF8Length: body.utf8.count,
                                             requiredBodyPrefix: requiredBodyPrefix)
    }

    private func dbFixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        let text = "apple-cli-test target"
        try fx.insertMessage(rowid: 70, guid: "message-guid", text: text,
                             attributedBody: replyNativeArchive(text, [(replyNativePartKey, NSNumber(value: 2), replyRange(text, "target"))]),
                             chatRowid: 3, date: fx.base + 10)
        return fx
    }

    @Test func oneReplyActionInspectsCleansAndAcks() throws {
        let driver = FakeReplyDriver()
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .ack(MessagesReplyComposerProbeDetail.verified))
        #expect(driver.message.performed == ["Name:Reply\nTarget:0x0\nSelector:(null)"])
        #expect(driver.replyTranscript.performed == ["AXCancel"])
        #expect(driver.replyVisible == false)
    }

    @Test func unavailableBodyEvidenceIsNotEmptyComposerProof() throws {
        let driver = FakeReplyDriver()
        driver.replyBody.bodyEvidence = .init(valueKind: .noValue, characterCount: nil, placeholder: "Reply")
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-evidence-unavailable"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func nonemptyComposerIsRefusedBeforeCleanup() throws {
        let driver = FakeReplyDriver()
        driver.replyBody.bodyEvidence = .init(valueKind: .attributedString(1), characterCount: 1, placeholder: "Reply")
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-not-empty"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func duplicateReplyActionsAreUnknownEvidence() throws {
        let driver = FakeReplyDriver()
        driver.message.actionNames.append("Name:Reply\nTarget:0x1\nSelector:(null)")
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("unknown-ax-value"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func replyActionMatcherAcceptsOnlyExactLocalizedEllipsisBoundary() {
        let title = "Répondre"
        #expect(MessagesAXActionMatcher.matches("Name:Répondre", title: title))
        #expect(MessagesAXActionMatcher.matches("Name:Répondre\nTarget:0x0", title: title))
        #expect(MessagesAXActionMatcher.matches("Name:Répondre…", title: title))
        #expect(MessagesAXActionMatcher.matches("Name:Répondre…\nTarget:0x0", title: title))

        #expect(!MessagesAXActionMatcher.matches("Name:Répondre...", title: title))
        #expect(!MessagesAXActionMatcher.matches("Name:Répondre……", title: title))
        #expect(!MessagesAXActionMatcher.matches("Name:Répondre… details", title: title))
        #expect(!MessagesAXActionMatcher.matches("Name:Répondre later", title: title))
        #expect(!MessagesAXActionMatcher.matches("Name:Répondre.\nTarget:0x0", title: title))
    }

    @Test func preexistingReplySurfaceIsRefusedBeforeAction() throws {
        let driver = FakeReplyDriver()
        driver.replyVisible = true
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-existing"))
        #expect(driver.message.performed.isEmpty)
    }

    @Test func cleanupRequiresRetainedCancelAction() throws {
        let driver = FakeReplyDriver()
        driver.replyTranscript.actionNames = []
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-cleanup-unavailable"))
        #expect(driver.replyVisible == true)
    }

    @Test func cleanupMustRemoveReplySurface() throws {
        let driver = FakeReplyDriver()
        driver.replyTranscript.onAction = { _ in }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-cleanup-failed"))
        #expect(driver.replyVisible == true)
    }

    @Test func bodyMutationDuringFinalAttachmentReadIsRefusedBeforeCancel() throws {
        let driver = FakeReplyDriver()
        var reads = 0
        driver.replyBody.onLinkedElementsRead = { [weak driver] in
            reads += 1
            if reads >= 2 {
                driver?.replyBody.bodyEvidence = .init(valueKind: .string(1), characterCount: 1, placeholder: "Reply")
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-not-empty"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func bodyMutationDuringCancelActionReadIsRefusedBeforeCancel() throws {
        let driver = FakeReplyDriver()
        driver.replyTranscript.onActionsRead = { [weak driver] in
            driver?.replyBody.bodyEvidence = .init(valueKind: .string(1), characterCount: 1, placeholder: "Reply")
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-not-empty"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func bodyMutationDuringFinalControlReadIsRefusedBeforeCancel() throws {
        let driver = FakeReplyDriver()
        driver.replyTranscript.onActionsRead = { [weak driver] in
            driver?.replyBody.onControlRead = { [weak driver] in
                driver?.replyBody.bodyEvidence = .init(valueKind: .string(1), characterCount: 1, placeholder: "Reply")
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-not-empty"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func attachmentAddedDuringCancelActionReadIsRefusedBeforeCancel() throws {
        let driver = FakeReplyDriver()
        driver.replyTranscript.onActionsRead = { [weak driver] in
            driver?.replyBody.staticChildren.append(FakeReplyNode(roleValue: "AXImage"))
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-attachment-evidence"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func modalAddedDuringCancelActionReadIsRefusedBeforeCancel() throws {
        let driver = FakeReplyDriver()
        let modal = FakeReplyNode(roleValue: "AXSheet")
        driver.replyTranscript.onActionsRead = { [weak driver] in
            driver?.extraWindowChildren = [modal]
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func attachmentAddedDuringFinalControlReadIsRefusedBeforeCancel() throws {
        let driver = FakeReplyDriver()
        driver.replyTranscript.onActionsRead = { [weak driver] in
            driver?.replyBody.onControlRead = { [weak driver] in
                driver?.replyBody.staticChildren.append(FakeReplyNode(roleValue: "AXImage"))
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-attachment-evidence"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func modalAddedDuringFinalControlReadIsRefusedBeforeCancel() throws {
        let driver = FakeReplyDriver()
        let modal = FakeReplyNode(roleValue: "AXSheet")
        driver.replyTranscript.onActionsRead = { [weak driver] in
            driver?.replyBody.onControlRead = { [weak driver] in
                driver?.extraWindowChildren = [modal]
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func normalComposerRequiresKnownPlaceholderBeforeClear() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(try action.preflight(resolved, context) == .requiresMutation)
        driver.normalBody.bodyEvidence = .init(valueKind: .noValue, characterCount: 0, placeholder: nil)
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.verified)
        #expect(throws: Error.self) {
            _ = try action.verify(resolved, response, context)
        }
    }

    @Test func normalComposerRequiresKnownPlaceholderDuringPreflight() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        driver.normalBody.bodyEvidence = .init(valueKind: .noValue, characterCount: 0, placeholder: nil)
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(throws: Error.self) {
            _ = try action.preflight(resolved, context)
        }
    }

    @Test func postCancelNormalComposerAttachmentDriftIsRefused() throws {
        let driver = FakeReplyDriver()
        driver.replyTranscript.onAction = { [weak driver] name in
            guard name == "AXCancel" else { throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable }
            driver?.replyVisible = false
            driver?.normalBody.staticChildren.append(FakeReplyNode(roleValue: "AXImage"))
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-attachment-evidence"))
    }

    @Test func postCancelNormalComposerControlDriftIsRefused() throws {
        let driver = FakeReplyDriver()
        driver.normalBody.enabledValue = true
        driver.normalBody.focusedValue = true
        driver.normalBody.settableValue = true
        driver.replyTranscript.onAction = { [weak driver] name in
            guard name == "AXCancel" else { throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable }
            driver?.replyVisible = false
            driver?.normalBody.enabledValue = false
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
    }

    @Test func postCancelModalDriftIsRefused() throws {
        let driver = FakeReplyDriver()
        let modal = FakeReplyNode(roleValue: "AXSheet")
        driver.replyTranscript.onAction = { [weak driver] name in
            guard name == "AXCancel" else { throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable }
            guard let driver else { return }
            driver.replyVisible = false
            driver.extraWindowChildren = [modal]
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
    }

    @Test func localAttachmentEvidenceRefusesAutomaticCleanup() throws {
        let driver = FakeReplyDriver()
        driver.replyBody.staticChildren.append(FakeReplyNode(roleValue: "AXImage"))
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-attachment-evidence"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func preopenDraftStateRefusesBeforeNativeOpen() throws {
        let driver = FakeReplyDriver()
        driver.normalBody.bodyEvidence = .init(valueKind: .string(5), characterCount: 5, placeholder: "iMessage")
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-not-empty"))
        #expect(driver.openCount == 0)
    }

    @Test func replyInspectReportsInitialRouteTargetDriftStage() throws {
        let driver = FakeReplyDriver()
        driver.message.selectedValue = false
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("target-drift-initial-route"))
    }

    @Test func replyInspectReportsPostOpenSafetyAXFailureStage() throws {
        let driver = FakeReplyDriver()
        driver.onOpen = { driver.root.onChildrenRead = { throw MessagesAXNavigationError.axFailure } }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-post-open-safety"))
    }

    @Test func replyInspectReportsRouteRevalidationTargetDriftStage() throws {
        let driver = FakeReplyDriver()
        driver.message.selectedValues = [true, false]
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("target-drift-route-revalidation"))
    }

    @Test func replyInspectReportsReplyOpenAXFailureStage() throws {
        let driver = FakeReplyDriver()
        driver.message.onAction = { _ in throw MessagesAXNavigationError.axFailure }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-reply-open"))
    }

    @Test func replyInspectReportsComposerReadinessAXFailureStage() throws {
        let driver = FakeReplyDriver()
        driver.message.onAction = { [weak driver] _ in
            driver?.replyVisible = true
            driver?.replyTranscript.onChildrenRead = { throw MessagesAXNavigationError.axFailure }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-composer-readiness"))
    }

    @Test func replyInspectReportsCleanupAXFailureStage() throws {
        let driver = FakeReplyDriver()
        driver.replyTranscript.onAction = { _ in throw MessagesAXNavigationError.axFailure }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
    }

    @Test func bodyChangeDuringInspectionIsRefusedBeforeCancel() throws {
        let driver = FakeReplyDriver()
        driver.replyBody.bodyEvidenceSequence = [
            .init(valueKind: .noValue, characterCount: 0, placeholder: "Reply"),
            .init(valueKind: .string(1), characterCount: 1, placeholder: "Reply")
        ]
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-not-empty"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func composerReplacementDuringInspectionIsRefusedAsAmbiguousBeforeCancel() throws {
        let driver = FakeReplyDriver()
        let replacement = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField", enabledValue: true, focusedValue: true, settableValue: true)
        replacement.bodyEvidence = .init(valueKind: .noValue, characterCount: 0, placeholder: "Reply")
        var reads = 0
        driver.replyTranscript.dynamicChildren = { [weak driver] in
            reads += 1
            guard let driver else { return [] }
            return reads >= 5 ? [replacement] : [driver.replyBody]
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ambiguous"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }


    @Test func replyComposerRefusesMultipleWindowWideBodiesBeforeCancel() throws {
        let driver = FakeReplyDriver()
        let extraBody = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField", enabledValue: true, focusedValue: true, settableValue: true)
        extraBody.bodyEvidence = .init(valueKind: .noValue, characterCount: 0, placeholder: "Reply")
        driver.message.onAction = { [weak driver] name in
            guard MessagesAXActionMatcher.matches(name, title: "Reply") else { throw MessagesReplyComposerAXError.replyActionUnavailable }
            driver?.replyVisible = true
            driver?.extraWindowChildren = [extraBody]
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ambiguous"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }


    @Test func replyComposerRefusesZeroWindowWideBodiesBeforeCancel() throws {
        let driver = FakeReplyDriver()
        driver.message.onAction = { [weak driver] name in
            guard MessagesAXActionMatcher.matches(name, title: "Reply") else { throw MessagesReplyComposerAXError.replyActionUnavailable }
            guard let driver else { return }
            driver.replyVisible = true
            driver.replyWindowChildrenOverride = { [weak driver] in driver.map { [$0.replyTranscript] } ?? [] }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ambiguous"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func replyComposerReplacementBodyAfterInitialCaptureIsOwnershipDriftBeforeCancel() throws {
        let driver = FakeReplyDriver()
        let replacement = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField", enabledValue: true, focusedValue: true, settableValue: true)
        replacement.bodyEvidence = .init(valueKind: .noValue, characterCount: 0, placeholder: "Reply")
        var evidenceReads = 0
        driver.replyBody.onBodyEvidenceRead = { [weak driver] in
            evidenceReads += 1
            if evidenceReads == 1 { driver?.replyBodyOverride = replacement }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func replyComposerReplacementTranscriptAfterInitialCaptureIsOwnershipDriftBeforeCancel() throws {
        let driver = FakeReplyDriver()
        let replacement = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView", descriptionValue: "Reply transcript", actionNames: ["AXCancel"])
        var attachmentReads = 0
        driver.replyBody.onLinkedElementsRead = { [weak driver] in
            attachmentReads += 1
            if attachmentReads == 1 { driver?.replyTranscriptOverride = replacement }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(replacement.performed.isEmpty)
    }

    @Test func replyComposerEnabledDriftDuringRevalidationRefusesBeforeCancel() throws {
        try expectReplyBodyControlDriftBeforeCancel { $0.replyBody.enabledValue = false }
    }

    @Test func replyComposerSettableDriftDuringRevalidationRefusesBeforeCancel() throws {
        try expectReplyBodyControlDriftBeforeCancel { $0.replyBody.settableValue = false }
    }

    @Test func replyComposerFocusedDriftDuringRevalidationRefusesBeforeCancel() throws {
        try expectReplyBodyControlDriftBeforeCancel { $0.replyBody.focusedValue = false }
    }

    private func expectReplyBodyControlDriftBeforeCancel(_ mutate: @escaping (FakeReplyDriver) -> Void) throws {
        let driver = FakeReplyDriver()
        var attachmentReads = 0
        driver.replyBody.onLinkedElementsRead = { [weak driver] in
            attachmentReads += 1
            guard attachmentReads == 1, let driver else { return }
            mutate(driver)
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func postCancelRequiresRestoredMainTranscriptIdentity() throws {
        let driver = FakeReplyDriver()
        let replacementMain = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView", descriptionValue: "Messages")
        replacementMain.staticChildren = [driver.message]
        driver.replyTranscript.onAction = { [weak driver] name in
            guard name == "AXCancel" else { throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable }
            guard let driver else { return }
            driver.replyVisible = false
            driver.mainTranscriptOverride = replacementMain
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
            .inspect(request(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-cleanup-failed"))
    }

    @Test func workerRegistryAcceptsOnlyInspectCommandWithReplyInspectPayload() throws {
        let driver = FakeReplyDriver()
        let registry = MessagesReplyComposerProbeWorkerRegistry(driver: driver)
        let payload = try request().workerPayloadData()
        #expect(registry.operation(for: try WorkerCommand(name: "messages.reply.inspect", payload: payload)) != nil)
        #expect(registry.operation(for: try WorkerCommand(name: "messages.reply.send", payload: payload)) == nil)
        let invalid = try JSONEncoder().encode(MessagesReplyComposerProbeRequestFixture(chatGUID: "iMessage;-;+12125550100", messageGUID: "message-guid", nativePartIndex: 2, nativePartGUID: "p:2/message-guid", phase: "replySend", expectedChatRowID: 3, expectedMessageRowID: 70, expectedParticipantHandles: ["+12125550100"], expectedIsFromMe: false, expectedBodySHA256: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "apple-cli-test target").value, expectedBodyUTF8Length: "apple-cli-test target".utf8.count, requiredBodyPrefix: "apple-cli-test"))
        #expect(registry.operation(for: try WorkerCommand(name: "messages.reply.inspect", payload: invalid)) == nil)
        let missingPhase = try JSONEncoder().encode(MessagesReplyComposerProbeRequestFixtureWithoutPhase(chatGUID: "iMessage;-;+12125550100", messageGUID: "message-guid", nativePartIndex: 2, nativePartGUID: "p:2/message-guid", expectedChatRowID: 3, expectedMessageRowID: 70, expectedParticipantHandles: ["+12125550100"], expectedIsFromMe: false, expectedBodySHA256: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "apple-cli-test target").value, expectedBodyUTF8Length: "apple-cli-test target".utf8.count, requiredBodyPrefix: "apple-cli-test"))
        #expect(registry.operation(for: try WorkerCommand(name: "messages.reply.inspect", payload: missingPhase)) == nil)
    }

    @Test func parentJournalUsesReplySendWithReplyInspectEvidence() throws {
        let payload = try request().workerPayloadData()
        let journal = try MessagesReplyComposerProbeParent.journalRequest(for: request(), payloadData: payload)
        #expect(journal.operationType == .replySend)
        #expect(journal.minimumEvidence.targetLength != payload.count)
        let tampered = try MessagesReplyComposerProbeParent.journalRequest(
            for: request(participantHandles: ["+12125550199"]),
            payloadData: payload
        )
        #expect(tampered.minimumEvidence.targetHash != journal.minimumEvidence.targetHash)
    }

    @Test func parentPayloadFileRequiresPrivateOutsideRepoFile() throws {
        let payload = try request().workerPayloadData()
        let dir = try scratch.directory()
        let file = dir.appendingPathComponent("reply-probe-input.json")
        FileManager.default.createFile(atPath: file.path, contents: payload)
        chmod(file.path, 0o600)
        #expect(try MessagesReplyComposerProbeParent.payloadData(fromFile: file.path, repoRoot: FileManager.default.currentDirectoryPath) == payload)
        chmod(file.path, 0o644)
        #expect(throws: Error.self) {
            _ = try MessagesReplyComposerProbeParent.payloadData(fromFile: file.path, repoRoot: FileManager.default.currentDirectoryPath)
        }
    }

    @Test func parentObservedActionVerifiesFreshDBBeforeClear() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        #expect(resolved.command.name == "messages.reply.inspect")
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(try action.preflight(resolved, context) == .requiresMutation)
        try fx.exec("UPDATE message SET text='changed target' WHERE ROWID=70;")
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.verified)
        #expect(throws: Error.self) {
            _ = try action.verify(resolved, response, context)
        }
    }

    @Test func parentPreflightRefusesUnsafeComposerByThrowing() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        driver.replyVisible = true
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(throws: Error.self) {
            _ = try action.preflight(resolved, context)
        }
    }

    @Test func parentPreflightAllowsNoSelectedReplyTargetWhenDraftIsClean() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        driver.message.selectedValue = false
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(try action.preflight(resolved, context) == .requiresMutation)
    }

    @Test func parentResolveBindsExpectedParticipantAndNativePart() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let payload = try request(participantHandles: ["+12125550199"]).workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: FakeReplyDriver(), readinessPause: { _ in })
        )
        #expect(throws: Error.self) {
            _ = try action.resolve()
        }
    }

    @Test func parentVerifyRequiresFreshCanonicalRouteBeforeClear() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(try action.preflight(resolved, context) == .requiresMutation)
        driver.processAvailable = false
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.verified)
        #expect(throws: Error.self) {
            _ = try action.verify(resolved, response, context)
        }
    }

    @Test func parentVerifyDoesNotRequireSelectedReplyTargetAfterAck() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(try action.preflight(resolved, context) == .requiresMutation)
        driver.message.selectedValue = false
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.verified)
        #expect(try action.verify(resolved, response, context) == MessagesReplyComposerProbeDetail.verified)
    }

    @Test func parentVerifyAllowsAmbiguousSelectedReplyTargetsAfterAck() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(try action.preflight(resolved, context) == .requiresMutation)
        driver.mainTranscript.staticChildren.append(FakeReplyNode(roleValue: "AXGroup", selectedValue: true, actionNames: ["Name:Reply\nTarget:0x1\nSelector:(null)"]))
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.verified)
        #expect(try action.verify(resolved, response, context) == MessagesReplyComposerProbeDetail.verified)
    }

    @Test func parentVerifyRequiresSameNormalBodyIdentityAfterAck() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(try action.preflight(resolved, context) == .requiresMutation)
        let replacement = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField", enabledValue: true, focusedValue: true, settableValue: true)
        replacement.bodyEvidence = .init(valueKind: .noValue, characterCount: 0, placeholder: "iMessage")
        driver.normalBodyOverride = replacement
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.verified)
        #expect(throws: Error.self) {
            _ = try action.verify(resolved, response, context)
        }
    }

    @Test func parentVerifyRequiresCleanNormalComposerBeforeClear() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        let payload = try request().workerPayloadData()
        let action = try MessagesReplyComposerProbeParent.observedAction(
            stateRoot: try scratch.directory().path,
            payloadData: payload,
            deadline: .millisecondsFromNow(5_000),
            makeChatDB: { try ChatDB(path: dbPath, book: AddressBook(), copyToTemp: false, homeDirectoryForTilde: homePath) },
            automation: MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in })
        )
        let resolved = try action.resolve()
        let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
        #expect(try action.preflight(resolved, context) == .requiresMutation)
        driver.normalBody.staticChildren.append(FakeReplyNode(roleValue: "AXImage"))
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.verified)
        #expect(throws: Error.self) {
            _ = try action.verify(resolved, response, context)
        }
    }

    @Test func requestRequiresFixedAppleCliTestPrefix() throws {
        #expect(throws: Error.self) {
            _ = try request(requiredBodyPrefix: "synthetic-test")
        }
    }

    @Test func bodyEvidenceRequiresExactIntegerCharacterCount() throws {
        #expect(MessagesAXBodyValueEvidence(valueKind: .noValue, characterCount: 0, placeholder: nil).provenEmpty)
        #expect(!MessagesAXBodyValueEvidence(valueKind: .noValue, characterCount: nil, placeholder: nil).provenEmpty)
        var double = 0.5
        let number = CFNumberCreate(nil, .doubleType, &double)!
        #expect(throws: MessagesAXNavigationError.unknownAXValue) {
            try LiveAXElement.checkedInteger(number, limit: 10)
        }
        var integer: Int64 = 0
        let integerNumber = CFNumberCreate(nil, .sInt64Type, &integer)!
        #expect(try LiveAXElement.checkedInteger(integerNumber, limit: 10) == 0)
    }
}

private struct MessagesReplyComposerProbeRequestFixture: Encodable {
    let chatGUID: String
    let messageGUID: String
    let nativePartIndex: Int
    let nativePartGUID: String?
    let phase: String
    let expectedChatRowID: Int64
    let expectedMessageRowID: Int64
    let expectedParticipantHandles: [String]
    let expectedIsFromMe: Bool
    let expectedBodySHA256: String
    let expectedBodyUTF8Length: Int
    let requiredBodyPrefix: String
    enum CodingKeys: String, CodingKey { case chatGUID = "chat_guid", messageGUID = "message_guid", nativePartIndex = "native_part_index", nativePartGUID = "native_part_guid", phase, expectedChatRowID = "expected_chat_rowid", expectedMessageRowID = "expected_message_rowid", expectedParticipantHandles = "expected_participant_handles", expectedIsFromMe = "expected_is_from_me", expectedBodySHA256 = "expected_body_sha256", expectedBodyUTF8Length = "expected_body_utf8_length", requiredBodyPrefix = "required_body_prefix" }
}

private struct MessagesReplyComposerProbeRequestFixtureWithoutPhase: Encodable {
    let chatGUID: String
    let messageGUID: String
    let nativePartIndex: Int
    let nativePartGUID: String?
    let expectedChatRowID: Int64
    let expectedMessageRowID: Int64
    let expectedParticipantHandles: [String]
    let expectedIsFromMe: Bool
    let expectedBodySHA256: String
    let expectedBodyUTF8Length: Int
    let requiredBodyPrefix: String
    enum CodingKeys: String, CodingKey { case chatGUID = "chat_guid", messageGUID = "message_guid", nativePartIndex = "native_part_index", nativePartGUID = "native_part_guid", expectedChatRowID = "expected_chat_rowid", expectedMessageRowID = "expected_message_rowid", expectedParticipantHandles = "expected_participant_handles", expectedIsFromMe = "expected_is_from_me", expectedBodySHA256 = "expected_body_sha256", expectedBodyUTF8Length = "expected_body_utf8_length", requiredBodyPrefix = "required_body_prefix" }
}

private let replyNativePartKey = NSAttributedString.Key("__kIMMessagePartAttributeName")

private func replyNativeArchive(_ text: String, _ attributes: [(NSAttributedString.Key, Any, NSRange)] = []) -> Data {
    let value = NSMutableAttributedString(string: text)
    for (key, object, range) in attributes {
        value.addAttribute(key, value: object, range: range)
    }
    return NSArchiver.archivedData(withRootObject: value)
}

private func replyRange(_ text: String, _ needle: String) -> NSRange {
    let range = (text as NSString).range(of: needle)
    precondition(range.location != NSNotFound)
    return range
}

private final class FakeReplyDriver: MessagesReplyComposerAXDriving {
    let root = FakeReplyNode(roleValue: "AXApplication")
    let window = FakeReplyNode(roleValue: "AXWindow")
    let mainTranscript = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView", descriptionValue: "Messages")
    var mainTranscriptOverride: FakeReplyNode?
    let message = FakeReplyNode(roleValue: "AXGroup", selectedValue: true, actionNames: ["Name:Reply\nTarget:0x0\nSelector:(null)"])
    let normalBody = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField", enabledValue: true, focusedValue: true, settableValue: true)
    var normalBodyOverride: FakeReplyNode?
    let replyTranscript = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView", descriptionValue: "Reply transcript", actionNames: ["AXCancel"])
    var replyTranscriptOverride: FakeReplyNode?
    let replyBody = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField", enabledValue: true, focusedValue: true, settableValue: true)
    var replyBodyOverride: FakeReplyNode?
    var replyVisible = false
    var replyWindowChildrenOverride: (() -> [FakeReplyNode])?
    var extraWindowChildren: [FakeReplyNode] = []
    var trusted = true
    var processAvailable = true
    var openCount = 0
    var onOpen: (() -> Void)?
    let identity = MessagesAXProcessIdentity(pid: 123, bundleURL: URL(fileURLWithPath: "/System/Applications/Messages.app"), launchDate: Date(timeIntervalSince1970: 1))

    init() {
        root.dynamicChildren = { [weak self] in self.map { [$0.window] } ?? [] }
        window.dynamicChildren = { [weak self] in
            guard let self else { return [] }
            let normalBody = self.normalBodyOverride ?? self.normalBody
            let mainTranscript = self.mainTranscriptOverride ?? self.mainTranscript
            let replyTranscript = self.replyTranscriptOverride ?? self.replyTranscript
            let replyBody = self.replyBodyOverride ?? self.replyBody
            let base = self.replyVisible ? (self.replyWindowChildrenOverride?() ?? [replyTranscript, replyBody]) : [mainTranscript, normalBody]
            return base + self.extraWindowChildren
        }
        mainTranscript.staticChildren = [message]
        replyTranscript.staticChildren = []
        message.onAction = { [weak self] name in
            guard MessagesAXActionMatcher.matches(name, title: "Reply") else { throw MessagesReplyComposerAXError.replyActionUnavailable }
            self?.replyVisible = true
        }
        replyTranscript.onAction = { [weak self] name in
            guard name == "AXCancel" else { throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable }
            self?.replyVisible = false
        }
        normalBody.bodyEvidence = .init(valueKind: .noValue, characterCount: 0, placeholder: "iMessage")
        replyBody.bodyEvidence = .init(valueKind: .noValue, characterCount: 0, placeholder: "Reply")
    }

    func checkAccessibilityTrusted(prompt: Bool) -> Bool { trusted }
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess {
        openCount += 1
        onOpen?()
        return process
    }
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess {
        guard processAvailable else { throw MessagesReplyComposerAXError.axFailure }
        return process
    }
    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool { process.identity == identity }
    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { replyVisible ? replyBody : normalBody }
    func replyActionTitles(deadline: WorkerDeadline) throws -> [String] { ["Reply"] }
    func normalComposePlaceholders(deadline: WorkerDeadline) throws -> [String] { ["iMessage", "Text Message"] }
    func replyTranscriptDescription(deadline: WorkerDeadline) throws -> String? { "Reply transcript" }
    private var process: MessagesAXProcess { MessagesAXProcess(identity: identity, root: root) }
}

private final class FakeReplyNode: MessagesAXElement {
    let roleValue: String
    let identifierValue: String?
    let descriptionValue: String?
    var selectedValue: Bool?
    var selectedValues: [Bool?] = []
    var enabledValue: Bool?
    var focusedValue: Bool?
    var settableValue: Bool?
    var actionNames: [String]
    var performed: [String] = []
    var staticChildren: [FakeReplyNode]
    var dynamicChildren: (() -> [FakeReplyNode])?
    var bodyEvidence: MessagesAXBodyValueEvidence = .init(valueKind: .noValue, characterCount: 0, placeholder: nil)
    var bodyEvidenceSequence: [MessagesAXBodyValueEvidence] = []
    var onChildrenRead: (() throws -> Void)?
    var onLinkedElementsRead: (() -> Void)?
    var onActionsRead: (() -> Void)?
    var onBodyEvidenceRead: (() -> Void)?
    var onControlRead: (() -> Void)?
    var onAction: ((String) throws -> Void)?
    weak var parentNode: FakeReplyNode?

    init(roleValue: String, identifierValue: String? = nil, descriptionValue: String? = nil,
         selectedValue: Bool? = nil, enabledValue: Bool? = nil, focusedValue: Bool? = nil,
         settableValue: Bool? = nil, actionNames: [String] = [], staticChildren: [FakeReplyNode] = []) {
        self.roleValue = roleValue
        self.identifierValue = identifierValue
        self.descriptionValue = descriptionValue
        self.selectedValue = selectedValue
        self.enabledValue = enabledValue
        self.focusedValue = focusedValue
        self.settableValue = settableValue
        self.actionNames = actionNames
        self.staticChildren = staticChildren
    }

    func sameIdentity(as other: any MessagesAXElement) -> Bool { (other as? FakeReplyNode) === self }
    func role(deadline: WorkerDeadline) throws -> String { roleValue }
    func identifier(deadline: WorkerDeadline) throws -> String? { identifierValue }
    func axDescription(deadline: WorkerDeadline) throws -> String? { descriptionValue }
    func axValue(deadline: WorkerDeadline) throws -> String? { nil }
    func candidateValueText(deadline: WorkerDeadline) throws -> String? { nil }
    func axTitle(deadline: WorkerDeadline) throws -> String? { nil }
    func subrole(deadline: WorkerDeadline) throws -> String? { nil }
    func enabled(deadline: WorkerDeadline) throws -> Bool? {
        onControlRead?()
        return enabledValue
    }
    func selected(deadline: WorkerDeadline) throws -> Bool? {
        if !selectedValues.isEmpty { return selectedValues.removeFirst() }
        return selectedValue
    }
    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { rootWindow() }
    func directWindows(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] { try children(limit: limit, deadline: deadline) }
    func parent(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { parentNode }
    func processIdentifier(deadline: WorkerDeadline) throws -> Int32? { 123 }
    func valueSettable(deadline: WorkerDeadline) throws -> Bool? {
        onControlRead?()
        return settableValue
    }
    func actions(deadline: WorkerDeadline) throws -> [String] {
        onActionsRead?()
        return actionNames
    }
    func children(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try onChildrenRead?()
        let nodes = dynamicChildren?() ?? staticChildren
        for node in nodes { node.parentNode = self }
        guard nodes.count <= limit else { throw MessagesAXNavigationError.traversalLimit }
        return nodes
    }
    func childrenInNavigationOrder(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]? { nil }
    func linkedElements(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        onLinkedElementsRead?()
        return []
    }
    func setValue(_ value: String, deadline: WorkerDeadline) throws {}
    func focused(deadline: WorkerDeadline) throws -> Bool? {
        onControlRead?()
        return focusedValue
    }
    func bodyValueEvidence(deadline: WorkerDeadline) throws -> MessagesAXBodyValueEvidence {
        let evidence = bodyEvidenceSequence.isEmpty ? bodyEvidence : bodyEvidenceSequence.removeFirst()
        onBodyEvidenceRead?()
        return evidence
    }
    func performAction(named name: String, deadline: WorkerDeadline) throws {
        performed.append(name)
        try onAction?(name)
    }

    private func rootWindow() -> FakeReplyNode? {
        var node: FakeReplyNode? = self
        while let current = node {
            if current.roleValue == "AXWindow" { return current }
            node = current.parentNode
        }
        return nil
    }
}
