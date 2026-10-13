import Foundation
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

    @Test(arguments: ["nodes", "depth", "children"])
    func traversalBoundsFailClosed(_ limit: String) throws {
        let fixture = NavigatorFixture()
        if limit == "children" {
            fixture.transcript.childrenNodes.append(NavigatorNode(role: "AXGroup"))
        }
        let navigator = fixture.navigator(maxTraversalNodes: limit == "nodes" ? 2 : 32,
                                          maxTraversalDepth: limit == "depth" ? 1 : 8,
                                          maxChildren: limit == "children" ? 1 : 8)

        #expect(throws: MessagesAXNavigationError.traversalLimit) {
            _ = try navigator.captureRoute(process: fixture.process, isTargetEligible: fixture.eligible,
                                           deadline: .millisecondsFromNow(1_000))
        }
    }

    @Test func deadlineStopsTraversal() throws {
        let fixture = NavigatorFixture()
        #expect(throws: MessagesAXNavigationError.deadlineExpired) {
            _ = try fixture.navigator().captureRoute(process: fixture.process, isTargetEligible: fixture.eligible,
                                                     deadline: WorkerDeadline(uptimeNanoseconds: 0))
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
    var isSelected: Bool?
    var eligible: Bool
    var pid: Int32 = 123
    weak var owner: (any MessagesAXElement)?
    var childrenNodes: [any MessagesAXElement] = []
    var linkedNodes: [any MessagesAXElement] = []
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
    func axTitle(deadline: WorkerDeadline) throws -> String? { nil }
    func subrole(deadline: WorkerDeadline) throws -> String? { nil }
    func enabled(deadline: WorkerDeadline) throws -> Bool? { nil }
    func selected(deadline: WorkerDeadline) throws -> Bool? { try checkMessagesAXDeadline(deadline); return isSelected }
    func window(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? {
        try checkMessagesAXDeadline(deadline)
        return roleName == "AXWindow" ? self : owner
    }
    func directWindows(limit: Int, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try checkMessagesAXDeadline(deadline)
        return directWindowNodes ?? childrenNodes.filter { (try? $0.role(deadline: deadline)) == "AXWindow" }
    }
    func parent(deadline: WorkerDeadline) throws -> (any MessagesAXElement)? { nil }
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
        return linkedNodes
    }
    func setValue(_ value: String, deadline: WorkerDeadline) throws {}
    func performAction(named name: String, deadline: WorkerDeadline) throws {}
}
