import AppleKit
import Foundation

/// Runs only inside a journaled worker with an already selected exact route.
/// Each native mutation is attempted once. Errors preserve uncertainty and do
/// not trigger retry, cancellation, or cleanup of a potentially user-owned UI.
struct MessagesEditAXAction {
    let navigator: MessagesAXNavigator
    let titles: MessagesEditActionTitles
    var pause: (UInt64) throws -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) }

    func perform(route: MessagesAXRoute, expectedText: String, replacement: String,
                 deadline: WorkerDeadline, validateTarget: () throws -> Void, diagnostic: MessagesEditDiagnostic? = nil) throws {
        guard MessagesEditEligibility.supportsEditorText(expectedText), !replacement.isEmpty, replacement.utf8.count <= 4096, !replacement.utf8.contains(0),
              !replacement.utf8.elementsEqual(expectedText.utf8) else { throw MessagesAXNavigationError.targetDrift }
        let ownership = try MessagesEditEditorOwnership(navigator: navigator, titles: titles)
        func checkpoint() throws {
            try Task.checkCancellation()
            try checkMessagesAXDeadline(deadline)
        }
        func validateRoute() throws {
            try checkpoint()
            try navigator.revalidate(route, isTargetEligible: { candidate, bounded in
                // The retained message may lose its Edit action while its editor
                // is open. Still include every other Edit-capable candidate so
                // a competing selection cannot disappear from the uniqueness check.
                let actions = try candidate.actions(deadline: bounded).filter {
                    MessagesReactionAXAutomation.matchesAction($0, title: titles.edit)
                }
                guard actions.count <= 1 else { throw MessagesAXNavigationError.unknownAXValue }
                return candidate.sameIdentity(as: route.selected) || actions.count == 1
            }, deadline: deadline)
            guard try navigator.driver.messagesProcessIsFrontmost(route.process, deadline: deadline) else {
                throw MessagesAXNavigationError.targetDrift
            }
        }
        diagnostic?.record(.route)
        try validateRoute()
        try ownership.requireInactive(route: route, deadline: deadline)
        try validateTarget()
        diagnostic?.record(.route)
        try validateRoute()
        try ownership.requireInactive(route: route, deadline: deadline)
        let actions = try route.selected.actions(deadline: deadline).filter {
            MessagesReactionAXAutomation.matchesAction($0, title: titles.edit)
        }
        guard actions.count == 1, let action = actions.first,
              try route.selected.enabled(deadline: deadline) == true else { throw MessagesAXNavigationError.targetDrift }
        diagnostic?.record(.anchor)
        let anchor = try ownership.retainAnchor(route: route, deadline: deadline)
        try checkpoint()
        diagnostic?.record(.openEditor)
        try route.selected.performAction(named: action, deadline: deadline)
        diagnostic?.record(.captureEditor)
        let token = try awaitObservation(deadline: deadline) {
            return try ownership.capture(route: route, anchor: anchor, expectedText: expectedText, deadline: deadline,
                allowPendingAppearance: true)
        }
        try validateTarget()
        try ownership.revalidate(token, route: route, expectedText: expectedText, deadline: deadline)
        guard try token.confirm.enabled(deadline: deadline) == false else {
            throw MessagesAXNavigationError.targetDrift
        }
        try checkpoint()
        diagnostic?.record(.replacement)
        try token.field.setValue(replacement, deadline: deadline)
        try awaitObservation(deadline: deadline) {
            try ownership.revalidate(token, route: route, expectedText: replacement, deadline: deadline)
            guard try token.confirm.enabled(deadline: deadline) == true else {
                throw MessagesEditObservationReadiness.notReady
            }
        }
        try validateTarget()
        try ownership.revalidate(token, route: route, expectedText: replacement, deadline: deadline)
        guard try token.confirm.enabled(deadline: deadline) == true else {
            throw MessagesAXNavigationError.targetDrift
        }
        try checkpoint()
        diagnostic?.record(.confirmation)
        try token.confirm.performAction(named: "AXPress", deadline: deadline)
        diagnostic?.record(.completion)
        try awaitObservation(deadline: deadline) {
            try ownership.validateAnchor(anchor, route: route, deadline: deadline)
            let remaining = try navigator.collect(from: route.window, window: route.window,
                traversalPolicy: .childrenOnly, deadline: deadline) { node, _, _ in
                node.sameIdentity(as: token.field) || node.sameIdentity(as: token.confirm)
            }
            if !remaining.isEmpty {
                try ownership.revalidate(token, route: route, expectedText: replacement, deadline: deadline)
                throw MessagesEditObservationReadiness.notReady
            }
            try ownership.requireInactive(route: route, deadline: deadline)
        }
        try checkpoint()
    }

    /// Retry only explicitly incomplete UI transitions, never an identity,
    /// ownership, type, transport or cancellation failure. No action is retried.
    private func awaitObservation<T>(deadline: WorkerDeadline, read: () throws -> T) throws -> T {
        for attempt in 0...15 {
            try Task.checkCancellation()
            try checkMessagesAXDeadline(deadline)
            do { return try read() }
            catch MessagesEditObservationReadiness.notReady {
                try checkMessagesAXDeadline(deadline)
                if attempt == 15 { throw MessagesAXNavigationError.targetDrift }
                try pause(min(50_000_000, deadline.remainingNanoseconds))
            }
        }
        throw MessagesAXNavigationError.deadlineExpired
    }
}
