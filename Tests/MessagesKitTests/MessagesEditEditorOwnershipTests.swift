import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesEditEditorOwnershipTests {
    @Test func exactOwnedEditorCanBeRetainedAndRevalidated() throws {
        let fx = EditOwnershipFixture()
        let token = try fx.capture()
        try fx.checker.revalidate(token, route: fx.route, expectedText: "original", deadline: .millisecondsFromNow(5000))
        #expect(fx.field.writes == 0)
        #expect(fx.confirm.writes == 0)
    }

    @Test func windowWithoutAncestorWindowSupportsEditorTransition() throws {
        let fx = EditOwnershipFixture()
        fx.window.owner = nil
        fx.prepareAction()
        try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
            deadline: .millisecondsFromNow(5000), validateTarget: {})
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 1)
        #expect(fx.cancel.writes == 0)
    }

    @Test(arguments: ["window-process", "descendant-window", "foreign-descendant-window"])
    func windowTerminalDoesNotRelaxDescendantIdentity(_ kind: String) throws {
        let fx = EditOwnershipFixture()
        fx.window.owner = nil
        switch kind {
        case "window-process": fx.window.pid = 999
        case "descendant-window": fx.panel.owner = nil
        default: fx.panel.owner = fx.root
        }
        #expect(throws: (any Error).self) { try fx.capture() }
        #expect(fx.target.writes == 0)
        #expect(fx.field.writes == 0)
        #expect(fx.confirm.writes == 0)
    }

    @Test(arguments: ["transcript", "composer", "unrelated", "duplicate", "wrong-text", "wrong-process"])
    func refusesUnownedOrAmbiguousEditor(_ kind: String) throws {
        let fx = EditOwnershipFixture()
        switch kind {
        case "transcript": fx.field.roleName = "AXTextArea"; fx.field.id = "CKBalloonTextView"
        case "composer": fx.field.id = "messageBodyField"
        case "unrelated": fx.panel.nodes.removeAll { $0 === fx.confirm }; fx.window.attach(fx.confirm)
        case "duplicate": fx.group.attach(EditOwnershipNode("AXTextField", text: "original", owner: fx.window))
        case "wrong-text": fx.field.text = "another message"
        default: fx.field.pid = 999
        }
        #expect(throws: (any Error).self) { try fx.capture() }
        #expect(fx.field.writes == 0)
    }

    @Test func replacingFieldAfterCaptureInvalidatesToken() throws {
        let fx = EditOwnershipFixture()
        let token = try fx.capture()
        fx.group.nodes.removeAll { $0 === fx.field }
        fx.group.attach(EditOwnershipNode("AXTextField", text: "original", owner: fx.window))
        #expect(throws: (any Error).self) {
            try fx.checker.revalidate(token, route: fx.route, expectedText: "original", deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func preflightPreservesExistingEditorAndComposerDraft() throws {
        let fx = EditOwnershipFixture()
        #expect(throws: (any Error).self) {
            try fx.checker.requireInactive(route: fx.route, deadline: .millisecondsFromNow(5000))
        }
        fx.hideEditor()
        let composer = EditOwnershipNode("AXTextField", owner: fx.window)
        composer.id = "messageBodyField"
        fx.window.attach(composer)
        try fx.checker.requireInactive(route: fx.route, deadline: .millisecondsFromNow(5000))
        composer.text = "user draft"
        #expect(throws: (any Error).self) {
            try fx.checker.requireInactive(route: fx.route, deadline: .millisecondsFromNow(5000))
        }
        #expect(composer.writes == 0)
        #expect(fx.cancel.writes == 0)
    }

    @Test func emptySearchFieldIsAllowedButSearchTextIsPreserved() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let search = EditOwnershipNode("AXTextField", owner: fx.window)
        search.subroleName = "AXSearchField"
        fx.window.attach(search)
        try fx.checker.requireInactive(route: fx.route, deadline: .millisecondsFromNow(5000))
        search.text = "synthetic search"
        #expect(throws: (any Error).self) {
            try fx.checker.requireInactive(route: fx.route, deadline: .millisecondsFromNow(5000))
        }
        #expect(search.writes == 0)
    }

    @Test func cancelControlAloneIsNotAnActiveEditor() throws {
        let fx = EditOwnershipFixture()
        fx.hideEditor(); fx.panel.attach(fx.cancel)
        try fx.checker.requireInactive(route: fx.route, deadline: .millisecondsFromNow(5000))
        fx.panel.attach(EditOwnershipNode("AXTextField", owner: fx.window))
        #expect(throws: (any Error).self) {
            try fx.checker.requireInactive(route: fx.route, deadline: .millisecondsFromNow(5000))
        }
    }


    @Test func confirmationReadinessWaitsWithoutRepeatingReplacement() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        fx.field.onSetValue = {}
        var polls = 0
        var action = try fx.action
        action.pause = { _ in polls += 1; fx.confirm.isEnabled = true }
        try action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
            deadline: .millisecondsFromNow(5000), validateTarget: {})
        #expect(polls == 1)
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 1)
    }

    @Test(arguments: ["container", "transcript", "panel", "confirm", "cancel", "enabled-before-replacement", "foreign-window"])
    func editorPhaseDriftStopsBeforeReplacement(_ kind: String) throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        fx.target.onPerform = { _ in
            fx.showEditor()
            switch kind {
            case "container": fx.transcript.nodes = []
            case "transcript": fx.panel.nodes.removeAll { $0 === fx.transcript }
            case "panel": fx.window.nodes = []
            case "confirm": fx.panel.attach(EditOwnershipNode("AXButton", label: "Send edit", owner: fx.window))
            case "cancel": fx.panel.attach(EditOwnershipNode("AXButton", label: "Cancel edit", owner: fx.window))
            case "enabled-before-replacement": fx.confirm.isEnabled = true
            default: fx.field.owner = fx.root
            }
        }
        #expect(throws: (any Error).self) {
            try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
                deadline: .millisecondsFromNow(5000), validateTarget: {})
        }
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == 0)
        #expect(fx.confirm.writes == 0)
        #expect(fx.cancel.writes == 0)
    }

    @Test func oversizedOriginalStopsBeforeOpeningEditor() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        #expect(throws: (any Error).self) {
            try fx.action.perform(route: fx.route, expectedText: String(repeating: "a", count: 4097),
                replacement: "replacement", deadline: .millisecondsFromNow(5000), validateTarget: {})
        }
        #expect(fx.target.writes == 0)
        #expect(fx.field.writes == 0)
        #expect(fx.confirm.writes == 0)
    }

    @Test func actionAssignsAndCommitsExactlyOnce() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        var checks = 0
        try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
            deadline: .millisecondsFromNow(5000), validateTarget: { checks += 1 })
        #expect(checks == 3)
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 1)
        #expect(fx.cancel.writes == 0)
    }

    @Test(arguments: [1, 2, 3])
    func competingSelectionStopsNextMutation(_ boundary: Int) throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let competitor = EditOwnershipNode("AXGroup", owner: fx.window)
        competitor.actionNames = ["Name:Edit"]
        var checks = 0
        #expect(throws: MessagesAXNavigationError.ambiguousSelectedMessage) {
            try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
                deadline: .millisecondsFromNow(5000), validateTarget: {
                    checks += 1
                    if checks == boundary { fx.transcript.attach(competitor) }
                })
        }
        #expect(fx.target.writes == (boundary > 1 ? 1 : 0))
        #expect(fx.field.writes == (boundary > 2 ? 1 : 0))
        #expect(fx.confirm.writes == 0)
        #expect(competitor.writes == 0)
    }

    @Test(arguments: [2, 3], [false, true])
    func nestedCompetingSelectionStopsNextMutation(_ boundary: Int, _ removeOriginal: Bool) throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let container = EditOwnershipNode("AXGroup", owner: fx.window)
        container.isSelected = false
        fx.transcript.nodes = []
        fx.transcript.attach(container)
        container.attach(fx.target)
        let competitor = EditOwnershipNode("AXGroup", owner: fx.window)
        competitor.actionNames = ["Name:Edit"]
        fx.target.onPerform = { _ in
            fx.showEditor()
            if removeOriginal { container.nodes.removeAll { $0 === fx.target } }
        }
        var checks = 0, polls = 0
        var action = try fx.action
        action.pause = { _ in polls += 1 }
        #expect(throws: MessagesAXNavigationError.ambiguousSelectedMessage) {
            try action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
                deadline: .millisecondsFromNow(5000), validateTarget: {
                    checks += 1
                    if checks == boundary { container.attach(competitor) }
                })
        }
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == (boundary == 3 ? 1 : 0))
        #expect(fx.confirm.writes == 0)
        #expect(fx.cancel.writes == 0)
        #expect(competitor.writes == 0)
        #expect(polls == 0)
    }

    @Test(arguments: ["cleared", "removed", "retained"])
    func nestedOriginalSelectionTransitionRemainsSupported(_ transition: String) throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let container = EditOwnershipNode("AXGroup", owner: fx.window)
        container.isSelected = false
        fx.transcript.nodes = []
        fx.transcript.attach(container)
        container.attach(fx.target)
        fx.target.onPerform = { _ in
            fx.showEditor()
            if transition == "removed" { container.nodes.removeAll { $0 === fx.target } }
            if transition == "retained" { fx.target.isSelected = true }
        }
        try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
            deadline: .millisecondsFromNow(5000), validateTarget: {})
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 1)
        #expect(fx.cancel.writes == 0)
    }

    @Test(arguments: [2, 3])
    func unknownNestedSelectionStopsNextMutation(_ boundary: Int) throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let container = EditOwnershipNode("AXGroup", owner: fx.window)
        container.isSelected = false
        fx.transcript.nodes = []
        fx.transcript.attach(container)
        container.attach(fx.target)
        let competitor = EditOwnershipNode("AXGroup", owner: fx.window)
        competitor.actionNames = ["Name:Edit"]
        competitor.isSelected = false
        container.attach(competitor)
        var checks = 0, polls = 0
        var action = try fx.action
        action.pause = { _ in polls += 1 }
        #expect(throws: MessagesAXNavigationError.unknownAXValue) {
            try action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
                deadline: .millisecondsFromNow(5000), validateTarget: {
                    checks += 1
                    if checks == boundary { competitor.isSelected = nil }
                })
        }
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == (boundary == 3 ? 1 : 0))
        #expect(fx.confirm.writes == 0)
        #expect(fx.cancel.writes == 0)
        #expect(competitor.writes == 0)
        #expect(polls == 0)
    }

    @Test func inertNestedNodeMayOmitSelectionEvidence() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let inert = EditOwnershipNode("AXStaticText", owner: fx.window)
        inert.isSelected = nil
        inert.actionNames = []
        fx.target.attach(inert)
        try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
            deadline: .millisecondsFromNow(5000), validateTarget: {})
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 1)
        #expect(inert.writes == 0)
    }

    @Test func retainedEditorWithoutEditActionRemainsEligible() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        fx.target.onPerform = { _ in
            fx.target.actionNames = []
            fx.showEditor()
        }
        try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
            deadline: .millisecondsFromNow(5000), validateTarget: {})
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 1)
    }

    @Test(arguments: ["appearance", "disappearance"])
    func explicitReadinessWaitsWithoutRepeatingActions(_ phase: String) throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        if phase == "appearance" { fx.target.onPerform = { _ in } }
        else { fx.confirm.onPerform = { _ in } }
        var polls = 0
        var action = try fx.action
        action.pause = { _ in
            polls += 1
            if phase == "appearance" { fx.showEditor() }
            else { fx.hideEditor() }
        }
        try action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
            deadline: .millisecondsFromNow(5000), validateTarget: {})
        #expect(polls == 1)
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 1)
    }

    @Test func transientEditorReplacementStopsWithoutPollingPastDrift() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let substitute = EditOwnershipNode("AXTextField", text: "replacement", owner: fx.window)
        fx.field.onSetValue = {
            fx.group.nodes.removeAll { $0 === fx.field }
            fx.group.attach(substitute)
        }
        var polls = 0
        var action = try fx.action
        action.pause = { _ in
            polls += 1
            fx.group.nodes.removeAll { $0 === substitute }
            fx.group.attach(fx.field)
        }
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
                deadline: .millisecondsFromNow(5000), validateTarget: {})
        }
        #expect(polls == 0)
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 0)
    }

    @Test func expiryBeforeCommitNeverPressesOrCancels() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        var checks = 0
        #expect(throws: MessagesAXNavigationError.deadlineExpired) {
            try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
                deadline: .millisecondsFromNow(5000), validateTarget: {
                    checks += 1
                    if checks == 3 { throw MessagesAXNavigationError.deadlineExpired }
                })
        }
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 0)
        #expect(fx.cancel.writes == 0)
    }

    @Test func uncertainCommitIsNotRetried() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        fx.confirm.onPerform = { _ in throw MessagesAXNavigationError.axFailure }
        #expect(throws: MessagesAXNavigationError.axFailure) {
            try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
                deadline: .millisecondsFromNow(5000), validateTarget: {})
        }
        #expect(fx.confirm.writes == 1)
        #expect(fx.cancel.writes == 0)
    }

    @Test func oversizedOriginalStopsBeforeNavigation() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        #expect(throws: (any Error).self) {
            try fx.automation.perform(messageGUID: "synthetic-message", nativePartIndex: 0,
                expectedText: String(repeating: "é", count: 2049), replacement: "replacement",
                deadline: .millisecondsFromNow(5000), validateTarget: {})
        }
        #expect(fx.opens == 0)
        #expect(fx.target.writes == 0)
        #expect(fx.field.writes == 0)
        #expect(fx.confirm.writes == 0)
    }

    @Test func automationNavigatesOnceAfterPreflightThenCommits() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        var validations = 0
        try fx.automation.perform(messageGUID: "synthetic-message", nativePartIndex: 0,
            expectedText: "original", replacement: "replacement", deadline: .millisecondsFromNow(5000),
            validateTarget: { validations += 1 })
        #expect(fx.opens == 1)
        #expect(validations == 4)
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 1)
    }

    @Test(arguments: ["child-image", "linked-image", "nested-attachment", "filetransfer"])
    func attachmentOnlyDraftPreventsNavigation(_ kind: String) throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let composer = EditOwnershipNode("AXTextField", owner: fx.window)
        composer.id = "messageBodyField"
        fx.window.attach(composer)
        let attachment = EditOwnershipNode(kind.contains("image") ? "AXImage" : "AXGroup", owner: fx.window)
        attachment.id = kind == "filetransfer" ? "FileTransfer" : "Attachment"
        if kind == "linked-image" {
            composer.links = [attachment]
        } else if kind == "nested-attachment" {
            let group = EditOwnershipNode("AXGroup", owner: fx.window)
            composer.attach(group); group.attach(attachment)
        } else {
            composer.attach(attachment)
        }
        #expect(throws: (any Error).self) {
            try fx.automation.perform(messageGUID: "synthetic-message", nativePartIndex: 0,
                expectedText: "original", replacement: "replacement", deadline: .millisecondsFromNow(5000),
                validateTarget: {})
        }
        #expect(fx.opens == 0)
        #expect(fx.target.writes == 0)
        #expect(fx.field.writes == 0)
        #expect(fx.confirm.writes == 0)
        #expect(composer.writes == 0)
        #expect(attachment.writes == 0)
    }

    @Test func automationPreservesDraftBeforeNavigation() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let composer = EditOwnershipNode("AXTextField", text: "synthetic draft", owner: fx.window)
        composer.id = "messageBodyField"
        fx.window.attach(composer)
        #expect(throws: (any Error).self) {
            try fx.automation.perform(messageGUID: "synthetic-message", nativePartIndex: 0,
                expectedText: "original", replacement: "replacement", deadline: .millisecondsFromNow(5000),
                validateTarget: {})
        }
        #expect(fx.opens == 0)
        #expect(composer.text == "synthetic draft")
        #expect(composer.writes == 0)
        #expect(fx.target.writes == 0)
    }

    @Test func automationRechecksBaselineBeforeNavigation() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            try fx.automation.perform(messageGUID: "synthetic-message", nativePartIndex: 0,
                expectedText: "original", replacement: "replacement", deadline: .millisecondsFromNow(5000),
                validateTarget: { throw MessagesAXNavigationError.targetDrift })
        }
        #expect(fx.opens == 0)
        #expect(fx.target.writes == 0)
    }

    @Test func diagnosticObservesConfirmationFailureWithoutChangingThrownError() throws {
        let fx = EditOwnershipFixture()
        fx.prepareAction()
        let diagnostic = MessagesEditDiagnostic()
        fx.confirm.onPerform = { _ in throw MessagesAXNavigationError.axFailure }
        #expect(throws: MessagesAXNavigationError.axFailure) {
            try fx.action.perform(route: fx.route, expectedText: "original", replacement: "replacement",
                deadline: .millisecondsFromNow(5000), validateTarget: {}, diagnostic: diagnostic)
        }
        #expect(diagnostic.stage == .confirmation)
        #expect(fx.target.writes == 1)
        #expect(fx.field.writes == 1)
        #expect(fx.confirm.writes == 1)
        #expect(fx.cancel.writes == 0)
    }

}

private final class EditOwnershipFixture: MessagesAXProcessDriving {
    var opens = 0
    let root = EditOwnershipNode("AXApplication")
    let window = EditOwnershipNode("AXWindow")
    let panel = EditOwnershipNode("AXGroup")
    let transcript = EditOwnershipNode("AXCollection")
    let target = EditOwnershipNode("AXGroup")
    let group = EditOwnershipNode("AXGroup")
    let field = EditOwnershipNode("AXTextField", text: "original")
    let confirm = EditOwnershipNode("AXButton", label: "Send edit")
    let cancel = EditOwnershipNode("AXButton", label: "Cancel edit")
    init() {
        window.owner = window
        for node in [panel, transcript, target, group, field, confirm, cancel] { node.owner = window }
        transcript.id = "TranscriptCollectionView"
        root.attach(window); window.attach(panel); panel.attach(transcript); transcript.attach(target)
        group.attach(field); showEditor()
        field.onSetValue = { [unowned self] in self.confirm.isEnabled = true }
    }
    var process: MessagesAXProcess { .init(identity: .init(pid: 123, bundleURL: URL(fileURLWithPath: "/Applications/Messages.app"), launchDate: Date(timeIntervalSince1970: 1)), root: root) }
    var route: MessagesAXRoute { .init(process: process, window: window, transcript: transcript, selected: target) }
    var checker: MessagesEditEditorOwnership { get throws {
        try .init(navigator: MessagesAXNavigator(driver: self), editTitle: "Edit", confirmTitle: "Send edit", cancelTitle: "Cancel edit")
    } }
    func prepareAction() {
        hideEditor()
        target.isSelected = true
        target.actionNames = ["Name:Edit"]
        target.onPerform = { [unowned self] _ in self.showEditor() }
        confirm.onPerform = { [unowned self] _ in self.hideEditor() }
    }
    func showEditor() {
        target.isSelected = false
        confirm.isEnabled = false
        panel.attach(group); panel.attach(confirm); panel.attach(cancel)
    }
    func hideEditor() { panel.nodes.removeAll { $0 !== transcript } }
    var action: MessagesEditAXAction { get throws {
        let titles = try MessagesEditActionTitles.resolve(deadline: .millisecondsFromNow(5000)) {
            ["edit.button": "Edit", "editing.confirm.button": "Send edit", "editing.reject.button": "Cancel edit"][$0]
        }
        return MessagesEditAXAction(navigator: MessagesAXNavigator(driver: self), titles: titles, pause: { _ in })
    } }
    var automation: MessagesEditAXAutomation {
        MessagesEditAXAutomation(driver: self, resolveTitles: { deadline in
            try MessagesEditActionTitles.resolve(deadline: deadline) {
                ["edit.button": "Edit", "editing.confirm.button": "Send edit", "editing.reject.button": "Cancel edit"][$0]
            }
        })
    }
    func capture() throws -> MessagesEditEditorOwnership.Token {
        try checker.capture(route: route, anchor: checker.retainAnchor(route: route, deadline: .millisecondsFromNow(5000)), expectedText: "original", deadline: .millisecondsFromNow(5000))
    }
    func checkAccessibilityTrusted(prompt: Bool) -> Bool { true }
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess { opens += 1; return process }
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess { process }
    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool { true }
    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { field }
}

private final class EditOwnershipNode: MessagesAXElement {
    var roleName: String
    var subroleName: String?
    var id: String?
    var label: String?
    var text: String
    var pid: Int32 = 123
    var writes = 0
    var isEnabled = true
    var isSelected: Bool? = true
    var actionNames = ["AXPress"]
    var onPerform: ((String) throws -> Void)?
    var onSetValue: (() throws -> Void)?
    weak var owner: EditOwnershipNode?
    weak var parentNode: EditOwnershipNode?
    var nodes: [EditOwnershipNode] = []
    var links: [EditOwnershipNode] = []
    init(_ role: String, text: String = "", label: String? = nil, owner: EditOwnershipNode? = nil) {
        roleName = role; self.text = text; self.label = label; self.owner = owner
    }
    func attach(_ node: EditOwnershipNode) { nodes.append(node); node.parentNode = self }
    func sameIdentity(as other: any MessagesAXElement) -> Bool { (other as? EditOwnershipNode) === self }
    func role(deadline: WorkerDeadline) throws -> String { roleName }
    func identifier(deadline: WorkerDeadline) throws -> String? { id }
    func axDescription(deadline: WorkerDeadline) throws -> String? { label }
    func axValue(deadline: WorkerDeadline) throws -> String? { text }
    func candidateValueText(deadline: WorkerDeadline) throws -> String? { text }
    func axTitle(deadline: WorkerDeadline) throws -> String? { label }
    func subrole(deadline: WorkerDeadline) throws -> String? { subroleName }
    func enabled(deadline: WorkerDeadline) throws -> Bool? { isEnabled }
    func selected(deadline: WorkerDeadline) throws -> Bool? { isSelected }
    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { owner }
    func directWindows(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] { nodes }
    func parent(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { parentNode }
    func processIdentifier(deadline: WorkerDeadline) throws -> Int32? { pid }
    func valueSettable(deadline: WorkerDeadline) throws -> Bool? { true }
    func actions(deadline: WorkerDeadline) throws -> [String] { actionNames }
    func children(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] { nodes }
    func childrenInNavigationOrder(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement]? { nil }
    func linkedElements(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] { links }
    func setValue(_ value: String, deadline: WorkerDeadline) throws { writes += 1; text = value; try onSetValue?() }
    func performAction(named name: String, deadline: WorkerDeadline) throws { writes += 1; try onPerform?(name) }
    func bodyTextSnapshot(deadline: WorkerDeadline) throws -> MessagesAXBodyTextSnapshot { try .init(text: text, characterCount: text.utf16.count) }
}
