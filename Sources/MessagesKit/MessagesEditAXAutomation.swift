import AppleKit
import Foundation

/// Resolves the exact native part only after protecting the current draft.
/// Must run inside the serialized, journaled worker, never directly in a command.
struct MessagesEditAXAutomation {
    let driver: any MessagesAXProcessDriving
    var resolveTitles: (WorkerDeadline) throws -> MessagesEditActionTitles = {
        try MessagesEditActionTitles.live(deadline: $0)
    }

    func perform(messageGUID: String, nativePartIndex: Int, expectedText: String,
                 replacement: String, deadline: WorkerDeadline,
                 validateTarget: () throws -> Void, diagnostic: MessagesEditDiagnostic? = nil) throws {
        guard MessagesEditEligibility.supportsEditorText(expectedText) else {
            throw MessagesAXNavigationError.targetDrift
        }
        try Task.checkCancellation()
        try checkMessagesAXDeadline(deadline)
        let url = try NativeMessagesURL.message(messageGUID: messageGUID,
            nativePartIndex: nativePartIndex, nativePartGUID: nil)
        diagnostic?.record(.trust)
        guard driver.checkAccessibilityTrusted(prompt: false) else { throw MessagesAXNavigationError.axFailure }
        diagnostic?.record(.titles)
        let titles = try resolveTitles(deadline)
        let navigator = MessagesAXNavigator(driver: driver)
        let ownership = try MessagesEditEditorOwnership(navigator: navigator, titles: titles)
        diagnostic?.record(.process)
        let initial = try driver.canonicalMessagesProcess(deadline: deadline)
        let window = try navigator.uniqueRootWindow(process: initial, deadline: deadline)
        diagnostic?.record(.inactive)
        try ownership.requireInactive(process: initial, window: window, deadline: deadline)
        try validateTarget()
        // The database check may take time; protect user drafts again directly
        // before navigation. No cancellation or clearing of an existing editor.
        diagnostic?.record(.inactive)
        try ownership.requireInactive(process: initial, window: window, deadline: deadline)
        try Task.checkCancellation()
        try checkMessagesAXDeadline(deadline)
        diagnostic?.record(.navigation)
        let process = try driver.openMessages(url: url, deadline: deadline)
        guard process.identity == initial.identity, process.root.sameIdentity(as: initial.root) else {
            throw MessagesAXNavigationError.targetDrift
        }
        diagnostic?.record(.route)
        let route = try navigator.captureInitialRoute(process: process, isTargetEligible: { node, bounded in
            let actions = try node.actions(deadline: bounded).filter {
                MessagesReactionAXAutomation.matchesAction($0, title: titles.edit)
            }
            guard actions.count <= 1 else { throw MessagesAXNavigationError.unknownAXValue }
            return actions.count == 1
        }, deadline: deadline)
        guard route.window.sameIdentity(as: window) else { throw MessagesAXNavigationError.targetDrift }
        try MessagesEditAXAction(navigator: navigator, titles: titles).perform(route: route,
            expectedText: expectedText, replacement: replacement, deadline: deadline, validateTarget: validateTarget, diagnostic: diagnostic)
    }
}
