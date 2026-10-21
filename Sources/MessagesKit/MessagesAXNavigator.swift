import Foundation
import AppleKit

struct MessagesAXNavigator {
    typealias TargetEligibility = (any MessagesAXElement, WorkerDeadline) throws -> Bool

    enum TraversalPolicy {
        case childrenAndLinks
        case childrenOnly
    }

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
        try captureRouteSnapshot(process: process, isTargetEligible: isTargetEligible,
                                 expectedWindow: nil, expectedTranscript: nil, deadline: deadline).route()
    }

    func captureWindowTranscript(process: MessagesAXProcess,
                                 deadline: WorkerDeadline) throws -> (window: any MessagesAXElement, transcript: any MessagesAXElement) {
        let window = try uniqueRootWindow(process: process, deadline: deadline)
        let transcripts = try collect(from: window, window: window, deadline: deadline) { _, role, identifier in
            (role == "AXGroup" || role == "AXCollection") && identifier == "TranscriptCollectionView"
        }
        guard transcripts.count == 1, let transcript = transcripts.first else {
            throw MessagesAXNavigationError.targetDrift
        }
        return (window, transcript)
    }

    func captureInitialRoute(process: MessagesAXProcess, isTargetEligible: TargetEligibility,
                             deadline: WorkerDeadline) throws -> MessagesAXRoute {
        let started = readinessNow()
        let cap: UInt64 = 750_000_000
        let localDeadline = WorkerDeadline.millisecondsFromNow(750)
        let readDeadline = deadline.remainingNanoseconds <= localDeadline.remainingNanoseconds ? deadline : localDeadline
        var expectedWindow: (any MessagesAXElement)?
        var expectedTranscript: (any MessagesAXElement)?
        func remainingLocalBudget() throws -> UInt64 {
            try checkMessagesAXDeadline(deadline)
            if readDeadline.expired { throw MessagesAXNavigationError.targetDrift }
            let now = readinessNow()
            guard now >= started, now - started < cap else { throw MessagesAXNavigationError.targetDrift }
            return cap - (now - started)
        }
        for attempt in 0...15 {
            try checkMessagesAXDeadline(deadline)
            do {
                let snapshot = try captureRouteSnapshot(process: process, isTargetEligible: isTargetEligible,
                                                        expectedWindow: expectedWindow,
                                                        expectedTranscript: expectedTranscript,
                                                        deadline: readDeadline)
                _ = try remainingLocalBudget()
                switch snapshot {
                case .available(let route):
                    try checkMessagesAXDeadline(deadline)
                    return route
                case .zeroSelected(let window, let transcript):
                    expectedWindow = window
                    expectedTranscript = transcript
                }
            } catch MessagesAXNavigationError.deadlineExpired {
                try checkMessagesAXDeadline(deadline)
                throw MessagesAXNavigationError.targetDrift
            }
            guard attempt < 15 else { throw MessagesAXNavigationError.targetDrift }
            let pause = min(50_000_000, try remainingLocalBudget(), readDeadline.remainingNanoseconds)
            guard pause > 0 else { throw MessagesAXNavigationError.targetDrift }
            readinessPause(pause)
            try checkMessagesAXDeadline(deadline)
        }
        throw MessagesAXNavigationError.targetDrift
    }

    private enum CaptureRouteSnapshot {
        case available(MessagesAXRoute)
        case zeroSelected(any MessagesAXElement, any MessagesAXElement)

        func route() throws -> MessagesAXRoute {
            switch self {
            case .available(let route): return route
            case .zeroSelected: throw MessagesAXNavigationError.targetDrift
            }
        }
    }

    private func captureRouteSnapshot(process: MessagesAXProcess, isTargetEligible: TargetEligibility,
                                      expectedWindow: (any MessagesAXElement)?,
                                      expectedTranscript: (any MessagesAXElement)?,
                                      deadline: WorkerDeadline) throws -> CaptureRouteSnapshot {
        let (rootWindow, transcript) = try captureWindowTranscript(process: process, deadline: deadline)
        if let expectedWindow, !rootWindow.sameIdentity(as: expectedWindow) {
            throw MessagesAXRouteDrift(.windowMismatch)
        }
        if let expectedTranscript, !transcript.sameIdentity(as: expectedTranscript) {
            throw MessagesAXNavigationError.targetDrift
        }
        let messages = try collect(from: transcript, window: rootWindow, deadline: deadline) { element, _, _ in
            guard try isTargetEligible(element, deadline) else { return false }
            guard let selected = try element.selected(deadline: deadline) else {
                throw MessagesAXNavigationError.unknownAXValue
            }
            return selected
        }
        guard messages.count <= 1 else {
            throw MessagesAXNavigationError.ambiguousSelectedMessage
        }
        guard let message = messages.first else { return .zeroSelected(rootWindow, transcript) }
        return .available(MessagesAXRoute(process: process, window: rootWindow, transcript: transcript, selected: message))
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
        let windows = try conversationWindows(process: process, deadline: deadline)
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

    // Window sharing adds a non-conversation AXDialog beside SceneWindow.
    // Recognize only its observed, inert structure; other dialogs and unknown
    // attributes remain ambiguous. Never act on the sharing control itself.
    func conversationWindows(process: MessagesAXProcess, deadline: WorkerDeadline) throws -> [any MessagesAXElement] {
        try checkProcess(process, deadline: deadline)
        let windows = try process.root.directWindows(limit: maxChildren, deadline: deadline)
        guard windows.count > 1 else { return windows }
        let first = try sharingWindowSnapshot(windows, process: process, deadline: deadline)
        let current = try process.root.directWindows(limit: maxChildren, deadline: deadline)
        let second = try sharingWindowSnapshot(current, process: process, deadline: deadline)
        guard first.scene.sameIdentity(as: second.scene),
              first.overlay.sameIdentity(as: second.overlay),
              first.button.sameIdentity(as: second.button),
              first.relationships == second.relationships else {
            throw MessagesAXRouteDrift(.windowMismatch)
        }
        try checkProcess(process, deadline: deadline)
        return [first.scene]
    }

    private func sharingWindowSnapshot(_ windows: [any MessagesAXElement], process: MessagesAXProcess,
                                       deadline: WorkerDeadline) throws -> (scene: any MessagesAXElement,
                                                                          overlay: any MessagesAXElement,
                                                                          button: any MessagesAXElement,
                                                                          relationships: [MessagesAXRelationshipCount]) {
        guard windows.count == 2, !windows[0].sameIdentity(as: windows[1]) else {
            throw MessagesAXRouteDrift(.windowMismatch)
        }
        for window in windows {
            guard try window.role(deadline: deadline) == "AXWindow",
                  try window.processIdentifier(deadline: deadline) == process.identity.pid,
                  let parent = try window.parent(deadline: deadline), parent.sameIdentity(as: process.root) else {
                throw MessagesAXRouteDrift(.windowMismatch)
            }
        }
        let sceneIndex: Int
        if try windows[0].identifier(deadline: deadline) == "SceneWindow" { sceneIndex = 0 }
        else { sceneIndex = 1 }
        let scene = windows[sceneIndex]
        let overlay = windows[1 - sceneIndex]
        guard try scene.identifier(deadline: deadline) == "SceneWindow",
              try scene.subrole(deadline: deadline) == "AXStandardWindow",
              try overlay.identifier(deadline: deadline) != "SceneWindow",
              try overlay.subrole(deadline: deadline) == "AXDialog",
              try overlay.mainWindow(deadline: deadline) == false,
              try overlay.focused(deadline: deadline) == false else {
            throw MessagesAXRouteDrift(.windowMismatch)
        }
        let children = try overlay.children(limit: maxChildren, deadline: deadline)
        guard children.count == 1, let button = children.first,
              try button.role(deadline: deadline) == "AXButton",
              try button.axTitle(deadline: deadline) == "WindowSharingSessionButton",
              try button.processIdentifier(deadline: deadline) == process.identity.pid,
              let parent = try button.parent(deadline: deadline), parent.sameIdentity(as: overlay),
              try button.window(deadline: deadline) == nil else {
            throw MessagesAXRouteDrift(.windowMismatch)
        }
        let overlayLinks = try overlay.relationshipCount(.linkedElements, limit: maxChildren, deadline: deadline)
        let buttonChildren = try button.relationshipCount(.children, limit: maxChildren, deadline: deadline)
        let buttonLinks = try button.relationshipCount(.linkedElements, limit: maxChildren, deadline: deadline)
        // The system sharing affordance reports unsupported links and no-value
        // leaf children on current macOS. These explicit states are part of the
        // recognized shape, not claims that an array was successfully read.
        // Require the same states in both complete snapshots; reject other
        // absence states, positive counts, errors and every unknown adapter.
        guard (overlayLinks == .unsupported || overlayLinks == .available(0)),
              (buttonChildren == .noValue || buttonChildren == .available(0)),
              (buttonLinks == .unsupported || buttonLinks == .available(0)) else {
            throw MessagesAXRouteDrift(.windowMismatch)
        }
        try checkMessagesAXDeadline(deadline)
        return (scene, overlay, button, [overlayLinks, buttonChildren, buttonLinks])
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
                 traversalPolicy: TraversalPolicy = .childrenAndLinks,
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
            var relationships = children
            if traversalPolicy == .childrenAndLinks {
                let remaining = maxChildren - children.count
                let linked = try next.linkedElements(limit: remaining, deadline: deadline)
                try checkMessagesAXDeadline(deadline)
                guard linked.count <= remaining else { throw MessagesAXNavigationError.traversalLimit }
                relationships += linked
            }
            for candidate in relationships {
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
