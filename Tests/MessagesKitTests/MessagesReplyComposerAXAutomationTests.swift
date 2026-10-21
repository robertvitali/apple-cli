import Foundation
import CoreFoundation
import AppKit
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


    private func sendRequest(text: String = "apple-cli-test reply",
                             attachmentDraft: MessagesReplyAttachmentDraftEvidence? = nil) throws -> MessagesReplySendRequest {
        try MessagesReplySendRequest(chatGUID: "iMessage;-;+12125550100",
                                     messageGUID: "message-guid",
                                     nativePartIndex: 2,
                                     nativePartGUID: "p:2/message-guid",
                                     expectedChatRowID: 3,
                                     expectedMessageRowID: 70,
                                     expectedParticipantHandles: ["+12125550100"],
                                     expectedIsFromMe: false,
                                     expectedBodySHA256: AppleAutomationJournal.targetDigest(forOpaqueIdentifier: "apple-cli-test target").value,
                                     expectedBodyUTF8Length: "apple-cli-test target".utf8.count,
                                     requiredBodyPrefix: "apple-cli-test",
                                     text: attachmentDraft == nil ? text : nil,
                                     attachmentDraft: attachmentDraft)
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


    @Test func sendInsertsExactTextAndAcknowledgesAlreadyRestoredWithoutCancel() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
            driver.replyVisible = false
        }).send(sendRequest(text: "apple-cli-test cafe\u{0301}"), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .ack(MessagesReplySendACKDetail.alreadyRestoredVerified))
        #expect(returnPresses == 1)
        #expect(driver.replyBody.bodyText == "apple-cli-test cafe\u{0301}")
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func sendCancelsRetainedEmptyOwnedComposerOnceAfterSend() throws {
        let driver = FakeReplyDriver()
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, deadline in
            try driver.replyBody.setValue("", deadline: deadline)
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .ack(MessagesReplySendACKDetail.retainedEmptyCancelledVerified))
        #expect(driver.replyTranscript.performed == ["AXCancel"])
        #expect(driver.replyVisible == false)
    }

    @Test func sendPostDispatchEmptyCancelRefusesIfBodyChangesDuringActionRead() throws {
        let driver = FakeReplyDriver()
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { [driver] _, deadline in
            try driver.replyBody.setValue("", deadline: deadline)
            driver.replyTranscript.onActionsRead = { [driver] in
                driver.replyBody.applyBodyText("apple-cli-test changed")
            }
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-possible-draft-remains"))
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
        #expect(driver.replyBody.bodyText == "apple-cli-test changed")
    }



    @Test func sendPostDispatchEmptyCancelRefusesIfAttachmentAppearsDuringActionRead() throws {
        let driver = FakeReplyDriver()
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { [driver] _, deadline in
            try driver.replyBody.setValue("", deadline: deadline)
            driver.replyTranscript.onActionsRead = { [driver] in
                driver.replyBody.staticChildren.append(FakeReplyNode(roleValue: "AXImage"))
            }
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-attachment-evidence"))
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendPostDispatchEmptyCancelRefusesIfModalAppearsDuringActionRead() throws {
        let driver = FakeReplyDriver()
        let modal = FakeReplyNode(roleValue: "AXSheet")
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { [driver] _, deadline in
            try driver.replyBody.setValue("", deadline: deadline)
            driver.replyTranscript.onActionsRead = { [driver] in
                driver.extraWindowChildren = [modal]
            }
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendPostDispatchEmptyCancelRefusesIfBodyChangesDuringFinalControlRead() throws {
        let driver = FakeReplyDriver()
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { [driver] _, deadline in
            try driver.replyBody.setValue("", deadline: deadline)
            driver.replyTranscript.onActionsRead = { [driver] in
                driver.replyBody.onControlRead = { [driver] in
                    driver.replyBody.applyBodyText("apple-cli-test changed")
                }
            }
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-possible-draft-remains"))
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
        #expect(driver.replyBody.bodyText == "apple-cli-test changed")
    }

    @Test func sendWaitsForTransientRetainedComposerTextToClearAfterReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        var pauses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { [driver] _ in
            pauses += 1
            if pauses == 1 { driver.replyBody.applyBodyText("") }
        }, sendReturnKey: { [driver] _, _ in
            returnPresses += 1
            driver.replyBody.applyBodyText("apple-cli-test transient")
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .ack(MessagesReplySendACKDetail.retainedEmptyCancelledVerified))
        #expect(returnPresses == 1)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
        #expect(driver.replyVisible == false)
    }

    @Test func sendBoundsPersistentRetainedComposerTextAfterOneReturnWithoutClearing() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { [driver] _, _ in
            returnPresses += 1
            driver.replyBody.applyBodyText("apple-cli-test persistent")
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-possible-draft-remains"))
        #expect(returnPresses == 1)
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
        #expect(driver.replyBody.bodyText == "apple-cli-test persistent")
    }

    @Test func sendRefusesWrongAppRootFocusBeforeReturnAndClearsExactOwnedDraft() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.appFocusedOverride = driver.message
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText.isEmpty)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
        #expect(driver.replyVisible == false)
    }

    @Test func sendAllowsSystemFocusMismatchWhenAppRootFocusIsExactBody() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.focusedOverride = driver.message
        driver.appFocusedOverride = driver.replyBody
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { [driver] _, _ in
            returnPresses += 1
            driver.replyVisible = false
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .ack(MessagesReplySendACKDetail.alreadyRestoredVerified))
        #expect(returnPresses == 1)
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func sendRefusesMissingAppRootFocusBeforeReturnAndClearsExactOwnedDraft() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.appFocusAvailable = false
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText.isEmpty)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func sendMapsAppRootFocusAXFailureToCleanupStage() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.appFocusError = MessagesReactionAXError.axFailure
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func sendRefusesWrongAppRootFocusedBodyBeforeReturnAndClearsExactOwnedDraft() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.appFocusedOverride = driver.message
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText.isEmpty)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func sendRefusesAppRootFocusedElementWithWrongPIDBeforeReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        let foreign = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField", enabledValue: true, focusedValue: true, settableValue: true)
        foreign.processIdentifierValue = 999
        foreign.parentNode = driver.window
        driver.appFocusedOverride = foreign
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func sendRefusesAppRootFocusedElementWithWrongWindowBeforeReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        let otherWindow = FakeReplyNode(roleValue: "AXWindow")
        let foreign = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField", enabledValue: true, focusedValue: true, settableValue: true)
        foreign.parentNode = otherWindow
        driver.appFocusedOverride = foreign
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func sendRefusesPreFocusFrontmostDriftBeforeReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.frontmostResults = [false]
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func sendRefusesPostFocusFrontmostDriftBeforeReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.frontmostResults = [true, false]
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func sendRefusesFocusDriftDuringFinalAttachmentScanBeforeReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        var afterPreSendActionRead = false
        var attachmentReadsAfterAction = 0
        driver.replyTranscript.onActionsRead = { afterPreSendActionRead = true }
        driver.replyBody.onLinkedElementsRead = { [driver] in
            guard afterPreSendActionRead, driver.replyBody.bodyText == sendRequestText else { return }
            attachmentReadsAfterAction += 1
            if attachmentReadsAfterAction == 6 { driver.appFocusedOverride = driver.message }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func sendRefusesFocusDriftDuringFinalModalScanBeforeReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        var afterPreSendActionRead = false
        var windowReadsAfterAction = 0
        driver.replyTranscript.onActionsRead = { afterPreSendActionRead = true }
        driver.window.onChildrenRead = { [driver] in
            guard afterPreSendActionRead, driver.replyVisible, driver.replyBody.bodyText == sendRequestText else { return }
            windowReadsAfterAction += 1
            if windowReadsAfterAction == 5 { driver.appFocusedOverride = driver.message }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func sendRefusesProcessDriftAfterAppRootFocusBeforeReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.onAppFocusRead = { [weak driver] in driver?.processAvailable = false }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func sendRefusesLaunchIdentityDriftAfterAppRootFocusBeforeReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.onAppFocusRead = { [weak driver] in
            guard let driver else { return }
            driver.identity = MessagesAXProcessIdentity(pid: 123, bundleURL: URL(fileURLWithPath: "/System/Applications/Messages.app"), launchDate: Date(timeIntervalSince1970: 2))
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("target-drift-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func sendRefusesRootDriftAfterAppRootFocusBeforeReturn() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.onAppFocusRead = { [weak driver] in
            driver?.canonicalRootOverride = FakeReplyNode(roleValue: "AXApplication")
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("target-drift-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func sendMapsAppRootCommonFocusedDeadlineToDeadlineFailure() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.appFocusError = MessagesReactionAXError.deadlineExpired
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("deadline-expired"))
        #expect(returnPresses == 0)
    }

    @Test func sendMapsForeignFrontmostTargetDriftToVerificationStageRefusal() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { [driver] _, deadline in
            returnPresses += 1
            try driver.replyBody.setValue("", deadline: deadline)
            driver.frontmostError = MessagesReactionAXError.targetDrift
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("target-drift-verification"))
        #expect(returnPresses == 1)
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func sendCleanupRefusesIfExactTextChangesDuringCancelActionRead() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        var actionReads = 0
        driver.appFocusedOverride = driver.message
        driver.replyTranscript.onActionsRead = { [weak driver] in
            actionReads += 1
            if actionReads == 2 { driver?.replyBody.applyBodyText("apple-cli-test changed") }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText == "apple-cli-test changed")
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendCancelsOwnedEmptyComposerWhenInsertionThrowsBeforeTextLands() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.replyBody.onSetValue = { value in
            if !value.isEmpty { throw MessagesReplyComposerAXError.axFailure }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText.isEmpty)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
        #expect(driver.replyVisible == false)
    }

    @Test func sendEmptyCleanupRefusesIfBodyChangesDuringCancelActionRead() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.replyBody.onSetValue = { value in
            if !value.isEmpty { throw MessagesReplyComposerAXError.axFailure }
        }
        driver.replyTranscript.onActionsRead = { [weak driver] in
            driver?.replyBody.applyBodyText("apple-cli-test changed")
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText == "apple-cli-test changed")
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendPostClearCleanupRefusesIfBodyChangesDuringFinalControlRead() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.appFocusedOverride = driver.message
        driver.replyBody.onSetValue = { [driver] value in
            if value.isEmpty {
                driver.replyBody.onControlRead = { [driver] in
                    driver.replyBody.applyBodyText("apple-cli-test changed")
                }
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText == "apple-cli-test changed")
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendPostClearCleanupRefusesIfBodyChangesDuringFinalModalRead() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.appFocusedOverride = driver.message
        driver.replyBody.onSetValue = { [driver] value in
            if value.isEmpty {
                driver.window.onChildrenRead = { [driver] in
                    driver.replyBody.applyBodyText("apple-cli-test changed")
                }
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText == "apple-cli-test changed")
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendEmptyCleanupRefusesIfBodyChangesDuringFinalControlRead() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.replyBody.onSetValue = { value in
            if !value.isEmpty { throw MessagesReplyComposerAXError.axFailure }
        }
        driver.replyTranscript.onActionsRead = { [driver] in
            driver.replyBody.onControlRead = { [driver] in
                driver.replyBody.applyBodyText("apple-cli-test changed")
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText == "apple-cli-test changed")
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendEmptyCleanupRefusesIfBodyChangesDuringFinalModalRead() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.replyBody.onSetValue = { value in
            if !value.isEmpty { throw MessagesReplyComposerAXError.axFailure }
        }
        driver.replyTranscript.onActionsRead = { [driver] in
            driver.window.onChildrenRead = { [driver] in
                driver.replyBody.applyBodyText("apple-cli-test changed")
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText == "apple-cli-test changed")
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendPostClearCleanupRefusesIfAttachmentAppearsDuringFinalProof() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.appFocusedOverride = driver.message
        driver.replyBody.onSetValue = { [driver] value in
            if value.isEmpty {
                driver.replyBody.staticChildren.append(FakeReplyNode(roleValue: "AXImage"))
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendPostClearCleanupRefusesIfModalAppearsDuringFinalProof() throws {
        let driver = FakeReplyDriver()
        let modal = FakeReplyNode(roleValue: "AXSheet")
        var returnPresses = 0
        driver.appFocusedOverride = driver.message
        driver.replyBody.onSetValue = { [driver] value in
            if value.isEmpty { driver.extraWindowChildren = [modal] }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendEmptyCleanupRefusesIfAttachmentAppearsDuringFinalProof() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.replyBody.onSetValue = { [driver] value in
            if !value.isEmpty {
                driver.replyBody.staticChildren.append(FakeReplyNode(roleValue: "AXImage"))
                throw MessagesReplyComposerAXError.axFailure
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendEmptyCleanupRefusesIfModalAppearsDuringFinalProof() throws {
        let driver = FakeReplyDriver()
        let modal = FakeReplyNode(roleValue: "AXSheet")
        var returnPresses = 0
        driver.replyBody.onSetValue = { [driver] value in
            if !value.isEmpty {
                driver.extraWindowChildren = [modal]
                throw MessagesReplyComposerAXError.axFailure
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendCleanupDoesNotAttemptSecondCancelAfterFirstCancelThrows() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.appFocusedOverride = driver.message
        driver.replyTranscript.onAction = { name in
            guard name == "AXCancel" else { throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable }
            throw MessagesReplyComposerAXError.axFailure
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
        #expect(driver.replyVisible == true)
    }

    @Test func sendLeavesPartialInsertedTextUntouchedWhenInsertionThrows() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        driver.replyBody.onSetValue = { value in
            if !value.isEmpty {
                driver.replyBody.applyBodyText("apple-cli-test partial")
                throw MessagesReplyComposerAXError.axFailure
            }
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-cleanup"))
        #expect(returnPresses == 0)
        #expect(driver.replyBody.bodyText == "apple-cli-test partial")
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func combinedWorkerRegistryAcceptsReplySendButNotInspectCommand() throws {
        let registry = MessagesWorkerRegistry(replyDriver: FakeReplyDriver())
        let payload = try sendRequest().workerPayloadData()
        #expect(registry.operation(for: try WorkerCommand(name: "messages.reply.send", payload: payload)) != nil)
        #expect(registry.operation(for: try WorkerCommand(name: "messages.reply.inspect", payload: try request().workerPayloadData())) == nil)
    }


    @Test func sendDoesNotRetryOrClearTextWhenReturnDispatchThrows() throws {
        let driver = FakeReplyDriver()
        var returnPresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
            throw MessagesReplyComposerAXError.axFailure
        }).send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .failed("ax-failure-verification"))
        #expect(returnPresses == 1)
        #expect(driver.replyBody.bodyText == "apple-cli-test reply")
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyVisible == true)
    }

    @Test func sendLeavesNonemptyComposerUnchangedAfterReturnDispatch() throws {
        let driver = FakeReplyDriver()
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in })
            .send(sendRequest(), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-possible-draft-remains"))
        #expect(driver.replyBody.bodyText == "apple-cli-test reply")
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func bodyTextSnapshotRequiresUTF16CountConsistency() throws {
        #expect(throws: Error.self) {
            _ = try MessagesAXBodyTextSnapshot(text: "apple-cli-test 😊", characterCount: "apple-cli-test 😊".count)
        }
        let snapshot = try MessagesAXBodyTextSnapshot(text: "apple-cli-test 😊", characterCount: "apple-cli-test 😊".utf16.count)
        #expect(snapshot.utf16Count == "apple-cli-test 😊".utf16.count)
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

    @Test(arguments: ["clean", "draft", "attachment", "modal", "unknown-overlay", "not-frontmost"])
    func sharingAffordancePreservesComposerSafety(state: String) throws {
        let driver = FakeReplyDriver()
        driver.window.identifierValue = "SceneWindow"
        driver.window.subroleValue = "AXStandardWindow"
        let overlay = FakeReplyNode(roleValue: "AXWindow", focusedValue: false)
        overlay.subroleValue = "AXDialog"
        overlay.mainValue = false
        let button = FakeReplyNode(roleValue: "AXButton")
        button.titleValue = "WindowSharingSessionButton"
        button.windowUnavailable = true
        overlay.staticChildren = [button]
        driver.root.dynamicChildren = { [weak driver] in driver.map { [$0.window, overlay] } ?? [] }
        switch state {
        case "draft": driver.normalBody.applyBodyText("apple-cli-test existing draft")
        case "attachment": driver.normalBody.staticChildren = [FakeReplyNode(roleValue: "AXImage")]
        case "modal": driver.extraWindowChildren = [FakeReplyNode(roleValue: "AXSheet")]
        case "unknown-overlay": button.titleValue = "Continue"
        case "not-frontmost": driver.frontmostResults = [false]
        default: break
        }
        var returnPresses = 0
        let automation = MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in }, sendReturnKey: { _, _ in
            returnPresses += 1
        })
        let outcome = try state == "not-frontmost"
            ? automation.send(sendRequest(), deadline: .millisecondsFromNow(5_000))
            : automation.inspect(request(), deadline: .millisecondsFromNow(5_000))
        if state == "clean" {
            #expect(outcome == .ack(MessagesReplyComposerProbeDetail.verified))
            #expect(driver.message.performed.count == 1)
        } else {
            #expect(outcome != .ack(MessagesReplyComposerProbeDetail.verified))
            if state == "not-frontmost" {
                #expect(outcome == .refused("reply-composer-ownership-drift"))
                #expect(driver.replyTranscript.performed == ["AXCancel"])
            } else {
                #expect(driver.message.performed.isEmpty)
            }
        }
        #expect(returnPresses == 0)
        #expect(overlay.performed.isEmpty)
        #expect(button.performed.isEmpty)
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



    @Test func attachmentDraftPreparationCreatesBoundedOwnedCopyPayload() throws {
        let sourceDir = try scratch.directory()
        let source = sourceDir.appendingPathComponent("apple-cli-test source.txt")
        let bytes = Data("apple-cli-test attachment".utf8)
        FileManager.default.createFile(atPath: source.path, contents: bytes)
        chmod(source.path, 0o600)
        let copyRoot = try scratch.directory()
        let payload = try MessagesReplyComposerProbeParent.payloadDataForAttachmentDraft(base: request(), rawFilePath: source.path,
                                                                                        scratchRoot: copyRoot.path,
                                                                                        repoRoot: FileManager.default.currentDirectoryPath,
                                                                                        deadline: .millisecondsFromNow(5_000))
        let decoded = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        #expect(decoded.phase == "replyAttachmentDraftInspect")
        let attachment = try #require(decoded.attachmentDraft)
        #expect(attachment.copyPath.hasPrefix(copyRoot.path))
        #expect(URL(fileURLWithPath: attachment.copyPath).lastPathComponent == source.lastPathComponent)
        #expect(attachment.copySize == bytes.count)
        #expect(try Data(contentsOf: URL(fileURLWithPath: attachment.copyPath)) == bytes)
        var st = stat()
        #expect(stat(attachment.copyPath, &st) == 0)
        #expect((st.st_mode & 0o777) == 0o600)
        #expect(payload.count <= 4096)
        #expect(MessagesReplyComposerProbeWorkerRegistry(driver: FakeReplyDriver()).operation(for: try WorkerCommand(name: "messages.reply.inspect", payload: payload)) != nil)
        #expect(MessagesWorkerRegistry().operation(for: try WorkerCommand(name: "messages.reply.inspect", payload: payload)) == nil)
        #expect(WorkerOperationResult(.ack, detail: MessagesReplyComposerProbeDetail.attachmentDraftVerified).detail == MessagesReplyComposerProbeDetail.attachmentDraftVerified)
    }

    @Test func attachmentDraftPreparationUsesSharedTwentyFiveMiBLimit() throws {
        let sourceDir = try scratch.directory()
        let source = sourceDir.appendingPathComponent("apple-cli-test-large.bin")
        let bytes = Data(repeating: 0x41, count: 70_000)
        FileManager.default.createFile(atPath: source.path, contents: bytes)
        chmod(source.path, 0o600)
        let payload = try MessagesReplyComposerProbeParent.payloadDataForAttachmentDraft(base: request(), rawFilePath: source.path,
                                                                                        scratchRoot: try scratch.directory().path,
                                                                                        repoRoot: FileManager.default.currentDirectoryPath,
                                                                                        deadline: .millisecondsFromNow(5_000))
        let decoded = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let attachment = try #require(decoded.attachmentDraft)
        #expect(attachment.copySize == bytes.count)
        #expect(try Data(contentsOf: URL(fileURLWithPath: attachment.copyPath)).count == bytes.count)
    }

    @Test func sendAttachmentRequiresConfiguredNativeMarkerShapeBeforeReturn() throws {
        let driver = FakeReplyDriver()
        let (_, attachment) = try attachmentDraftPayload()
        let request = try sendRequest(attachmentDraft: attachment)
        let clipboard = FakeMessagesClipboard()
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var pastePresses = 0
        var returnPresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            sendReturnKey: { _, _ in returnPresses += 1 },
                                                            clipboardFactory: { clipboard },
                                                            pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                            sendPasteKey: { _, _, _ in
                                                                pastePresses += 1
                                                                let node = FakeReplyNode(roleValue: "AXImage", identifierValue: "attachment")
                                                                driver.replyBody.staticChildren = [node]
                                                                driver.replyBody.applyBodyText("\u{fffc}")
                                                            })
            .send(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-draft-unverified"))
        #expect(pastePresses == 1)
        #expect(returnPresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(clipboard.restoredSnapshots.map(\.items) == [clipboard.original.items])
    }

    @Test func sendAttachmentPastesOnceSendsOnceWithConfiguredNativeMarkerShape() throws {
        let driver = FakeReplyDriver()
        let (_, attachment) = try attachmentDraftPayload()
        let request = try sendRequest(attachmentDraft: attachment)
        let clipboard = FakeMessagesClipboard()
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var pastePresses = 0
        var returnPresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            sendReturnKey: { _, _ in
                                                                returnPresses += 1
                                                                driver.replyVisible = false
                                                            },
                                                            clipboardFactory: { clipboard },
                                                            pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                            allowedAttachmentDraftMarkers: ["\u{fffc}"],
                                                            sendPasteKey: { _, _, _ in
                                                                pastePresses += 1
                                                                driver.mainTranscript.parentNode = driver.window
                                                                driver.replyBody.staticLinked = [driver.mainTranscript]
                                                                let node = FakeReplyNode(roleValue: "AXImage", identifierValue: "attachment")
                                                                driver.replyBody.staticChildren = [node]
                                                                driver.replyBody.applyBodyText("\u{fffc}")
                                                            })
            .send(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .ack(MessagesReplySendACKDetail.alreadyRestoredVerified))
        #expect(pastePresses == 1)
        #expect(returnPresses == 1)
        #expect(clipboard.restoredSnapshots.map(\.items) == [clipboard.original.items])
    }

    @Test(arguments: [false, true])
    func sendAttachmentAcceptsNativeMarkerWithoutBodyAttachmentChild(retainedMainPresent: Bool) throws {
        let result = try simulateNativeAttachmentSend { driver in
            if retainedMainPresent { driver.extraWindowChildren = [driver.mainTranscript] }
        }
        #expect(result.outcome == .ack(MessagesReplySendACKDetail.alreadyRestoredVerified))
        #expect(result.pastes == 1)
        #expect(result.sends == 1)
        #expect(result.clipboard.restoredSnapshots.map(\.items) == [result.clipboard.original.items])
    }

    @Test(arguments: ["replacement-main", "third-transcript", "missing-target", "replaced-target", "foreign-target", "missing-action"])
    func sendAttachmentRefusesUnownedTranscriptStructure(kind: String) throws {
        let result = try simulateNativeAttachmentSend { driver in
            driver.extraWindowChildren = [driver.mainTranscript]
            driver.replyBody.staticLinked = [driver.mainTranscript]
            switch kind {
            case "missing-action": driver.message.actionNames = []
            case "replacement-main":
                driver.extraWindowChildren = [FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView", descriptionValue: "Messages")]
                driver.replyBody.staticLinked = driver.extraWindowChildren
            case "third-transcript":
                driver.extraWindowChildren.append(FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView"))
            case "missing-target": driver.mainTranscript.staticChildren = []
            case "replaced-target":
                driver.mainTranscript.staticChildren = [FakeReplyNode(roleValue: "AXGroup", selectedValue: true, actionNames: driver.message.actionNames)]
            default: driver.message.processIdentifierValue = 456
            }
        }
        let reason: String
        switch kind {
        case "replacement-main": reason = "main-transcript"
        case "third-transcript": reason = "transcript-count"
        case "foreign-target": reason = "main-target-process"
        case "missing-action": reason = "main-target-action-missing"
        default: reason = "main-target-missing"
        }
        #expect(result.outcome == .refused("reply-attachment-ownership-after-paste-\(reason)"))
        #expect(result.sends == 0)
        #expect(result.driver.replyTranscript.performed.isEmpty)
    }

    @Test(arguments: ["", "\u{fffc}", "\u{fffc}\nextra", "\u{fffc}\u{fffc}\n", "\n\u{fffc}\n"])
    func sendAttachmentRefusesUnexpectedNativeMarker(text: String) throws {
        let result = try simulateNativeAttachmentSend { driver in driver.replyBody.applyBodyText(text) }
        #expect(result.outcome == .refused("reply-attachment-draft-unverified"))
        #expect(result.sends == 0)
    }

    @Test(arguments: [false, true])
    func attachmentRetainedAncestryAcceptsAbsentBodyLink(mainInGraph: Bool) throws {
        let result = try simulateNativeAttachmentSend { driver in
            driver.mainTranscript.parentNode = driver.window
            driver.mainTranscript.staticChildren = []
            driver.replyTranscript.staticLinked = mainInGraph ? [driver.mainTranscript] : []
            driver.replyBody.staticLinked = []
        }
        #expect(result.outcome == .ack(MessagesReplySendACKDetail.alreadyRestoredVerified))
        #expect(result.pastes == 1)
        #expect(result.sends == 1)
        #expect(result.clipboard.restoredSnapshots.map(\.items) == [result.clipboard.original.items])
    }

    @Test func attachmentAbsentLinkDoesNotRetryOrRepeatPaste() throws {
        var pauses = 0
        let result = try simulateNativeAttachmentSend(readinessPause: { _, _ in pauses += 1 }) { driver in
            driver.mainTranscript.staticChildren = []
            driver.replyTranscript.staticLinked = [driver.mainTranscript]
            driver.replyBody.staticLinked = []
        }
        #expect(result.outcome == .ack(MessagesReplySendACKDetail.alreadyRestoredVerified))
        #expect(pauses == 0)
        #expect(result.pastes == 1)
        #expect(result.sends == 1)
    }

    @Test(arguments: [MessagesAXRelationshipCount.unsupported, .noValue, .available(1)])
    func attachmentRequiresKnownEmptyRelationship(count: MessagesAXRelationshipCount) throws {
        let result = try simulateNativeAttachmentSend { driver in
            driver.mainTranscript.staticChildren = []
            driver.replyTranscript.staticLinked = [driver.mainTranscript]
            driver.replyBody.staticLinked = []
            driver.replyBody.linkedCountOverride = count
        }
        #expect(result.outcome == .refused("reply-attachment-ownership-after-paste-body-main-link-missing"))
        #expect(result.pastes == 1)
        #expect(result.sends == 0)
        #expect(result.clipboard.restoredSnapshots.map(\.items) == [result.clipboard.original.items])
    }

    @Test(arguments: ["body-parent", "reply-parent", "cycle", "depth", "foreign-parent", "foreign-window", "duplicate-child"], [false, true])
    func attachmentRefusesAncestryDrift(kind: String, beforeReturn: Bool) throws {
        let result = try simulateNativeAttachmentSend(mutateBeforeReturn: beforeReturn ? { driver in
            changeAttachmentAncestry(driver, kind: kind)
        } : nil) { driver in
            if !beforeReturn { changeAttachmentAncestry(driver, kind: kind) }
        }
        guard case .refused = result.outcome else { Issue.record("Changed ancestry must refuse"); return }
        #expect(result.pastes == 1)
        #expect(result.sends == 0)
        #expect(result.driver.replyTranscript.performed.isEmpty)
        #expect(result.driver.replyBody.bodyText == "\u{fffc}\n")
        #expect(result.clipboard.restoredSnapshots.map(\.items) == [result.clipboard.original.items])
    }

    @Test(arguments: ["cycle", "depth", "foreign-parent", "foreign-window", "duplicate-child"])
    func attachmentRejectsInvalidInitialAncestryBeforeClipboardMutation(kind: String) throws {
        let result = try simulateNativeAttachmentSend(configure: { driver, _ in
            driver.message.onAction = { _ in
                driver.replyVisible = true
                changeAttachmentAncestry(driver, kind: kind)
            }
        }) { _ in }
        guard case .refused = result.outcome else { Issue.record("Invalid initial ancestry must refuse"); return }
        #expect(result.pastes == 0)
        #expect(result.sends == 0)
        #expect(result.clipboard.current == result.clipboard.original)
        #expect(result.clipboard.restoredSnapshots.isEmpty)
    }

    @Test(arguments: ["process", "window", "focus", "modal", "text", "foreign-link", "extra-link", "ax-error"], [false, true])
    func attachmentRefusesObservedDrift(kind: String, beforeReturn: Bool) throws {
        let change: (FakeReplyDriver) -> Void = { driver in
            switch kind {
            case "process":
                driver.identity = MessagesAXProcessIdentity(pid: 456, bundleURL: driver.identity.bundleURL,
                                                            launchDate: driver.identity.launchDate)
            case "window": driver.root.dynamicChildren = { [FakeReplyNode(roleValue: "AXWindow")] }
            case "focus": driver.appFocusedOverride = driver.normalBody
            case "modal": driver.extraWindowChildren = [FakeReplyNode(roleValue: "AXSheet")]
            case "text": driver.replyBody.applyBodyText("replacement draft")
            case "foreign-link":
                let foreign = FakeReplyNode(roleValue: "AXGroup")
                foreign.parentNode = driver.window
                driver.replyBody.staticLinked = [foreign]
            case "extra-link": driver.replyBody.staticLinked = [driver.mainTranscript, driver.replyTranscript]
            default: driver.replyBody.onChildrenRead = { throw MessagesAXNavigationError.unknownAXValue }
            }
        }
        let result = try simulateNativeAttachmentSend(mutateBeforeReturn: beforeReturn ? change : nil) { driver in
            if !beforeReturn { change(driver) }
        }
        guard case .refused = result.outcome else { Issue.record("Changed ownership must refuse"); return }
        #expect(result.pastes == 1)
        #expect(result.sends == 0)
        #expect(result.driver.replyTranscript.performed.isEmpty)
        #expect(result.driver.replyBody.bodyText == (kind == "text" ? "replacement draft" : "\u{fffc}\n"))
    }

    @Test func attachmentFinalFocusReadFollowsAllGraphTraversal() throws {
        var finalFocusRead = false
        let result = try simulateNativeAttachmentSend(configure: { driver, clipboard in
            clipboard.onRestore = {
                driver.onAppFocusRead = {
                    finalFocusRead = true
                    driver.window.onChildrenRead = {
                        Issue.record("Graph traversal after the final focus read")
                        throw MessagesAXNavigationError.unknownAXValue
                    }
                }
            }
        }, mutateAfterReturn: { driver in
            driver.window.onChildrenRead = nil
            driver.onAppFocusRead = nil
        }) { _ in }
        #expect(result.outcome == .ack(MessagesReplySendACKDetail.alreadyRestoredVerified))
        #expect(finalFocusRead)
        #expect(result.sends == 1)
    }

    @Test(arguments: ["missing-target", "missing-action", "moved-target"])
    func sendAttachmentAcceptsLinkedOnlyMainWithoutHistoricalTargetProof(kind: String) throws {
        let result = try simulateNativeAttachmentSend { driver in
            driver.mainTranscript.parentNode = driver.window
            driver.replyBody.staticLinked = [driver.mainTranscript]
            if kind == "missing-action" { driver.message.actionNames = [] }
            else {
                driver.mainTranscript.staticChildren = []
                if kind == "moved-target" { driver.replyTranscript.staticChildren = [driver.message] }
            }
        }
        #expect(result.outcome == .ack(MessagesReplySendACKDetail.alreadyRestoredVerified))
        #expect(result.pastes == 1)
        #expect(result.sends == 1)
        #expect(result.driver.replyTranscript.performed.isEmpty)
        #expect(result.driver.replyBody.bodyText == "\u{fffc}\n")
        #expect(result.clipboard.restoredSnapshots.map(\.items) == [result.clipboard.original.items])
    }

    @Test(arguments: ["replacement-main", "linked-third", "linked-reply", "contradictory-child-scan"])
    func sendAttachmentRefusesUnprovenLinkedOnlyTopology(kind: String) throws {
        let result = try simulateNativeAttachmentSend { driver in
            driver.mainTranscript.parentNode = driver.window
            driver.mainTranscript.staticChildren = []
            driver.replyBody.staticLinked = [driver.mainTranscript]
            switch kind {
            case "replacement-main":
                let replacement = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView", descriptionValue: "Messages")
                replacement.parentNode = driver.window
                driver.replyBody.staticLinked = [replacement]
            case "linked-third":
                let third = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView")
                third.parentNode = driver.window
                driver.mainTranscript.staticLinked = [third]
            case "linked-reply":
                driver.replyTranscript.parentNode = driver.window
                driver.replyWindowChildrenOverride = { [driver.replyBody] }
                driver.window.staticLinked = [driver.replyTranscript]
            default:
                // The first two scans discover the composer and body. Change the
                // child tree during the following full-graph ownership scan.
                var mainReads = 0
                driver.mainTranscript.onChildrenRead = {
                    mainReads += 1
                    if mainReads == 3 {
                        driver.extraWindowChildren = [FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView")]
                    }
                }
            }
        }
        let reason: String
        switch kind {
        case "linked-third": reason = "transcript-count"
        case "linked-reply": reason = "other"
        case "contradictory-child-scan": reason = "child-transcript-drift"
        default: reason = "main-transcript"
        }
        #expect(result.outcome == .refused("reply-attachment-ownership-after-paste-\(reason)"))
        #expect(result.sends == 0)
        #expect(result.driver.replyTranscript.performed.isEmpty)
        #expect(result.driver.replyBody.bodyText == "\u{fffc}\n")
    }

    @Test(arguments: ["reply", "body"], [false, true])
    func sendAttachmentRefusesCapturedIdentityReplacement(kind: String, beforeReturn: Bool) throws {
        let result = try simulateNativeAttachmentSend { driver in
            driver.mainTranscript.parentNode = driver.window
            driver.mainTranscript.staticChildren = []
            driver.replyBody.staticLinked = [driver.mainTranscript]
            let replace = {
                if kind == "reply" {
                    driver.replyTranscriptOverride = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView",
                                                                   descriptionValue: "Reply transcript", actionNames: ["AXCancel"])
                } else {
                    let body = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField",
                                             enabledValue: true, focusedValue: true, settableValue: true)
                    body.bodyEvidence = driver.replyBody.bodyEvidence
                    body.bodyText = driver.replyBody.bodyText
                    body.staticLinked = [driver.mainTranscript]
                    driver.replyBodyOverride = body
                }
            }
            if beforeReturn { driver.onAppFocusRead = replace }
            else { replace() }
        }
        let phase = beforeReturn ? "before-return" : "after-paste"
        #expect(result.outcome == .refused("reply-attachment-ownership-\(phase)-other"))
        #expect(result.sends == 0)
        #expect(result.driver.replyTranscript.performed.isEmpty)
        #expect(result.driver.replyTranscriptOverride?.performed.isEmpty ?? true)
        #expect(result.driver.replyBody.bodyText == "\u{fffc}\n")
    }

    @Test(arguments: ["retained-main", "linked-third"])
    func sendAttachmentRechecksTopologyBeforeReturn(kind: String) throws {
        let result = try simulateNativeAttachmentSend { driver in
            driver.mainTranscript.parentNode = driver.window
            driver.mainTranscript.staticChildren = []
            driver.replyBody.staticLinked = [driver.mainTranscript]
            driver.onAppFocusRead = {
                switch kind {
                case "retained-main": driver.extraWindowChildren = [driver.mainTranscript]
                default:
                    let third = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView")
                    third.parentNode = driver.window
                    driver.mainTranscript.staticLinked = [third]
                }
            }
        }
        let reason = kind == "retained-main" ? "main-target-missing" : "transcript-count"
        #expect(result.outcome == .refused("reply-attachment-ownership-before-return-\(reason)"))
        #expect(result.sends == 0)
        #expect(result.driver.replyTranscript.performed.isEmpty)
        #expect(result.driver.replyBody.bodyText == "\u{fffc}\n")
    }

    @Test func sendAttachmentClosesLinkedOnlyMainRetainedEmptyReply() throws {
        let result = try simulateNativeAttachmentSend(retainEmptyAfterSend: true) { driver in
            driver.mainTranscript.parentNode = driver.window
            driver.mainTranscript.staticChildren = []
            driver.replyBody.staticLinked = [driver.mainTranscript]
        }
        #expect(result.outcome == .ack(MessagesReplySendACKDetail.retainedEmptyCancelledVerified))
        #expect(result.sends == 1)
        #expect(result.driver.replyTranscript.performed == ["AXCancel"])
        #expect(!result.driver.replyVisible)
    }

    @Test(arguments: ["nonempty", "replaced-reply", "replaced-body"])
    func sendAttachmentProtectsLinkedOnlyComposerAfterReturn(kind: String) throws {
        let result = try simulateNativeAttachmentSend(retainEmptyAfterSend: true, mutateAfterReturn: { driver in
            switch kind {
            case "nonempty": driver.replyBody.applyBodyText("apple-cli-test changed")
            case "replaced-reply":
                driver.replyTranscriptOverride = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView",
                                                               descriptionValue: "Reply transcript", actionNames: ["AXCancel"])
            default:
                let body = FakeReplyNode(roleValue: "AXTextField", identifierValue: "messageBodyField",
                                         enabledValue: true, focusedValue: true, settableValue: true)
                body.bodyEvidence = driver.replyBody.bodyEvidence
                body.staticLinked = [driver.mainTranscript]
                driver.replyBodyOverride = body
            }
        }) { driver in
            driver.mainTranscript.parentNode = driver.window
            driver.mainTranscript.staticChildren = []
            driver.replyBody.staticLinked = [driver.mainTranscript]
        }
        let reason = kind == "nonempty" ? "reply-composer-possible-draft-remains" : "reply-composer-cleanup-failed"
        #expect(result.outcome == .refused(reason))
        #expect(result.sends == 1)
        #expect(result.driver.replyTranscript.performed.isEmpty)
        #expect(result.driver.replyTranscriptOverride?.performed.isEmpty ?? true)
        #expect(result.driver.replyVisible)
        if kind == "nonempty" { #expect(result.driver.replyBody.bodyText == "apple-cli-test changed") }
    }

    @Test func attachmentOwnershipDiagnosticDistinguishesFinalValidation() throws {
        let driver = FakeReplyDriver()
        let (_, attachment) = try attachmentDraftPayload()
        let clipboard = FakeMessagesClipboard()
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var sends = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            sendReturnKey: { _, _ in sends += 1 },
                                                            clipboardFactory: { clipboard },
                                                            pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                            sendPasteKey: { _, _, _ in
                                                                driver.extraWindowChildren = [driver.mainTranscript]
                                                                driver.replyBody.staticLinked = [driver.mainTranscript]
                                                                driver.replyBody.applyBodyText("\u{fffc}\n")
                                                                driver.onAppFocusRead = { driver.message.actionNames = [] }
                                                            })
            .send(sendRequest(attachmentDraft: attachment), deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-ownership-before-return-main-target-action-missing"))
        #expect(sends == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test(arguments: ["main", "reply", "foreign-process", "foreign-window", "unknown-transcript", "two-attachments"])
    func sendAttachmentValidatesExposedBodyReferences(kind: String) throws {
        let result = try simulateNativeAttachmentSend { driver in
            driver.extraWindowChildren = [driver.mainTranscript]
            switch kind {
            case "main": driver.replyBody.staticLinked = [driver.mainTranscript]
            case "reply": driver.replyBody.staticLinked = [driver.replyTranscript]
            case "two-attachments":
                driver.replyBody.staticChildren = [FakeReplyNode(roleValue: "AXImage"), FakeReplyNode(roleValue: "AXImage")]
            default:
                let link = FakeReplyNode(roleValue: "AXGroup", identifierValue: "TranscriptCollectionView")
                if kind == "foreign-window" {
                    let owner = FakeReplyNode(roleValue: "AXWindow")
                    driver.extraWindowChildren.append(owner)
                    link.parentNode = owner
                } else {
                    link.parentNode = driver.window
                }
                if kind == "foreign-process" { link.processIdentifierValue = 456 }
                driver.replyBody.staticLinked = [link]
            }
        }
        #expect(result.sends == (kind == "main" ? 1 : 0))
        if kind == "main" {
            #expect(result.outcome == .ack(MessagesReplySendACKDetail.alreadyRestoredVerified))
        }
    }

    @Test func sendAttachmentPreservesDraftWhenModalAppearsAfterPaste() throws {
        let result = try simulateNativeAttachmentSend { driver in
            driver.extraWindowChildren = [FakeReplyNode(roleValue: "AXSheet")]
        }
        #expect(result.outcome == .refused("reply-attachment-ownership-after-paste-other"))
        #expect(result.sends == 0)
        #expect(result.driver.replyTranscript.performed.isEmpty)
    }

    @Test(arguments: [false, true])
    func sendAttachmentPreservesNonemptyDraftOnFailure(beforePaste: Bool) throws {
        let driver = FakeReplyDriver()
        let (_, attachment) = try attachmentDraftPayload()
        let request = try sendRequest(attachmentDraft: attachment)
        let clipboard = FakeMessagesClipboard()
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        if beforePaste {
            clipboard.onPublish = { driver.replyBody.applyBodyText("\u{fffc}\n") }
        } else {
            clipboard.writeSucceeds = false
        }
        var pastes = 0
        var sends = 0
        _ = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                   sendReturnKey: { _, _ in sends += 1 },
                                                   clipboardFactory: { clipboard },
                                                   pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                   sendPasteKey: { _, _, _ in
                                                       pastes += 1
                                                       driver.replyBody.applyBodyText("\u{fffc}\n")
                                                   })
            .send(request, deadline: .millisecondsFromNow(5_000))
        #expect(pastes == (beforePaste ? 0 : 1))
        #expect(sends == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(driver.replyBody.bodyText == "\u{fffc}\n")
    }

    @Test func sendAttachmentRefusesLayoutDriftBeforePaste() throws {
        let driver = FakeReplyDriver()
        let (_, attachment) = try attachmentDraftPayload()
        let request = try sendRequest(attachmentDraft: attachment)
        let clipboard = FakeMessagesClipboard()
        let first = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        let second = MessagesPasteKeyEvidence(inputSourceID: "other", layoutSHA256: "sha256:" + String(repeating: "b", count: 64), keyboardType: 40, keyCode: 8)
        var pastes = 0
        var sends = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            sendReturnKey: { _, _ in sends += 1 },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([first, second]),
                                                            sendPasteKey: { _, _, _ in pastes += 1 })
            .send(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-layout-drift"))
        #expect(pastes == 0)
        #expect(sends == 0)
    }

    @Test func sendAttachmentRestoresClipboardWhenClearVerificationThrows() throws {
        let driver = FakeReplyDriver()
        let (_, attachment) = try attachmentDraftPayload()
        let request = try sendRequest(attachmentDraft: attachment)
        let clipboard = FakeMessagesClipboard()
        clipboard.throwOnReadAfterNextClear = true
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var pastes = 0
        var sends = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            sendReturnKey: { _, _ in sends += 1 },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([evidence]),
                                                            sendPasteKey: { _, _, _ in pastes += 1 })
            .send(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-clipboard-drift"))
        #expect(pastes == 0)
        #expect(sends == 0)
        #expect(clipboard.restoredSnapshots.map(\.items) == [clipboard.original.items])
    }

    @Test(arguments: ["\u{fffc}\nuser text", "\u{fffc}\u{fffc}\n"])
    func sendAttachmentPreservesDraftChangedDuringFinalFocusCheck(text: String) throws {
        let result = try simulateNativeAttachmentSend { driver in
            var focusReadsAfterPaste = 0
            driver.onAppFocusRead = {
                focusReadsAfterPaste += 1
                if focusReadsAfterPaste == 2 { driver.replyBody.applyBodyText(text) }
            }
        }
        #expect(result.outcome == .refused("reply-attachment-draft-unverified"))
        #expect(result.sends == 0)
        #expect(result.driver.replyTranscript.performed.isEmpty)
        #expect(result.driver.replyBody.bodyText == text)
    }

    @Test func sendAttachmentClosesRetainedEmptyReplyWithOriginalMainPresent() throws {
        let result = try simulateNativeAttachmentSend(retainEmptyAfterSend: true) { driver in
            driver.extraWindowChildren = [driver.mainTranscript]
            driver.replyTranscript.onAction = { [weak driver] name in
                guard name == "AXCancel", let driver else { throw MessagesReplyComposerAXError.replyComposerCleanupUnavailable }
                driver.replyVisible = false
                driver.extraWindowChildren = []
            }
        }
        #expect(result.outcome == .ack(MessagesReplySendACKDetail.retainedEmptyCancelledVerified))
        #expect(result.sends == 1)
        #expect(result.driver.replyTranscript.performed == ["AXCancel"])
    }

    private func simulateNativeAttachmentSend(retainEmptyAfterSend: Bool = false,
                                              configure: ((FakeReplyDriver, FakeMessagesClipboard) -> Void)? = nil,
                                              mutateBeforeReturn: ((FakeReplyDriver) -> Void)? = nil,
                                              readinessNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                                              readinessPause: ((FakeReplyDriver, UInt64) -> Void)? = nil,
                                              mutateAfterReturn: ((FakeReplyDriver) -> Void)? = nil,
                                              mutateAfterPaste: (FakeReplyDriver) -> Void) throws ->
        (outcome: MessagesReplyComposerAXOutcome, pastes: Int, sends: Int, driver: FakeReplyDriver, clipboard: FakeMessagesClipboard) {
        let driver = FakeReplyDriver()
        let (_, attachment) = try attachmentDraftPayload()
        let request = try sendRequest(attachmentDraft: attachment)
        let clipboard = FakeMessagesClipboard()
        clipboard.onRestore = { mutateBeforeReturn?(driver) }
        configure?(driver, clipboard)
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var pastes = 0
        var sends = 0
        let outcome = try withoutActuallyEscaping(mutateAfterPaste) { mutate in
            try MessagesReplyComposerAXAutomation(driver: driver, readinessNow: readinessNow,
                                                   readinessPause: { readinessPause?(driver, $0) },
                                                   sendReturnKey: { _, _ in
                                                       sends += 1
                                                       if retainEmptyAfterSend {
                                                           driver.replyBody.applyBodyText("")
                                                       } else {
                                                           driver.replyVisible = false
                                                           driver.extraWindowChildren = []
                                                       }
                                                       mutateAfterReturn?(driver)
                                                   },
                                                   clipboardFactory: { clipboard },
                                                   pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                   sendPasteKey: { _, _, _ in
                                                       pastes += 1
                                                       driver.replyBody.applyBodyText("\u{fffc}\n")
                                                       driver.mainTranscript.parentNode = driver.window
                                                       driver.replyBody.staticLinked = [driver.mainTranscript]
                                                       mutate(driver)
                                                   })
                .send(request, deadline: .millisecondsFromNow(5_000))
        }
        return (outcome, pastes, sends, driver, clipboard)
    }

    @Test func attachmentDraftInspectPastesOneCommandVAndCancelsExactOwnedDraft() throws {
        let driver = FakeReplyDriver()
        let (payload, attachment) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        let resolver = FakePasteKeyResolver([MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9),
                                             MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)])
        var pastePresses: [(pid_t, UInt16)] = []
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: resolver,
                                                            sendPasteKey: { pid, key, _ in
                                                                pastePresses.append((pid, key))
                                                                let node = FakeReplyNode(roleValue: "AXImage", identifierValue: "attachment")
                                                                node.stringAttributes["AXURL"] = URL(fileURLWithPath: attachment.copyPath).absoluteString
                                                                driver.replyBody.staticChildren = [node]
                                                                driver.replyBody.applyBodyText("\u{fffc}")
                                                            }).inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .ack(MessagesReplyComposerProbeDetail.attachmentDraftVerified))
        #expect(pastePresses.count == 1)
        #expect(pastePresses.first?.0 == driver.identity.pid)
        #expect(pastePresses.first?.1 == 9)
        #expect(driver.replyTranscript.performed == ["AXCancel"])
        #expect(clipboard.restoredSnapshots.map(\.items) == [clipboard.original.items])
    }

    @Test func attachmentDraftInspectRefusesWeakAttachmentIdentityWithoutCancel() throws {
        let driver = FakeReplyDriver()
        let (payload, _) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        let resolver = FakePasteKeyResolver([evidence, evidence])
        var pastePresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: resolver,
                                                            sendPasteKey: { _, _, _ in
                                                                pastePresses += 1
                                                                let node = FakeReplyNode(roleValue: "AXImage", identifierValue: "attachment")
                                                                node.stringAttributes["AXTitle"] = "apple-cli-test-source.txt"
                                                                driver.replyBody.staticChildren = [node]
                                                                driver.replyBody.applyBodyText("\u{fffc}")
                                                            }).inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-draft-unverified"))
        #expect(pastePresses == 1)
        #expect(driver.replyTranscript.performed.isEmpty)
        #expect(clipboard.restoredSnapshots.map(\.items) == [clipboard.original.items])
    }

    @Test func attachmentDraftInspectRefusesLayoutDriftBeforePaste() throws {
        let driver = FakeReplyDriver()
        let (payload, _) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        let first = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        let second = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "b", count: 64), keyboardType: 40, keyCode: 9)
        var pastePresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([first, second]),
                                                            sendPasteKey: { _, _, _ in pastePresses += 1 })
            .inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-layout-drift"))
        #expect(pastePresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func attachmentDraftInspectRefusesClipboardDriftBeforePaste() throws {
        let driver = FakeReplyDriver()
        let (payload, _) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        clipboard.mutateAfterPublish = true
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var pastePresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                            sendPasteKey: { _, _, _ in pastePresses += 1 })
            .inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-clipboard-drift"))
        #expect(pastePresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
    }


    @Test func attachmentDraftInspectRestoresOwnedEmptyClipboardWhenPublishFails() throws {
        let driver = FakeReplyDriver()
        let (payload, _) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        clipboard.publishSucceeds = false
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var pastePresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([evidence]),
                                                            sendPasteKey: { _, _, _ in pastePresses += 1 })
            .inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-clipboard-drift"))
        #expect(pastePresses == 0)
        #expect(clipboard.restoredSnapshots.map(\.items) == [clipboard.original.items])
    }


    @Test func attachmentDraftInspectRefusesLateClipboardDriftAfterUIProofWithZeroPaste() throws {
        let driver = FakeReplyDriver()
        let (payload, attachment) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var armed = false
        driver.replyBody.onBodyEvidenceRead = {
            guard !armed, clipboard.current.isExactFileURLPayload(URL(fileURLWithPath: attachment.copyPath)) else { return }
            armed = true
            clipboard.mutateOnNextRead = true
        }
        var pastePresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                            sendPasteKey: { _, _, _ in pastePresses += 1 })
            .inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-clipboard-drift"))
        #expect(pastePresses == 0)
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func attachmentDraftInspectRefusesNonfileURLEvenWhenPathMatches() throws {
        let driver = FakeReplyDriver()
        let (payload, attachment) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var pastePresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                            sendPasteKey: { _, _, _ in
                                                                pastePresses += 1
                                                                let node = FakeReplyNode(roleValue: "AXImage", identifierValue: "attachment")
                                                                node.stringAttributes["AXURL"] = "https://example.com\(attachment.copyPath)"
                                                                driver.replyBody.staticChildren = [node]
                                                                driver.replyBody.applyBodyText("\u{fffc}")
                                                            }).inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-draft-unverified"))
        #expect(pastePresses == 1)
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func attachmentDraftCopyValidationRejectsStatDriftAndCleanupPreservesUnexpectedDirectoryContent() throws {
        let (_, drifted) = try attachmentDraftPayload()
        chmod(drifted.copyPath, 0o644)
        #expect(throws: Error.self) {
            _ = try validateReplyAttachmentDraftCopy(drifted, deadline: .millisecondsFromNow(5_000))
        }
        let (_, attachment) = try attachmentDraftPayload()
        let extra = URL(fileURLWithPath: attachment.directoryPath, isDirectory: true).appendingPathComponent("unexpected.txt")
        FileManager.default.createFile(atPath: extra.path, contents: Data("unexpected".utf8))
        #expect(throws: Error.self) {
            _ = try removeReplyAttachmentDraftCopyIfOwned(attachment, deadline: .millisecondsFromNow(5_000))
        }
        #expect(FileManager.default.fileExists(atPath: extra.path))
    }

    @Test func attachmentDraftClipboardSnapshotRefusesUnstableOrMissingRepresentations() throws {
        let clipboard = FakeMessagesClipboard()
        clipboard.mutateOnNextRead = true
        #expect(throws: Error.self) {
            _ = try clipboard.snapshot(deadline: .millisecondsFromNow(5_000))
        }
        let failing = FakeMessagesClipboard()
        failing.throwOnRead = true
        #expect(throws: Error.self) {
            _ = try failing.snapshot(deadline: .millisecondsFromNow(5_000))
        }
    }

    @Test func parentObservedActionRequiresFinalCopyProofAndCleansOnlyAfterVerifiedAck() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        let (payload, attachment) = try attachmentDraftPayload()
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
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: attachment.copyPath))
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.attachmentDraftVerified)
        #expect(throws: Error.self) {
            _ = try action.verify(resolved, response, context)
        }
        #expect(FileManager.default.fileExists(atPath: attachment.copyPath))
    }


    @Test func attachmentProbePrivateClassifierOnlyCompletesExactObservedAttachmentState() throws {
        let (payload, _) = try attachmentDraftPayload()
        let prepared = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let id = UUID()
        let removed = MessagesReplyAttachmentProbeCleanupEvidence(disposition: "removed", copyAbsent: true, directoryAbsent: true)
        let success = MessagesReplyAttachmentProbePrivateEntrypoint.classify(
            observed: .observedState(operationID: id, verification: MessagesReplyComposerProbeDetail.attachmentDraftVerified),
            prepared: prepared, payloadData: payload, cleanup: removed)
        #expect(success.exitCode == 0)
        #expect(success.result.outcome == "completed")
        #expect(success.result.category == "ack")
        #expect(success.result.detail == MessagesReplyComposerProbeDetail.attachmentDraftVerified)
        #expect(success.result.phase == "replyAttachmentDraftInspect")
        #expect(success.result.workerCommand == "messages.reply.inspect")
        #expect(success.result.observedState == "observedState")
        #expect(success.result.operationID == id)
        let failures: [WorkerObservedOutcome?] = [
            nil,
            .alreadyInDesiredState("verified"),
            .observedState(operationID: UUID(), verification: MessagesReplyComposerProbeDetail.verified),
            .spawnOrSetupFailedBeforeRequest("setup"),
            .requestNotSent("not-sent"),
            .childRefusedOrFailed("refused"),
            .cancelled,
            .verificationFailed,
            .timedOut,
            .protocolViolation("bad")
        ]
        for failure in failures {
            let classified = MessagesReplyAttachmentProbePrivateEntrypoint.classify(observed: failure, prepared: prepared,
                                                                                    payloadData: payload, cleanup: removed)
            #expect(classified.exitCode != 0)
            #expect(classified.result.outcome == "refused")
        }
    }

    @Test func attachmentDraftInspectRestoresOwnedEmptyClipboardWhenClearVerificationThrows() throws {
        let driver = FakeReplyDriver()
        let (payload, _) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        clipboard.throwOnReadAfterNextClear = true
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var pastePresses = 0
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([evidence]),
                                                            sendPasteKey: { _, _, _ in pastePresses += 1 })
            .inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-clipboard-drift"))
        #expect(pastePresses == 0)
        #expect(clipboard.restoredSnapshots.map(\.items) == [clipboard.original.items])
    }

    @Test func attachmentDraftClipboardNilItemsRequireIndependentEmptyProof() throws {
        let clipboard = FakeMessagesClipboard()
        clipboard.returnNilItems = true
        #expect(throws: Error.self) {
            _ = try clipboard.snapshot(deadline: .millisecondsFromNow(5_000))
        }
        clipboard.emptyTypesWhenNilItems = true
        #expect(try clipboard.snapshot(deadline: .millisecondsFromNow(5_000)).items.isEmpty)
        let count = try clipboard.clearContentsReturningCount(deadline: .millisecondsFromNow(5_000))
        try clipboard.verifyEmpty(ownerCount: count, deadline: .millisecondsFromNow(5_000))
    }

    @Test func attachmentDraftInspectRestoresOwnedPayloadClipboardWhenPublishThrows() throws {
        let driver = FakeReplyDriver()
        let (payload, _) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        clipboard.publishThrows = true
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([evidence]),
                                                            sendPasteKey: { _, _, _ in })
            .inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-attachment-clipboard-drift"))
        #expect(clipboard.restoredSnapshots.map(\.items) == [clipboard.original.items])
    }

    @Test func attachmentDraftInspectAcceptsTypedFileURLAttribute() throws {
        let driver = FakeReplyDriver()
        let (payload, attachment) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                            sendPasteKey: { _, _, _ in
                                                                let node = FakeReplyNode(roleValue: "AXImage", identifierValue: "attachment")
                                                                node.fileURLAttributes["AXURL"] = URL(fileURLWithPath: attachment.copyPath)
                                                                driver.replyBody.staticChildren = [node]
                                                                driver.replyBody.applyBodyText("\u{fffc}")
                                                            }).inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .ack(MessagesReplyComposerProbeDetail.attachmentDraftVerified))
        #expect(driver.replyTranscript.performed == ["AXCancel"])
    }

    @Test func attachmentDraftInspectRefusesModalDriftDuringAttachmentCancelProof() throws {
        let driver = FakeReplyDriver()
        let (payload, attachment) = try attachmentDraftPayload()
        let request = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        let clipboard = FakeMessagesClipboard()
        let evidence = MessagesPasteKeyEvidence(inputSourceID: "source", layoutSHA256: "sha256:" + String(repeating: "a", count: 64), keyboardType: 40, keyCode: 9)
        var afterPaste = false
        driver.replyBody.onChildrenRead = {
            guard afterPaste else { return }
            driver.extraWindowChildren.append(FakeReplyNode(roleValue: "AXSheet", identifierValue: nil))
        }
        let outcome = try MessagesReplyComposerAXAutomation(driver: driver, readinessPause: { _ in },
                                                            clipboardFactory: { clipboard }, pasteKeyResolver: FakePasteKeyResolver([evidence, evidence]),
                                                            sendPasteKey: { _, _, _ in
                                                                afterPaste = true
                                                                let node = FakeReplyNode(roleValue: "AXImage", identifierValue: "attachment")
                                                                node.stringAttributes["AXURL"] = URL(fileURLWithPath: attachment.copyPath).absoluteString
                                                                driver.replyBody.staticChildren = [node]
                                                                driver.replyBody.applyBodyText("\u{fffc}")
                                                            }).inspect(request, deadline: .millisecondsFromNow(5_000))
        #expect(outcome == .refused("reply-composer-ownership-drift"))
        #expect(driver.replyTranscript.performed.isEmpty)
    }

    @Test func attachmentDraftEvidenceDecodeValidatesNestedStatAndPathBounds() throws {
        let (_, attachment) = try attachmentDraftPayload()
        let encoded = try JSONEncoder().encode(attachment)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["copy_size"] = 70_000
        let oversized = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(MessagesReplyAttachmentDraftEvidence.self, from: oversized)
        }
        var nested = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var copyStat = try #require(nested["copy_stat"] as? [String: Any])
        copyStat["mode"] = 0o644
        nested["copy_stat"] = copyStat
        let badStat = try JSONSerialization.data(withJSONObject: nested)
        #expect(throws: Error.self) {
            _ = try JSONDecoder().decode(MessagesReplyAttachmentDraftEvidence.self, from: badStat)
        }
    }


    @Test func attachmentDraftPayloadCleansOwnedCopyWhenPreparedPayloadExceedsBound() throws {
        let sourceDir = try scratch.directory()
        let source = sourceDir.appendingPathComponent("apple-cli-test-source.txt")
        FileManager.default.createFile(atPath: source.path, contents: Data("apple-cli-test attachment".utf8))
        chmod(source.path, 0o600)
        var failingRoot: URL?
        for width in 1...120 {
            let handles = (0..<32).map { "fixture\($0)" + String(repeating: "x", count: width) + "@example.com" }
            guard let candidate = try? request(participantHandles: handles),
                  (try? candidate.workerPayloadData()) != nil else { continue }
            let attemptRoot = try scratch.directory()
            do {
                let payload = try MessagesReplyComposerProbeParent.payloadDataForAttachmentDraft(base: candidate, rawFilePath: source.path,
                                                                                                 scratchRoot: attemptRoot.path,
                                                                                                 repoRoot: FileManager.default.currentDirectoryPath,
                                                                                                 deadline: .millisecondsFromNow(5_000))
                let decoded = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
                if let attachment = decoded.attachmentDraft {
                    _ = try removeReplyAttachmentDraftCopyIfOwned(attachment, deadline: .millisecondsFromNow(5_000))
                }
            } catch {
                failingRoot = attemptRoot
                break
            }
        }
        let root = try #require(failingRoot)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func attachmentDraftPreparationHonorsExpiredDeadlineBeforeCopy() throws {
        let sourceDir = try scratch.directory()
        let source = sourceDir.appendingPathComponent("apple-cli-test-source.txt")
        FileManager.default.createFile(atPath: source.path, contents: Data("apple-cli-test attachment".utf8))
        chmod(source.path, 0o600)
        let copyRoot = try scratch.directory()
        #expect(throws: Error.self) {
            _ = try MessagesReplyComposerProbeParent.payloadDataForAttachmentDraft(base: request(), rawFilePath: source.path,
                                                                                  scratchRoot: copyRoot.path,
                                                                                  repoRoot: FileManager.default.currentDirectoryPath,
                                                                                  deadline: .millisecondsFromNow(0))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: copyRoot.path).isEmpty)
    }

    @Test func attachmentDraftLiveCFURLConversionPreservesFileIdentity() throws {
        let url = URL(fileURLWithPath: "/tmp/apple-cli-test file.bin")
        #expect(try LiveAXElement.checkedFileURL(url as CFURL) == url)
        #expect(try LiveAXElement.checkedFileURL(url.absoluteString as CFString) == url)
        for raw in [URL(string: "https://example.com/file")! as CFURL,
                               "/tmp/apple-cli-test file.bin" as CFString,
                               NSNumber(value: 7),
                               ("file:///" + String(repeating: "a", count: 2048)) as CFString] as [CFTypeRef] {
            #expect(throws: Error.self) { _ = try LiveAXElement.checkedFileURL(raw) }
        }
    }

    @Test func attachmentDraftClipboardProviderBoundsAndMissingDataRefuse() throws {
        let type = NSPasteboard.PasteboardType.string
        func read(_ types: [[NSPasteboard.PasteboardType]]?, declared: [NSPasteboard.PasteboardType]? = nil,
                  bytes: Data? = Data([1])) throws -> [[MessagesClipboardRepresentation]] {
            try LiveMessagesClipboardBackend.readRepresentations(itemTypes: types, declaredTypes: declared,
                                                                   deadline: .millisecondsFromNow(5_000)) { _, _ in bytes }
        }
        #expect(try read(nil, declared: []).isEmpty)
        for declared in [nil, [type]] as [[NSPasteboard.PasteboardType]?] {
            #expect(throws: Error.self) { _ = try read(nil, declared: declared) }
        }
        #expect(throws: Error.self) { _ = try read([[type]], bytes: nil) }
        #expect(throws: Error.self) { _ = try read(Array(repeating: [type], count: 9)) }
        #expect(throws: Error.self) { _ = try read([Array(repeating: type, count: 33)]) }
        #expect(throws: Error.self) { _ = try read([[type]], bytes: Data(repeating: 0, count: 65_537)) }
        #expect(throws: Error.self) { _ = try read(Array(repeating: [type], count: 5), bytes: Data(repeating: 0, count: 65_536)) }
        #expect(try read(Array(repeating: [type], count: 4), bytes: Data(repeating: 0, count: 65_536)).count == 4)
        #expect(throws: Error.self) {
            _ = try LiveMessagesClipboardBackend.readRepresentations(itemTypes: [[type]], declaredTypes: nil,
                                                                      deadline: .millisecondsFromNow(5_000)) { _, _ in
                throw MessagesReplyComposerAXError.invalidPayload
            }
        }
    }

    @Test func attachmentDraftRestorationAcceptsOwnedNonemptyClipboardWithoutWriteCountAdvance() throws {
        let clipboard = FakeMessagesClipboard()
        try clipboard.restore(clipboard.original, deadline: .millisecondsFromNow(5_000))
        #expect(clipboard.current.items == clipboard.original.items)
        #expect(clipboard.current.changeCount == clipboard.original.changeCount + 1)
        #expect(clipboard.restoredSnapshots.count == 1)
    }

    @Test func attachmentDraftPublishRejectsExternalClipboardCountDrift() throws {
        let clipboard = FakeMessagesClipboard()
        let cleared = try clipboard.clearAndVerifyEmpty(deadline: .millisecondsFromNow(5_000))
        clipboard.mutateAfterPublish = true
        #expect(throws: Error.self) {
            _ = try clipboard.publishAndVerifyFileURL(URL(fileURLWithPath: "/tmp/apple-cli-test.bin"), ownerCount: cleared, deadline: .millisecondsFromNow(5_000))
        }
    }

    @Test func attachmentDraftRestorationRefusesPartialWriteCountAndContentFailures() throws {
        for failure in 0..<3 {
            let clipboard = FakeMessagesClipboard()
            if failure == 0 { clipboard.writeSucceeds = false }
            if failure == 1 { clipboard.mutateAfterWrite = true }
            if failure == 2 { clipboard.externalChangeCountAfterWrite = true }
            #expect(throws: Error.self) { try clipboard.restore(clipboard.original, deadline: .millisecondsFromNow(5_000)) }
            #expect(clipboard.restoredSnapshots.count == 1)
            #expect(clipboard.current.changeCount > clipboard.original.changeCount)
        }
    }

    @Test func attachmentDraftExpiryBeforeClipboardOperationsDoesNotWrite() throws {
        let clipboard = FakeMessagesClipboard()
        let expired = WorkerDeadline.millisecondsFromNow(0)
        #expect(throws: Error.self) { _ = try clipboard.snapshot(deadline: expired) }
        #expect(throws: Error.self) { _ = try clipboard.clearContentsReturningCount(deadline: expired) }
        #expect(throws: Error.self) { _ = try clipboard.publishAndVerifyFileURL(URL(fileURLWithPath: "/tmp/apple-cli-test.bin"), ownerCount: 1, deadline: expired) }
        #expect(throws: Error.self) { try clipboard.restore(clipboard.original, deadline: expired) }
        #expect(clipboard.current == clipboard.original)
        #expect(clipboard.restoredSnapshots.isEmpty)
    }

    @Test func attachmentDraftCleanupDistinguishesNoHandoffFromUncertainOutcomes() throws {
        let cases: [(Bool, WorkerObservedOutcome?, Bool)] = [
            (false, nil, true), (true, .requestNotSent("refused"), true),
            (true, .spawnOrSetupFailedBeforeRequest("spawn"), true),
            (true, nil, false), (true, .cancelled, false), (true, .timedOut, false),
            (true, .verificationFailed, false), (true, .childRefusedOrFailed("child"), false),
            (true, .protocolViolation("binding"), false)
        ]
        for (started, outcome, shouldRemove) in cases {
            let (_, attachment) = try attachmentDraftPayload()
            try MessagesReplyAttachmentProbePrivateEntrypoint.cleanupBeforeHandoffIfProven(attachment, launchStarted: started,
                                                                                           outcome: outcome, deadline: .millisecondsFromNow(5_000))
            #expect(FileManager.default.fileExists(atPath: attachment.copyPath) == !shouldRemove)
            #expect(FileManager.default.fileExists(atPath: attachment.directoryPath) == !shouldRemove)
        }
    }

    @Test func attachmentDraftDecodeRefusesWrongTypesPathsHashesAndTimestamps() throws {
        let (_, attachment) = try attachmentDraftPayload()
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any])
        for (key, value) in [("copy_size", "1"), ("copy_size", true),
                                           ("copy_path", String(repeating: "x", count: 1025)),
                                           ("copy_path", "relative.bin"),
                                           ("copy_sha256", "sha256:" + String(repeating: "z", count: 64)),
                                           ("directory_stat", NSNull())] as [(String, Any)] {
            var malformed = original
            malformed[key] = value
            let data = try JSONSerialization.data(withJSONObject: malformed)
            #expect(throws: Error.self) { _ = try JSONDecoder().decode(MessagesReplyAttachmentDraftEvidence.self, from: data) }
        }
        var malformed = original
        var copyStat = try #require(malformed["copy_stat"] as? [String: Any])
        copyStat["mtime_nsec"] = 1_000_000_000
        malformed["copy_stat"] = copyStat
        let data = try JSONSerialization.data(withJSONObject: malformed)
        #expect(throws: Error.self) { _ = try JSONDecoder().decode(MessagesReplyAttachmentDraftEvidence.self, from: data) }
    }

    private func attachmentDraftPayload() throws -> (Data, MessagesReplyAttachmentDraftEvidence) {
        let sourceDir = try scratch.directory()
        let source = sourceDir.appendingPathComponent("apple-cli-test-source.txt")
        FileManager.default.createFile(atPath: source.path, contents: Data("apple-cli-test attachment".utf8))
        chmod(source.path, 0o600)
        let payload = try MessagesReplyComposerProbeParent.payloadDataForAttachmentDraft(base: request(), rawFilePath: source.path,
                                                                                        scratchRoot: try scratch.directory().path,
                                                                                        repoRoot: FileManager.default.currentDirectoryPath,
                                                                                        deadline: .millisecondsFromNow(5_000))
        let decoded = try JSONDecoder().decode(MessagesReplyComposerProbeRequest.self, from: payload)
        return (payload, try #require(decoded.attachmentDraft))
    }



    @Test func parentObservedActionVerifiesAttachmentDraftDetailAndFreshUI() throws {
        let fx = try dbFixture()
        let dbPath = fx.path
        let homePath = fx.homePath
        let driver = FakeReplyDriver()
        let (payload, _) = try attachmentDraftPayload()
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
        let wrong = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.verified)
        #expect(try action.verify(resolved, wrong, context) == nil)
        let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: MessagesReplyComposerProbeDetail.attachmentDraftVerified)
        #expect(try action.verify(resolved, response, context) == MessagesReplyComposerProbeDetail.attachmentDraftVerified)
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

private let sendRequestText = "apple-cli-test reply"

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

private func changeAttachmentAncestry(_ driver: FakeReplyDriver, kind: String) {
    let target = kind == "reply-parent" ? driver.replyTranscript : driver.replyBody
    if kind == "duplicate-child" {
        driver.replyWindowChildrenOverride = { [driver.replyTranscript, driver.replyBody, driver.replyBody] }
        return
    }
    let container = FakeReplyNode(roleValue: "AXGroup", staticChildren: [target])
    container.parentNode = driver.window
    target.windowOverride = driver.window
    if kind == "foreign-window" { target.windowOverride = FakeReplyNode(roleValue: "AXWindow") }
    if kind == "foreign-parent" { container.processIdentifierValue = 456 }
    if kind == "cycle" {
        target.parentOverride = { target }
        target.staticChildren = [target]
        return
    }
    var outer = container
    if kind == "depth" {
        for _ in 0..<16 {
            let parent = FakeReplyNode(roleValue: "AXGroup", staticChildren: [outer])
            outer.parentNode = parent
            outer = parent
        }
    }
    let rootContainer = outer
    rootContainer.parentNode = driver.window
    driver.replyWindowChildrenOverride = {
        kind == "reply-parent" ? [rootContainer, driver.replyBody] : [driver.replyTranscript, rootContainer]
    }
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
    var focusedOverride: FakeReplyNode?
    var appFocusedOverride: FakeReplyNode?
    var appFocusAvailable = true
    var appFocusError: Error?
    var onAppFocusRead: (() -> Void)?
    var frontmostResults: [Bool] = []
    var frontmostError: Error?
    var focusedElementError: Error?
    var identity = MessagesAXProcessIdentity(pid: 123, bundleURL: URL(fileURLWithPath: "/System/Applications/Messages.app"), launchDate: Date(timeIntervalSince1970: 1))
    var canonicalRootOverride: FakeReplyNode?

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
    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool {
        if let frontmostError { throw frontmostError }
        if !frontmostResults.isEmpty { return frontmostResults.removeFirst() }
        return process.identity == identity
    }
    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        if let focusedElementError { throw focusedElementError }
        return focusedOverride ?? (replyVisible ? replyBody : normalBody)
    }
    func focusedElement(in process: MessagesAXProcess, deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        if let appFocusError { throw appFocusError }
        onAppFocusRead?()
        guard appFocusAvailable else { return nil }
        return appFocusedOverride ?? (replyVisible ? replyBody : normalBody)
    }
    func replyActionTitles(deadline: WorkerDeadline) throws -> [String] { ["Reply"] }
    func normalComposePlaceholders(deadline: WorkerDeadline) throws -> [String] { ["iMessage", "Text Message"] }
    func replyTranscriptDescription(deadline: WorkerDeadline) throws -> String? { "Reply transcript" }
    private var process: MessagesAXProcess { MessagesAXProcess(identity: identity, root: canonicalRootOverride ?? root) }
}

private final class FakeReplyNode: MessagesAXElement {
    let roleValue: String
    var identifierValue: String?
    var subroleValue: String?
    var titleValue: String?
    var mainValue: Bool?
    var windowUnavailable = false
    var windowOverride: FakeReplyNode?
    var parentOverride: (() -> FakeReplyNode?)?
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
    var bodyText: String = ""
    var onChildrenRead: (() throws -> Void)?
    var staticLinked: [FakeReplyNode] = []
    var onLinkedElementsRead: (() -> Void)?
    var linkedCountOverride: MessagesAXRelationshipCount?
    var onActionsRead: (() -> Void)?
    var onBodyEvidenceRead: (() -> Void)?
    var onControlRead: (() -> Void)?
    var onAction: ((String) throws -> Void)?
    var onSetValue: ((String) throws -> Void)?
    weak var parentNode: FakeReplyNode?
    var processIdentifierValue: Int32? = 123

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
    func axTitle(deadline: WorkerDeadline) throws -> String? { titleValue }
    var stringAttributes: [String: String] = [:]
    var fileURLAttributes: [String: URL] = [:]
    func stringAttribute(named name: String, deadline: WorkerDeadline) throws -> String? { stringAttributes[name] }
    func fileURLAttribute(named name: String, deadline: WorkerDeadline) throws -> URL? {
        if let url = fileURLAttributes[name] { return url.standardizedFileURL }
        guard let value = stringAttributes[name], !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value).standardizedFileURL }
        guard let url = URL(string: value), url.isFileURL else { throw MessagesAXNavigationError.unknownAXValue }
        return url.standardizedFileURL
    }
    func subrole(deadline: WorkerDeadline) throws -> String? { subroleValue }
    func mainWindow(deadline: WorkerDeadline) throws -> Bool? { mainValue }
    func enabled(deadline: WorkerDeadline) throws -> Bool? {
        onControlRead?()
        return enabledValue
    }
    func selected(deadline: WorkerDeadline) throws -> Bool? {
        if !selectedValues.isEmpty { return selectedValues.removeFirst() }
        return selectedValue
    }
    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { windowUnavailable ? nil : (windowOverride ?? rootWindow()) }
    func directWindows(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] { try children(limit: limit, deadline: deadline) }
    func parent(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { parentOverride?() ?? parentNode }
    func processIdentifier(deadline: WorkerDeadline) throws -> Int32? { processIdentifierValue }
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
    func relationshipCount(_ attribute: MessagesAXRelationshipAttribute, limit: Int,
                           deadline: WorkerDeadline) throws -> MessagesAXRelationshipCount {
        switch attribute {
        case .children: return .available(try children(limit: limit, deadline: deadline).count)
        case .linkedElements: return try linkedCountOverride ?? .available(linkedElements(limit: limit, deadline: deadline).count)
        }
    }
    func childrenInNavigationOrder(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]? { nil }
    func linkedElements(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        onLinkedElementsRead?()
        guard staticLinked.count <= limit else { throw MessagesAXNavigationError.traversalLimit }
        return staticLinked
    }
    func setValue(_ value: String, deadline: WorkerDeadline) throws {
        try onSetValue?(value)
        applyBodyText(value)
    }
    func applyBodyText(_ value: String) {
        bodyText = value
        bodyEvidence = .init(valueKind: value.isEmpty ? .noValue : .string(value.utf16.count),
                             characterCount: value.utf16.count, placeholder: bodyEvidence.placeholder)
    }
    func focused(deadline: WorkerDeadline) throws -> Bool? {
        onControlRead?()
        return focusedValue
    }
    func bodyValueEvidence(deadline: WorkerDeadline) throws -> MessagesAXBodyValueEvidence {
        let evidence = bodyEvidenceSequence.isEmpty ? bodyEvidence : bodyEvidenceSequence.removeFirst()
        onBodyEvidenceRead?()
        return evidence
    }
    func bodyTextSnapshot(deadline: WorkerDeadline) throws -> MessagesAXBodyTextSnapshot {
        try MessagesAXBodyTextSnapshot(text: bodyText, characterCount: bodyText.utf16.count)
    }
    func performAction(named name: String, deadline: WorkerDeadline) throws {
        performed.append(name)
        try onAction?(name)
    }

    private func rootWindow() -> FakeReplyNode? {
        var node: FakeReplyNode? = self
        var visited: Set<ObjectIdentifier> = []
        while let current = node {
            guard visited.insert(ObjectIdentifier(current)).inserted else { return nil }
            if current.roleValue == "AXWindow" { return current }
            node = current.parentNode
        }
        return nil
    }
}

private final class FakeMessagesClipboard: MessagesClipboarding, MessagesClipboardBackend {
    let original = MessagesClipboardSnapshot(changeCount: 1, items: [[MessagesClipboardRepresentation(type: "public.utf8-plain-text", data: Data("original".utf8))]])
    var current: MessagesClipboardSnapshot
    var restoredSnapshots: [MessagesClipboardSnapshot] = []
    var mutateAfterPublish = false
    var publishSucceeds = true
    var publishThrows = false
    var mutateOnNextRead = false
    var throwOnRead = false
    var throwOnReadAfterNextClear = false
    private var throwOnReadAfterClearIsArmed = false
    var returnNilItems = false
    var emptyTypesWhenNilItems = false
    var writeSucceeds = true
    var mutateAfterWrite = false
    var externalChangeCountAfterWrite = false
    var readCount = 0
    var onPublish: (() -> Void)?
    var onRestore: (() -> Void)?

    init() { current = original }

    var backend: any MessagesClipboardBackend { self }
    var changeCount: Int { current.changeCount }

    func readItems(deadline: WorkerDeadline) throws -> [[MessagesClipboardRepresentation]] {
        if throwOnRead { throw MessagesReplyComposerAXError.invalidPayload }
        if returnNilItems {
            guard emptyTypesWhenNilItems else { throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift }
            readCount += 1
            return []
        }
        readCount += 1
        if throwOnReadAfterClearIsArmed {
            throwOnReadAfterClearIsArmed = false
            throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift
        }
        if mutateOnNextRead {
            mutateOnNextRead = false
            current = MessagesClipboardSnapshot(changeCount: current.changeCount + 1, items: current.items)
        }
        return current.items
    }

    func clearContents(deadline: WorkerDeadline) throws -> Int {
        current = MessagesClipboardSnapshot(changeCount: current.changeCount + 1, items: [])
        if throwOnReadAfterNextClear {
            throwOnReadAfterNextClear = false
            throwOnReadAfterClearIsArmed = true
        }
        return current.changeCount
    }

    func publishFileURLData(_ data: Data, deadline: WorkerDeadline) throws -> Bool {
        onPublish?()
        let count = current.changeCount + (mutateAfterPublish ? 1 : 0)
        current = MessagesClipboardSnapshot(changeCount: count, items: [[MessagesClipboardRepresentation(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: data)]])
        if publishThrows { throw MessagesReplyComposerAXError.replyAttachmentClipboardDrift }
        return publishSucceeds
    }

    func writeItems(_ items: [[MessagesClipboardRepresentation]], deadline: WorkerDeadline) throws -> Bool {
        restoredSnapshots.append(MessagesClipboardSnapshot(changeCount: current.changeCount, items: items))
        let restored = mutateAfterWrite ? [[MessagesClipboardRepresentation(type: "public.utf8-plain-text", data: Data("drift".utf8))]] : items
        current = MessagesClipboardSnapshot(changeCount: current.changeCount + (externalChangeCountAfterWrite ? 1 : 0), items: restored)
        onRestore?()
        return writeSucceeds
    }
}


private final class FakePasteKeyResolver: MessagesPasteKeyResolving, @unchecked Sendable {
    private var values: [MessagesPasteKeyEvidence]

    init(_ values: [MessagesPasteKeyEvidence]) { self.values = values }

    func resolvePasteKey(deadline: WorkerDeadline) throws -> MessagesPasteKeyEvidence {
        guard !values.isEmpty else { throw MessagesReplyComposerAXError.replyComposerEvidenceUnavailable }
        return values.removeFirst()
    }
}
