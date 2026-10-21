import Foundation
import ApplicationServices
import Testing
@testable import AppleKit
@testable import MessagesKit

@Suite("Messages AX navigator")
struct MessagesAXNavigatorTests {
    @Test func captureRequiresUniqueTranscriptAndSelectedTarget() throws {
        let fixture = NavigatorFixture()
        let navigator = fixture.navigator()
        _ = try navigator.captureRoute(process: fixture.process, isTargetEligible: fixture.eligible, deadline: .millisecondsFromNow(1_000))

        let duplicateTranscript = fixture.transcript.clone()
        fixture.window.childrenNodes.append(duplicateTranscript)
        #expect(throws: MessagesAXNavigationError.targetDrift) {
            _ = try navigator.captureRoute(process: fixture.process, isTargetEligible: fixture.eligible, deadline: .millisecondsFromNow(1_000))
        }

        fixture.window.childrenNodes = [fixture.transcript]
        fixture.transcript.childrenNodes.append(fixture.message.clone())
        #expect(throws: MessagesAXNavigationError.ambiguousSelectedMessage) {
            _ = try navigator.captureRoute(process: fixture.process, isTargetEligible: fixture.eligible, deadline: .millisecondsFromNow(1_000))
        }
    }

    @Test(arguments: ["process", "window", "transcript", "target"])
    func revalidateDetectsRouteReplacement(_ level: String) throws {
        let fixture = NavigatorFixture()
        let navigator = fixture.navigator()
        let route = try navigator.captureRoute(process: fixture.process, isTargetEligible: fixture.eligible,
                                               deadline: .millisecondsFromNow(1_000))

        switch level {
        case "process":
            fixture.processIdentity = MessagesAXProcessIdentity(pid: 124, bundleURL: fixture.processIdentity.bundleURL,
                                                                launchDate: fixture.processIdentity.launchDate)
        case "window":
            fixture.window = fixture.window.clone()
            fixture.root.childrenNodes = [fixture.window]
            fixture.root.directWindowNodes = [fixture.window]
        case "transcript":
            fixture.transcript = fixture.transcript.clone()
            fixture.window.childrenNodes = [fixture.transcript]
        default:
            fixture.message = fixture.message.clone()
            fixture.transcript.childrenNodes = [fixture.message]
        }

        if level == "window" {
            #expect(throws: MessagesAXRouteDrift.self) {
                try navigator.revalidate(route, isTargetEligible: fixture.eligible, deadline: .millisecondsFromNow(1_000))
            }
        } else {
            #expect(throws: MessagesAXNavigationError.targetDrift) {
                try navigator.revalidate(route, isTargetEligible: fixture.eligible, deadline: .millisecondsFromNow(1_000))
            }
        }
    }

    @Test(arguments: ["duplicate-window", "wrong-pid", "wrong-owner"])
    func rejectsAmbiguousOrForeignWindowOwnership(_ shape: String) throws {
        let fixture = NavigatorFixture()
        let navigator = fixture.navigator()
        switch shape {
        case "duplicate-window":
            fixture.root.directWindowNodes = [fixture.window, fixture.window.clone()]
        case "wrong-pid":
            fixture.window.pid = 999
        default:
            let foreign = NavigatorNode(role: "AXWindow")
            fixture.window.childrenNodes.append(foreign)
            fixture.message.owner = foreign
        }

        #expect(throws: MessagesAXRouteDrift.self) {
            _ = try navigator.captureRoute(process: fixture.process, isTargetEligible: fixture.eligible,
                                           deadline: .millisecondsFromNow(1_000))
        }
    }

    @Test(arguments: [false, true])
    func sharingAffordanceDoesNotBecomeASecondConversation(reversed: Bool) throws {
        let fixture = NavigatorFixture()
        _ = fixture.addSharingAffordance(reversed: reversed)
        let route = try fixture.navigator().captureRoute(process: fixture.process, isTargetEligible: fixture.eligible,
                                                         deadline: .millisecondsFromNow(1_000))
        #expect(route.window.sameIdentity(as: fixture.window))
        #expect(route.selected.sameIdentity(as: fixture.message))
    }

    @Test(arguments: [false, true])
    func sharingAffordancePreservesExplicitPlatformAbsence(reversed: Bool) throws {
        let fixture = NavigatorFixture()
        let (overlay, button) = fixture.addSharingAffordance(reversed: reversed)
        overlay.linkCount = .unsupported
        button.childCount = .noValue
        button.linkCount = .unsupported
        let window = try fixture.navigator().uniqueRootWindow(process: fixture.process, deadline: .millisecondsFromNow(1_000))
        #expect(window.sameIdentity(as: fixture.window))
    }

    @Test(arguments: ["overlay-no-value", "button-link-no-value", "button-child-unsupported",
                      "overlay-state-drift", "button-child-state-drift", "button-link-state-drift"])
    func sharingAffordanceRejectsUnrecognizedAbsenceAndStateDrift(shape: String) throws {
        let fixture = NavigatorFixture()
        let (overlay, button) = fixture.addSharingAffordance()
        switch shape {
        case "overlay-no-value": overlay.linkCount = .noValue
        case "button-link-no-value": button.linkCount = .noValue
        case "button-child-unsupported": button.childCount = .unsupported
        default:
            fixture.root.onWindowRead = { count in
                guard count == 2 else { return }
                switch shape {
                case "overlay-state-drift": overlay.linkCount = .unsupported
                case "button-child-state-drift": button.childCount = .noValue
                default: button.linkCount = .unsupported
                }
            }
        }
        #expect(throws: MessagesAXRouteDrift.self) {
            _ = try fixture.navigator().uniqueRootWindow(process: fixture.process, deadline: .millisecondsFromNow(1_000))
        }
    }

    @Test func nativeRelationshipCountPreservesAbsenceAndRefusesErrors() throws {
        #expect(try LiveAXElement.checkedRelationshipCount(status: .success, count: 0, limit: 256) == .available(0))
        #expect(try LiveAXElement.checkedRelationshipCount(status: .success, count: 1, limit: 256) == .available(1))
        #expect(try LiveAXElement.checkedRelationshipCount(status: .noValue, count: 0, limit: 256) == .noValue)
        #expect(try LiveAXElement.checkedRelationshipCount(status: .attributeUnsupported, count: 0, limit: 256) == .unsupported)
        for status: AXError in [.notImplemented, .cannotComplete, .invalidUIElement, .failure, .illegalArgument, .apiDisabled] {
            #expect(throws: (any Error).self) {
                try LiveAXElement.checkedRelationshipCount(status: status, count: 0, limit: 256)
            }
        }
        for (count, limit) in [(-1, 256), (257, 256), (0, -1)] {
            #expect(throws: (any Error).self) {
                try LiveAXElement.checkedRelationshipCount(status: .success, count: count, limit: limit)
            }
        }
    }

    @Test(arguments: ["scene-id", "scene-subrole", "scene-parent", "scene-pid", "overlay-role",
                      "overlay-subrole", "overlay-scene-id", "overlay-parent", "overlay-pid", "overlay-main", "overlay-focus",
                      "overlay-unknown-main", "overlay-unknown-focus", "overlay-links", "overlay-extra-child",
                      "button-role", "button-title", "button-parent", "button-pid", "button-window",
                      "button-child", "button-links", "duplicate-overlay", "extra-scene", "about-dialog",
                      "button-link-error", "overlay-link-error"], [false, true])
    func rejectsWindowSharingLookalikesAndAmbiguity(shape: String, reversed: Bool) throws {
        let fixture = NavigatorFixture()
        let (overlay, button) = fixture.addSharingAffordance(reversed: reversed)
        switch shape {
        case "scene-id": fixture.window.id = nil
        case "scene-subrole": fixture.window.subroleName = "AXDialog"
        case "scene-parent": fixture.window.parentNode = nil
        case "scene-pid": fixture.window.pid = 999
        case "overlay-role": overlay.roleName = "AXGroup"
        case "overlay-subrole": overlay.subroleName = nil
        case "overlay-scene-id": overlay.id = "SceneWindow"
        case "overlay-parent": overlay.parentNode = fixture.window
        case "overlay-pid": overlay.pid = 999
        case "overlay-main": overlay.mainValue = true
        case "overlay-focus": overlay.focusValue = true
        case "overlay-unknown-main": overlay.mainValue = nil
        case "overlay-unknown-focus": overlay.focusValue = nil
        case "overlay-links": overlay.linkedNodes = [fixture.window]
        case "overlay-extra-child": overlay.childrenNodes.append(NavigatorNode(role: "AXTextField"))
        case "button-role": button.roleName = "AXTextField"
        case "button-title": button.title = "Continue"
        case "button-parent": button.parentNode = fixture.window
        case "button-pid": button.pid = 999
        case "button-window": button.owner = fixture.window
        case "button-child": button.childrenNodes = [NavigatorNode(role: "AXTextField")]
        case "button-links": button.linkedNodes = [fixture.window]
        case "duplicate-overlay": fixture.root.directWindowNodes?.append(overlay)
        case "extra-scene": fixture.root.directWindowNodes?.append(fixture.window.clone())
        case "about-dialog": overlay.childrenNodes = (0..<8).map { _ in NavigatorNode(role: "AXStaticText") }
        case "button-link-error": button.failLinkRead = true
        default: overlay.failLinkRead = true
        }
        #expect(throws: (any Error).self) {
            _ = try fixture.navigator().uniqueRootWindow(process: fixture.process, deadline: .millisecondsFromNow(1_000))
        }
    }

    @Test(arguments: ["scene", "button", "overlay", "disappeared", "title"])
    func sharingAffordanceMustRemainStableDuringProof(change: String) throws {
        let fixture = NavigatorFixture()
        let (overlay, button) = fixture.addSharingAffordance()
        fixture.root.onWindowRead = { count in
            guard count == 2 else { return }
            switch change {
            case "scene": fixture.root.directWindowNodes = [fixture.window.clone(), overlay]
            case "button": overlay.childrenNodes = [button.clone()]
            case "overlay": fixture.root.directWindowNodes = [fixture.window, overlay.clone()]
            case "disappeared": fixture.root.directWindowNodes = [fixture.window]
            default: button.title = "Continue"
            }
        }
        #expect(throws: (any Error).self) {
            _ = try fixture.navigator().uniqueRootWindow(process: fixture.process, deadline: .millisecondsFromNow(1_000))
        }
    }

    @Test func defaultTraversalFollowsLinks() throws {
        let fixture = NavigatorFixture()
        fixture.transcript.childrenNodes = []
        fixture.transcript.linkedNodes = [fixture.message]
        let route = try fixture.navigator().captureRoute(process: fixture.process, isTargetEligible: fixture.eligible,
                                                         deadline: .millisecondsFromNow(1_000))
        #expect(route.selected.sameIdentity(as: fixture.message))
        #expect(fixture.transcript.linkReads > 0)
    }

    @Test func childrenOnlyNeverReadsLinks() throws {
        let fixture = NavigatorFixture()
        fixture.transcript.childrenNodes = []
        fixture.transcript.linkedNodes = [fixture.message]
        fixture.transcript.failLinkRead = true
        let matches = try fixture.navigator().collect(from: fixture.window, window: fixture.window,
                                                       traversalPolicy: .childrenOnly, deadline: .millisecondsFromNow(1_000)) { _, _, _ in true }
        #expect(matches.count == 2)
        #expect(fixture.window.linkReads == 0)
        #expect(fixture.transcript.linkReads == 0)
        #expect(fixture.message.linkReads == 0)
    }

    @Test(arguments: [MessagesAXNavigator.TraversalPolicy.childrenAndLinks, .childrenOnly])
    func traversalDeduplicatesCycles(policy: MessagesAXNavigator.TraversalPolicy) throws {
        let fixture = NavigatorFixture()
        fixture.message.childrenNodes = [fixture.transcript]
        fixture.message.linkedNodes = [fixture.window, fixture.transcript]
        let matches = try fixture.navigator().collect(from: fixture.window, window: fixture.window,
                                                       traversalPolicy: policy, deadline: .millisecondsFromNow(1_000)) { _, _, _ in true }
        #expect(matches.count == 3)
    }

    @Test(arguments: ["nodes", "depth", "children"], [MessagesAXNavigator.TraversalPolicy.childrenAndLinks, .childrenOnly])
    func traversalBoundsFailClosed(_ limit: String, policy: MessagesAXNavigator.TraversalPolicy) throws {
        let fixture = NavigatorFixture()
        if limit == "children" {
            fixture.transcript.childrenNodes.append(NavigatorNode(role: "AXGroup"))
        }
        let navigator = fixture.navigator(maxTraversalNodes: limit == "nodes" ? 2 : 32,
                                          maxTraversalDepth: limit == "depth" ? 1 : 8,
                                          maxChildren: limit == "children" ? 1 : 8)
        #expect(throws: MessagesAXNavigationError.traversalLimit) {
            _ = try navigator.collect(from: fixture.window, traversalPolicy: policy,
                                      deadline: .millisecondsFromNow(1_000)) { _, _, _ in true }
        }
    }

    @Test func defaultTraversalBoundsCombinedRelationships() throws {
        let fixture = NavigatorFixture()
        fixture.transcript.linkedNodes = [fixture.message]
        #expect(throws: MessagesAXNavigationError.traversalLimit) {
            _ = try fixture.navigator(maxChildren: 1).collect(from: fixture.window,
                                                              deadline: .millisecondsFromNow(1_000)) { _, _, _ in true }
        }
    }

    @Test(arguments: [MessagesAXNavigator.TraversalPolicy.childrenAndLinks, .childrenOnly])
    func deadlineStopsTraversal(policy: MessagesAXNavigator.TraversalPolicy) throws {
        let fixture = NavigatorFixture()
        #expect(throws: MessagesAXNavigationError.deadlineExpired) {
            _ = try fixture.navigator().collect(from: fixture.window, traversalPolicy: policy,
                                                deadline: WorkerDeadline(uptimeNanoseconds: 0)) { _, _, _ in true }
        }
    }

    @Test(arguments: [MessagesAXNavigator.TraversalPolicy.childrenAndLinks, .childrenOnly])
    func traversalEnforcesMatchingWindow(policy: MessagesAXNavigator.TraversalPolicy) throws {
        let fixture = NavigatorFixture()
        let foreign = NavigatorNode(role: "AXWindow")
        fixture.message.owner = foreign
        #expect(throws: MessagesAXRouteDrift.self) {
            _ = try fixture.navigator().collect(from: fixture.window, window: fixture.window,
                                                traversalPolicy: policy, deadline: .millisecondsFromNow(1_000)) { _, _, _ in true }
        }
        fixture.message.owner = nil
        #expect(throws: MessagesAXNavigationError.unknownAXValue) {
            _ = try fixture.navigator().collect(from: fixture.window, window: fixture.window,
                                                traversalPolicy: policy, deadline: .millisecondsFromNow(1_000)) { _, _, _ in true }
        }
    }

    @Test func retainedRouteRediscoveryDoesNotRequireSelectionToRemainTrue() throws {
        let fixture = NavigatorFixture()
        let navigator = fixture.navigator()
        let route = try navigator.captureRoute(process: fixture.process, isTargetEligible: fixture.eligible,
                                               deadline: .millisecondsFromNow(1_000))
        fixture.message.isSelected = false

        let discovery = try navigator.retainedRouteDiscovery(process: fixture.process, originalRoute: route,
                                                             isTargetEligible: fixture.eligible,
                                                             deadline: .millisecondsFromNow(1_000))

        guard case .available(let retained) = discovery else {
            Issue.record("retained route was unavailable")
            return
        }
        #expect(retained.selected.sameIdentity(as: fixture.message))
    }
}

private final class NavigatorFixture: MessagesAXProcessDriving {
    var processIdentity = MessagesAXProcessIdentity(pid: 123, bundleURL: URL(fileURLWithPath: "/Applications/Messages.app"),
                                                    launchDate: Date(timeIntervalSince1970: 1_000))
    var root = NavigatorNode(role: "AXApplication")
    var window = NavigatorNode(role: "AXWindow")
    var transcript = NavigatorNode(role: "AXCollection", identifier: "TranscriptCollectionView")
    var message = NavigatorNode(role: "AXGroup", selected: true, eligible: true)

    init() {
        root.pid = processIdentity.pid
        window.pid = processIdentity.pid
        transcript.pid = processIdentity.pid
        message.pid = processIdentity.pid
        transcript.owner = window
        message.owner = window
        root.childrenNodes = [window]
        root.directWindowNodes = [window]
        window.childrenNodes = [transcript]
        transcript.childrenNodes = [message]
    }

    func addSharingAffordance(reversed: Bool = false) -> (NavigatorNode, NavigatorNode) {
        window.id = "SceneWindow"
        window.subroleName = "AXStandardWindow"
        window.parentNode = root
        let overlay = NavigatorNode(role: "AXWindow")
        overlay.subroleName = "AXDialog"
        overlay.parentNode = root
        overlay.mainValue = false
        overlay.focusValue = false
        let button = NavigatorNode(role: "AXButton")
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
        (element as? NavigatorNode)?.eligible == true
    }

    func checkAccessibilityTrusted(prompt: Bool) -> Bool { true }
    func openMessages(url: URL, deadline: WorkerDeadline) throws -> MessagesAXProcess { process }
    func canonicalMessagesProcess(deadline: WorkerDeadline) throws -> MessagesAXProcess { process }
    func messagesProcessIsFrontmost(_ process: MessagesAXProcess, deadline: WorkerDeadline) throws -> Bool { true }
    func focusedElement(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { nil }
}

private final class NavigatorNode: MessagesAXElement {
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

    func clone() -> NavigatorNode {
        let clone = NavigatorNode(role: roleName, identifier: id, selected: isSelected, eligible: eligible)
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
        (other as? NavigatorNode)?.identity == identity
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
    func enabled(deadline: WorkerDeadline) throws -> Bool? { nil }
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
    func actions(deadline: WorkerDeadline) throws -> [String] { [] }
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
    func performAction(named name: String, deadline: WorkerDeadline) throws {}
}
