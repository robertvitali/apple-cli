@testable import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentAXPressTests {
    @Test(arguments: ["navigation", "actions", "press", "revalidation"])
    func diagnosticPreservesFailureAndPressCount(_ stage: String) throws {
        let fx = AttachmentPressFixture()
        let diagnostic = MessagesAttachmentDiagnostic()
        let secret = "synthetic-private-path-and-message"
        let sentinel = NSError(domain: secret, code: 9)
        if stage == "navigation" { fx.onOpen = { throw sentinel } }
        if stage == "actions" { fx.message.pressActions = [] }
        if stage == "press" { fx.message.onPerform = { throw sentinel } }
        var caught = false
        do {
            try MessagesAttachmentAXPress(driver: fx, isTargetEligible: fx.eligible).perform(
                messageGUID: "synthetic-message", nativePartIndex: 0, nativePartGUID: nil,
                deadline: .millisecondsFromNow(5000), diagnostic: diagnostic, validateTarget: {
                    if stage == "revalidation" { throw sentinel }
                    return .pending
                })
        } catch {
            caught = true
            if stage == "actions" {
                #expect(error as? MessagesAttachmentAXPress.Failure == .pressUnavailable)
            } else { #expect((error as NSError) === sentinel) }
            #expect(diagnostic.stage.rawValue == stage)
            #expect(WorkerOperationResult.failed(diagnostic.detail(error)).detail == diagnostic.detail(error))
            #expect(!diagnostic.detail(error).contains(secret))
        }
        #expect(caught)
        #expect(fx.message.performed == (stage == "press" ? ["AXPress"] : []))
    }

    @Test func retainedTargetPressedOnceAfterValidation() throws {
        let fx = AttachmentPressFixture()
        var validations = 0
        try MessagesAttachmentAXPress(driver: fx, isTargetEligible: fx.eligible).perform(
            messageGUID: "synthetic-message", nativePartIndex: 0, nativePartGUID: nil,
            deadline: .millisecondsFromNow(5000), validateTarget: { validations += 1; return .pending })
        #expect(validations == 3)
        #expect(fx.message.performed == ["AXPress"])
    }
    @Test(arguments: ["row-removed", "link-only-row", "transcript-removed", "wrong-parent", "duplicate-child"])
    func targetMustRemainInTranscriptThroughFinalActionRead(_ drift: String) throws {
        let fx = AttachmentPressFixture()
        fx.message.onActionsRead = {
            switch drift {
            case "row-removed":
                fx.transcript.childrenNodes = []
            case "link-only-row":
                fx.transcript.childrenNodes = []
                fx.transcript.linkedNodes = [fx.message]
            case "transcript-removed":
                fx.window.childrenNodes = []
            case "wrong-parent":
                fx.message.parentNode = fx.window
            default:
                fx.transcript.childrenNodes = [fx.message, fx.message]
            }
        }
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try MessagesAttachmentAXPress(driver: fx, isTargetEligible: fx.eligible).perform(
                messageGUID: "synthetic-message", nativePartIndex: 1, nativePartGUID: nil,
                deadline: .millisecondsFromNow(5000), validateTarget: { .pending })
        }
        #expect(fx.message.performed.isEmpty)
    }

    @Test(arguments: [2, 3]) func replacementBeforePressIsRefused(_ changeAt: Int) throws {
        let fx = AttachmentPressFixture()
        var validations = 0
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try MessagesAttachmentAXPress(driver: fx, isTargetEligible: fx.eligible).perform(
                messageGUID: "synthetic-message", nativePartIndex: 0, nativePartGUID: nil,
                deadline: .millisecondsFromNow(5000), validateTarget: {
                    validations += 1
                    if validations == changeAt { fx.transcript.childrenNodes = [fx.message.clone()] }
                    return .pending
                })
        }
        #expect(fx.message.performed.isEmpty)
    }
    @Test func missingPressActionIsRefused() throws {
        let fx = AttachmentPressFixture()
        fx.message.pressActions = []
        #expect(throws: MessagesAttachmentAXPress.Failure.pressUnavailable) {
            try MessagesAttachmentAXPress(driver: fx, isTargetEligible: fx.eligible).perform(
                messageGUID: "synthetic-message", nativePartIndex: 0, nativePartGUID: nil,
                deadline: .millisecondsFromNow(5000), validateTarget: { .pending })
        }
        #expect(fx.message.performed.isEmpty)
    }
    @Test(arguments: [1, 2, 3]) func downloadedObservationSkipsPress(_ changeAt: Int) throws {
        let fx = AttachmentPressFixture()
        var checks = 0
        try MessagesAttachmentAXPress(driver: fx, isTargetEligible: fx.eligible).perform(
            messageGUID: "synthetic-message", nativePartIndex: 0, nativePartGUID: nil,
            deadline: .millisecondsFromNow(5000), validateTarget: {
                checks += 1
                return checks == changeAt ? .downloaded : .pending
            })
        #expect(checks == changeAt)
        #expect(fx.message.performed.isEmpty)
    }

    @Test(arguments: [1, 2, 3], [MessagesAttachmentRetrievalState.Outcome.failed, .unavailable])
    func uncertainObservationRefusesPress(_ changeAt: Int, _ outcome: MessagesAttachmentRetrievalState.Outcome) throws {
        let fx = AttachmentPressFixture()
        var checks = 0
        #expect(throws: MessagesAttachmentAXPress.Failure.observationRefused) {
            try MessagesAttachmentAXPress(driver: fx, isTargetEligible: fx.eligible).perform(
                messageGUID: "synthetic-message", nativePartIndex: 0, nativePartGUID: nil,
                deadline: .millisecondsFromNow(5000), validateTarget: {
                    checks += 1
                    return checks == changeAt ? outcome : .pending
                })
        }
        #expect(checks == changeAt)
        #expect(fx.message.performed.isEmpty)
    }

}

private final class AttachmentPressFixture: MessagesReactionAXDriving {
    var onOpen: (() throws -> Void)?
    var processIdentity = MessagesAXProcessIdentity(pid: 123, bundleURL: URL(fileURLWithPath: "/Applications/Messages.app"),
                                                    launchDate: Date(timeIntervalSince1970: 1_000))
    var root = AttachmentPressNode(role: "AXApplication")
    var window = AttachmentPressNode(role: "AXWindow")
    var transcript = AttachmentPressNode(role: "AXCollection", identifier: "TranscriptCollectionView")
    var message = AttachmentPressNode(role: "AXGroup", selected: true, eligible: true)

    init() {
        root.pid = processIdentity.pid
        window.pid = processIdentity.pid
        transcript.pid = processIdentity.pid
        message.pid = processIdentity.pid
        transcript.parentNode = window
        message.parentNode = transcript
        transcript.owner = window
        message.owner = window
        root.childrenNodes = [window]
        root.directWindowNodes = [window]
        window.childrenNodes = [transcript]
        transcript.childrenNodes = [message]
    }

    func addSharingAffordance(reversed: Bool = false) -> (AttachmentPressNode, AttachmentPressNode) {
        window.id = "SceneWindow"
        window.subroleName = "AXStandardWindow"
        window.parentNode = root
        let overlay = AttachmentPressNode(role: "AXWindow")
        overlay.subroleName = "AXDialog"
        overlay.parentNode = root
        overlay.mainValue = false
        overlay.focusValue = false
        let button = AttachmentPressNode(role: "AXButton")
        button.title = "WindowSharingSessionButton"
        button.parentNode = overlay
        overlay.childrenNodes = [button]
        root.directWindowNodes = reversed ? [overlay, window] : [window, overlay]
        return (overlay, button)
    }

    var process: MessagesAXProcess { MessagesAXProcess(identity: processIdentity, root: root) }

    func navigator(maxTraversalNodes: Int = 2_048, maxTraversalDepth: Int = 32,
                   maxChildren: Int = 256) -> MessagesAXNavigator {
        MessagesAXNavigator(driver: self, maxTraversalNodes: maxTraversalNodes,
                            maxTraversalDepth: maxTraversalDepth, maxChildren: maxChildren)
    }

    func eligible(_ element: any MessagesAXElement, _ deadline: WorkerDeadline) throws -> Bool {
        (element as? AttachmentPressNode)?.eligible == true
    }

    func checkAccessibilityTrusted(prompt: Bool) -> Bool { true }
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess { try onOpen?(); return process }
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess { process }
    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool { true }
    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { nil }
    func reactActionTitles(deadline: WorkerDeadline) throws -> [String] { ["React"] }
    func customEmojiSearchPlan(for emoji: String, deadline: WorkerDeadline) throws -> MessagesCustomEmojiSearchPlan { throw MessagesAXNavigationError.axFailure }
    func pressCustomEmojiChooserKey(_ key: MessagesCustomEmojiChooserKey, process: MessagesAXProcess, deadline: WorkerDeadline) throws { throw MessagesAXNavigationError.axFailure }
    func detachedCustomEmojiPopover(process: MessagesAXProcess, deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { throw MessagesAXNavigationError.axFailure }

}

private final class AttachmentPressNode: MessagesAXElement {
    var performed: [String] = []
    var onEnabledRead: (() throws -> Void)?
    var onActionsRead: (() throws -> Void)?
    var onPerform: (() throws -> Void)?
    var pressActions = ["AXPress"]
    var identity = UUID()
    var roleName: String
    var id: String?
    var subroleName: String?
    var title: String?
    var mainValue: Bool?
    var focusValue: Bool?
    weak var parentNode: (any MessagesAXElement)?
    var onWindowRead: ((Int) -> Void)?
    var windowReads = 0
    var isSelected: Bool?
    var eligible: Bool
    var pid: Int32 = 123
    weak var owner: (any MessagesAXElement)?
    var childrenNodes: [any MessagesAXElement] = []
    var linkedNodes: [any MessagesAXElement] = []
    var linkReads = 0
    var childCount: MessagesAXRelationshipCount?
    var linkCount: MessagesAXRelationshipCount?
    var failLinkRead = false
    var directWindowNodes: [any MessagesAXElement]?

    init(role: String, identifier: String? = nil, selected: Bool? = nil, eligible: Bool = false) {
        self.roleName = role
        self.id = identifier
        self.isSelected = selected
        self.eligible = eligible
    }

    func clone() -> AttachmentPressNode {
        let clone = AttachmentPressNode(role: roleName, identifier: id, selected: isSelected, eligible: eligible)
        clone.pid = pid
        clone.subroleName = subroleName
        clone.title = title
        clone.mainValue = mainValue
        clone.focusValue = focusValue
        clone.parentNode = parentNode
        clone.owner = owner
        clone.childrenNodes = childrenNodes
        clone.linkedNodes = linkedNodes
        clone.directWindowNodes = directWindowNodes
        return clone
    }

    func sameIdentity(as other: any MessagesAXElement) -> Bool {
        (other as? AttachmentPressNode)?.identity == identity
    }

    func role(deadline: WorkerDeadline) throws -> String { try checkMessagesAXDeadline(deadline); return roleName }
    func identifier(deadline: WorkerDeadline) throws -> String? { try checkMessagesAXDeadline(deadline); return id }
    func axDescription(deadline: WorkerDeadline) throws -> String? { nil }
    func axValue(deadline: WorkerDeadline) throws -> String? { nil }
    func candidateValueText(deadline: WorkerDeadline) throws -> String? { nil }
    func axTitle(deadline: WorkerDeadline) throws -> String? { title }
    func subrole(deadline: WorkerDeadline) throws -> String? { subroleName }
    func mainWindow(deadline: WorkerDeadline) throws -> Bool? { mainValue }
    func focused(deadline: WorkerDeadline) throws -> Bool? { focusValue }
    func enabled(deadline: WorkerDeadline) throws -> Bool? {
        try onEnabledRead?()
        return true
    }
    func selected(deadline: WorkerDeadline) throws -> Bool? { try checkMessagesAXDeadline(deadline); return isSelected }
    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        try checkMessagesAXDeadline(deadline)
        return roleName == "AXWindow" ? self : owner
    }
    func directWindows(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try checkMessagesAXDeadline(deadline)
        windowReads += 1
        onWindowRead?(windowReads)
        return directWindowNodes ?? childrenNodes.filter { (try? $0.role(deadline: deadline)) == "AXWindow" }
    }
    func parent(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { parentNode }
    func processIdentifier(deadline: WorkerDeadline) throws -> Int32? { try checkMessagesAXDeadline(deadline); return pid }
    func valueSettable(deadline: WorkerDeadline) throws -> Bool? { nil }
    func actions(deadline: WorkerDeadline) throws -> [String] {
        try onActionsRead?()
        return pressActions
    }
    func children(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try checkMessagesAXDeadline(deadline)
        return childrenNodes
    }
    func childrenInNavigationOrder(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]? { nil }
    func linkedElements(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try checkMessagesAXDeadline(deadline)
        linkReads += 1
        if failLinkRead { throw MessagesAXNavigationError.unknownAXValue }
        return linkedNodes
    }
    func relationshipCount(_ attribute: MessagesAXRelationshipAttribute, limit: Int,
                           deadline: WorkerDeadline) throws -> MessagesAXRelationshipCount {
        switch attribute {
        case .children: return try childCount ?? .available(children(limit: limit, deadline: deadline).count)
        case .linkedElements: return try linkCount ?? .available(linkedElements(limit: limit, deadline: deadline).count)
        }
    }
    func setValue(_ value: String, deadline: WorkerDeadline) throws {}
    func performAction(named name: String, deadline: WorkerDeadline) throws { performed.append(name); try onPerform?() }
}


@Suite struct MessagesAttachmentPendingWorkerRegressionTests {
    private func attachmentBody(guid: String) -> Data {
        let body = NSMutableAttributedString(string: "apple-cli-test \u{fffc}")
        let range = NSRange(location: body.length - 1, length: 1)
        body.addAttribute(.init("__kIMMessagePartAttributeName"), value: NSNumber(value: 1),
                          range: NSRange(location: 0, length: range.location))
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: range)
        body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: guid, range: range)
        return NSArchiver.archivedData(withRootObject: body)
    }

    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.insertMessage(rowid: 60, guid: "synthetic-pending", attributedBody: attachmentBody(guid: "a10"),
                             chatRowid: 3, date: fx.base, cacheHasAttachments: true)
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,10); ALTER TABLE attachment ADD COLUMN transfer_state; UPDATE attachment SET transfer_state=4")
        return fx
    }

    private func run(_ fx: ChatFixture, driver: AttachmentPressFixture,
                     afterResolution: () throws -> Void = {}) throws -> WorkerOperationResult {
        let captured = try MessagesAttachmentTargetResolver.read(databasePath: fx.path, chat: .rowid(3),
            message: .rowid(60), partIndex: 0, sandboxPrefix: "apple-cli-test", deadline: .millisecondsFromNow(5000))
        let command = try WorkerCommand(name: "messages.attachment.retrieve", payload: captured.request.workerPayloadData())
        try afterResolution()
        driver.message.pressActions = ["AXPress", "Name:React"]
        let registry = MessagesAttachmentRetrievalWorkerRegistry(driver: driver, databasePath: fx.path, homeDirectory: fx.homePath)
        let operation = try #require(registry.operation(for: command))
        let identity = WorkerProcessIdentity(pid: 1, parentPID: 0, uid: 1, gid: 1,
            startTimeMicroseconds: 1, executableDevice: 1, executableInode: 1, executablePath: "/tmp/apple")
        let request = WorkerRequest(schemaVersion: 1, operationID: UUID(), nonce: UUID(), deadline: .millisecondsFromNow(5000),
            parent: identity, workerExecutable: .init(uid: 1, gid: 1, device: 1, inode: 1, path: "/tmp/apple"), command: command)
        return try operation.run(request, deadline: request.deadline)
    }

    @Test(arguments: ["navigation", "press", "eligibility", "initial-binding", "verification-read",
                      "initial-state", "verification-state"])
    func workerReturnsOnlyFixedDiagnosticAndNeverRetries(_ stage: String) throws {
        let fx = try fixture(), driver = AttachmentPressFixture()
        let secret = "synthetic-secret /private/path\nmessage:body"
        let sentinel = NSError(domain: secret, code: 19)
        switch stage {
        case "navigation": driver.onOpen = { throw sentinel }
        case "press": driver.message.onPerform = { throw sentinel }
        case "eligibility": driver.onOpen = { driver.message.pressActions = ["AXPress", "Name:React", "Name:React"] }
        case "verification-read": driver.message.onPerform = { try fx.exec("ALTER TABLE message RENAME COLUMN attributedBody TO old_body") }
        case "initial-state": try fx.exec("UPDATE attachment SET transfer_state=10")
        case "verification-state": driver.message.onPerform = { try fx.exec("UPDATE attachment SET transfer_state=10") }
        default: break
        }
        let result = try run(fx, driver: driver, afterResolution: {
            if stage == "initial-binding" { try fx.exec("UPDATE message SET guid='synthetic-other-guid' WHERE ROWID=60") }
        })
        let category: String
        switch stage {
        case "eligibility": category = "unknown-ax-value"
        case "initial-binding": category = "target-drift"
        case "initial-state", "verification-state": category = "state-unavailable"
        default: category = "other"
        }
        #expect(result.category == (stage == "initial-state" ? .refused : .failed))
        #expect(result.detail == "attachment-unverified:\(stage):\(category)")
        #expect(result.detail?.contains(secret) == false)
        let pressed = ["press", "verification-read", "verification-state"].contains(stage)
        #expect(driver.message.performed == (pressed ? ["AXPress"] : []))
    }

    @Test(arguments: [MessagesReactionAXError.deadlineExpired, .targetDrift,
                      .ambiguousSelectedMessage, .unknownAXValue, .traversalLimit, .axFailure])
    func liveDriverErrorFamilyKeepsCategoryWithoutRetry(_ error: MessagesReactionAXError) throws {
        let fx = try fixture(), driver = AttachmentPressFixture()
        var openings = 0
        driver.onOpen = { openings += 1; throw error }
        let result = try run(fx, driver: driver)
        #expect(result.category == .failed)
        #expect(result.detail == "attachment-unverified:navigation:\(error.rawValue)")
        #expect(openings == 1)
        #expect(driver.message.performed.isEmpty)
    }

    @Test(arguments: [false, true])
    func addressCollisionDuringRetrievalCannotVerifySuccess(_ afterPress: Bool) throws {
        let fx = try fixture(), driver = AttachmentPressFixture()
        let body = NSMutableAttributedString(string: "apple-cli-test ")
        body.append(NSAttributedString(string: "\u{fffc}", attributes: [
            .init("__kIMMessagePartAttributeName"): NSNumber(value: 0),
            .init("__kIMFileTransferGUIDAttributeName"): "a10"
        ]))
        let hex = NSArchiver.archivedData(withRootObject: body).map { String(format: "%02x", $0) }.joined()
        var changes = 0
        let introduceCollision = {
            changes += 1
            try fx.exec("UPDATE message SET attributedBody=X'\(hex)' WHERE ROWID=60; UPDATE attachment SET transfer_state=5 WHERE ROWID=10")
        }
        if afterPress {
            driver.message.onPerform = introduceCollision
        } else {
            driver.onOpen = introduceCollision
        }
        let result = try run(fx, driver: driver)
        #expect(changes == 1)
        #expect(result.category == .failed)
        #expect(driver.message.performed == (afterPress ? ["AXPress"] : []))
    }

    private enum TransferChangePoint: CaseIterable { case enabled, routeAction }

    @Test(arguments: [false, true], TransferChangePoint.allCases)
    private func transferChangeWhileReadingPressControlsSkipsPress(_ completed: Bool, at point: TransferChangePoint) throws {
        let fx = try fixture(), driver = AttachmentPressFixture()
        var changed = false
        let changeTransfer = {
            guard !changed else { return }
            changed = true
            if completed {
                try fx.exec("UPDATE attachment SET transfer_state=5 WHERE ROWID=10")
            } else {
                let hex = self.attachmentBody(guid: "replacement-guid").map { String(format: "%02x", $0) }.joined()
                try fx.exec("""
                    BEGIN;
                    UPDATE message SET attributedBody=X'\(hex)' WHERE ROWID=60;
                    UPDATE attachment SET guid='replacement-guid' WHERE ROWID=10;
                    COMMIT;
                    """)
            }
        }
        switch point {
        case .enabled:
            driver.message.onEnabledRead = changeTransfer
        case .routeAction:
            driver.message.onEnabledRead = { [weak message = driver.message] in
                var actionReads = 0
                message?.onActionsRead = {
                    actionReads += 1
                    // The direct AXPress lookup precedes the route's eligibility lookup.
                    if actionReads == 2 { try changeTransfer() }
                }
            }
        }
        let result = try run(fx, driver: driver)
        #expect(changed)
        #expect(driver.message.performed.isEmpty)
        #expect(result.category == (completed ? .ack : .failed))
    }

    @Test func pendingWorkerPressesExactlyOnceAndVerifiesAvailability() throws {
        let fx = try fixture(), driver = AttachmentPressFixture()
        driver.message.onPerform = { try fx.exec("UPDATE attachment SET transfer_state=5") }
        let result = try run(fx, driver: driver)
        #expect(result.category == .ack)
        #expect(result.detail == "attachment-retrieval-downloaded-verified")
        #expect(driver.message.performed == ["AXPress"])
    }

    @Test(arguments: [5, 6, 10]) func finalStateGatesNativePress(_ state: Int) throws {
        let fx = try fixture(), driver = AttachmentPressFixture()
        driver.onOpen = { try fx.exec("UPDATE attachment SET transfer_state=\(state)") }
        let result = try run(fx, driver: driver)
        #expect(driver.message.performed.isEmpty)
        #expect(result.category == (state == 5 ? .ack : .failed))
    }

    @Test(arguments: [
        "UPDATE message SET text='label removed' WHERE ROWID=60",
        "UPDATE chat SET style=43 WHERE ROWID=3",
        "INSERT INTO chat_message_join VALUES(1,60)",
        "INSERT INTO message(ROWID,guid) VALUES(61,'synthetic-pending')"
    ], [false, true]) func targetDriftBeforeHandoffOrPressNeverActs(_ sql: String, _ duringOpen: Bool) throws {
        let fx = try fixture(), driver = AttachmentPressFixture()
        if duringOpen { driver.onOpen = { try fx.exec(sql) } }
        let result = try run(fx, driver: driver, afterResolution: {
            if !duringOpen { try fx.exec(sql) }
        })
        #expect(result.category == .failed)
        #expect(driver.message.performed.isEmpty)
    }

    @Test(arguments: [4, 5], [false, true])
    func availableSelectedPartNeverPressesForIncompleteSibling(_ siblingState: Int, _ duringOpen: Bool) throws {
        let fx = try fixture(), driver = AttachmentPressFixture()
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,11); UPDATE attachment SET transfer_state=\(siblingState) WHERE ROWID=11")
        var opened = false
        if duringOpen {
            driver.onOpen = {
                opened = true
                try fx.exec("UPDATE attachment SET transfer_state=5 WHERE ROWID=10")
            }
        } else {
            try fx.exec("UPDATE attachment SET transfer_state=5 WHERE ROWID=10")
        }
        let result = try run(fx, driver: driver)
        #expect(opened == duringOpen)
        #expect(driver.message.performed.isEmpty)
        #expect(result.category != .ack)
    }

    @Test func completeTwoMemberObservationSucceedsWithoutPress() throws {
        let fx = try fixture(), driver = AttachmentPressFixture()
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,11); UPDATE attachment SET transfer_state=5; UPDATE attachment SET filename=(SELECT filename FROM attachment WHERE ROWID=10) WHERE ROWID=11")
        let result = try run(fx, driver: driver)
        #expect(result.category == .ack)
        #expect(driver.message.performed.isEmpty)
    }
}
