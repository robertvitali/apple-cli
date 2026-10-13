import Foundation
import AppleKit

struct MessagesAXNavigator {
    typealias TargetEligibility = (any MessagesAXElement, WorkerDeadline) throws -> Bool

    let driver: any MessagesAXProcessDriving
    let maxTraversalNodes: Int
    let maxTraversalDepth: Int
    let maxChildren: Int
    let readinessNow: () -> UInt64
    let readinessPause: (UInt64) -> Void

    init(driver: any MessagesAXProcessDriving, maxTraversalNodes: Int = 2_048, maxTraversalDepth: Int = 32,
         maxChildren: Int = 256, readinessNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         readinessPause: @escaping (UInt64) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) }) {
        self.driver = driver
        self.maxTraversalNodes = maxTraversalNodes
        self.maxTraversalDepth = maxTraversalDepth
        self.maxChildren = maxChildren
        self.readinessNow = readinessNow
        self.readinessPause = readinessPause
    }

    func captureRoute(process: MessagesAXProcess, isTargetEligible: TargetEligibility,
                      deadline: WorkerDeadline) throws -> MessagesAXRoute {
        let rootWindow = try uniqueRootWindow(process: process, deadline: deadline)
        let transcripts = try collect(from: rootWindow, window: rootWindow, deadline: deadline) { _, role, identifier in
            (role == "AXGroup" || role == "AXCollection") && identifier == "TranscriptCollectionView"
        }
        guard transcripts.count == 1, let transcript = transcripts.first else {
            throw MessagesAXNavigationError.targetDrift
        }
        let messages = try collect(from: transcript, window: rootWindow, deadline: deadline) { element, _, _ in
            guard try isTargetEligible(element, deadline) else { return false }
            guard let selected = try element.selected(deadline: deadline) else {
                throw MessagesAXNavigationError.unknownAXValue
            }
            return selected
        }
        guard messages.count == 1 else {
            throw messages.isEmpty ? MessagesAXNavigationError.targetDrift : .ambiguousSelectedMessage
        }
        return MessagesAXRoute(process: process, window: rootWindow, transcript: transcript, selected: messages[0])
    }

    func revalidate(_ route: MessagesAXRoute, isTargetEligible: TargetEligibility,
                    deadline: WorkerDeadline) throws {
        let current = try captureRoute(process: route.process, isTargetEligible: isTargetEligible, deadline: deadline)
        guard route.window.sameIdentity(as: current.window),
              route.transcript.sameIdentity(as: current.transcript),
              route.selected.sameIdentity(as: current.selected) else {
            throw MessagesAXNavigationError.targetDrift
        }
        try checkMessagesAXDeadline(deadline)
    }

    func uniqueCurrentWindow(_ route: MessagesAXRoute, deadline: WorkerDeadline) throws -> any MessagesAXElement {
        let window = try uniqueRootWindow(process: route.process, deadline: deadline)
        guard window.sameIdentity(as: route.window) else {
            throw MessagesAXRouteDrift(.windowMismatch)
        }
        return window
    }

    func uniqueRootWindow(process: MessagesAXProcess, deadline: WorkerDeadline) throws -> any MessagesAXElement {
        try checkProcess(process, deadline: deadline)
        let windows = try process.root.directWindows(limit: maxChildren, deadline: deadline)
        guard windows.count == 1, let window = windows.first else {
            throw MessagesAXRouteDrift(.windowMismatch)
        }
        guard try window.role(deadline: deadline) == "AXWindow",
              try window.processIdentifier(deadline: deadline) == process.identity.pid else {
            throw MessagesAXRouteDrift(.windowMismatch)
        }
        try checkProcess(process, deadline: deadline)
        return window
    }

    func checkProcess(_ expected: MessagesAXProcess, deadline: WorkerDeadline) throws {
        try checkMessagesAXDeadline(deadline)
        let current = try driver.canonicalMessagesProcess(deadline: deadline)
        guard current.identity == expected.identity, expected.root.sameIdentity(as: current.root) else {
            throw MessagesAXNavigationError.targetDrift
        }
        try checkMessagesAXDeadline(deadline)
    }

    func retainedRouteDiscovery(process: MessagesAXProcess, originalRoute: MessagesAXRoute,
                                isTargetEligible: TargetEligibility,
                                deadline: WorkerDeadline) throws -> MessagesAXRetainedRouteDiscovery {
        try checkProcess(process, deadline: deadline)
        let window = try uniqueRootWindow(process: process, deadline: deadline)
        guard window.sameIdentity(as: originalRoute.window) else { throw MessagesAXRouteDrift(.windowMismatch) }
        let transcripts = try collect(from: window, window: window, deadline: deadline) { _, role, identifier in
            (role == "AXGroup" || role == "AXCollection") && identifier == "TranscriptCollectionView"
        }
        guard !transcripts.isEmpty else { return .unavailable(.missingTranscript) }
        guard transcripts.count == 1, let transcript = transcripts.first else {
            throw MessagesAXRouteDrift(.relationshipCountChanged)
        }
        guard transcript.sameIdentity(as: originalRoute.transcript) else {
            throw MessagesAXRouteDrift(.replacedTranscript)
        }
        let messages = try collect(from: transcript, window: window, deadline: deadline) { element, _, _ in
            element.sameIdentity(as: originalRoute.selected)
        }
        guard !messages.isEmpty else { return .unavailable(.missingRetainedTarget) }
        guard messages.count == 1 else { throw MessagesAXRouteDrift(.relationshipCountChanged) }
        guard try isTargetEligible(messages[0], deadline) else {
            throw MessagesAXRouteDrift(.retainedTargetActionMissing)
        }
        return .available(MessagesAXRoute(process: process, window: window,
                                          transcript: transcript, selected: messages[0]))
    }

    func collect(from root: any MessagesAXElement, window: (any MessagesAXElement)? = nil,
                 deadline: WorkerDeadline,
                 matching predicate: (any MessagesAXElement, String, String?) throws -> Bool) throws -> [any MessagesAXElement] {
        guard maxTraversalNodes > 0, maxTraversalDepth >= 0, maxChildren >= 0 else {
            throw MessagesAXNavigationError.traversalLimit
        }
        var discovered: [(element: any MessagesAXElement, depth: Int)] = [(root, 0)]
        var cursor = 0
        var matches: [any MessagesAXElement] = []
        while cursor < discovered.count {
            try checkMessagesAXDeadline(deadline)
            let (next, depth) = discovered[cursor]
            cursor += 1
            let role = try next.role(deadline: deadline)
            let identifier = try next.identifier(deadline: deadline)
            guard role.utf8.count <= 128, identifier.map({ $0.utf8.count <= 2048 }) ?? true else {
                throw MessagesAXNavigationError.unknownAXValue
            }
            if try predicate(next, role, identifier) {
                if let window {
                    guard let owner = try next.window(deadline: deadline) else {
                        throw MessagesAXNavigationError.unknownAXValue
                    }
                    try checkMessagesAXDeadline(deadline)
                    guard owner.sameIdentity(as: window) else { throw MessagesAXRouteDrift(.windowMismatch) }
                }
                matches.append(next)
            }
            try checkMessagesAXDeadline(deadline)
            let children = try next.children(limit: maxChildren, deadline: deadline)
            try checkMessagesAXDeadline(deadline)
            guard children.count <= maxChildren else { throw MessagesAXNavigationError.traversalLimit }
            let remaining = maxChildren - children.count
            let linked = try next.linkedElements(limit: remaining, deadline: deadline)
            try checkMessagesAXDeadline(deadline)
            guard linked.count <= remaining else { throw MessagesAXNavigationError.traversalLimit }
            for candidate in children + linked {
                let known = try discovered.contains { entry in
                    try checkMessagesAXDeadline(deadline)
                    return entry.element.sameIdentity(as: candidate)
                }
                if known { continue }
                guard discovered.count < maxTraversalNodes, depth < maxTraversalDepth else {
                    throw MessagesAXNavigationError.traversalLimit
                }
                discovered.append((candidate, depth + 1))
            }
        }
        try checkMessagesAXDeadline(deadline)
        return matches
    }
}
