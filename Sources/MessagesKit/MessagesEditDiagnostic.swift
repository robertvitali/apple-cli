import Foundation

/// Per-operation synchronous diagnostics. Never retains target values or Error objects.
final class MessagesEditDiagnostic {
    enum Stage: String, CaseIterable {
        case nativeAction = "native-action", trust, titles, process, inactive
        case navigation, route, anchor, openEditor = "open-editor"
        case captureEditor = "capture-editor", replacement, confirmation, completion, persistence
    }
    private(set) var stage: Stage = .nativeAction
    func record(_ stage: Stage) { self.stage = stage }
    func detail(_ error: Error) -> String {
        let category: String
        if let navigation = error as? MessagesAXNavigationError { category = navigation.rawValue }
        else if error is MessagesAXRouteDrift { category = "route-drift" }
        else if error is CancellationError { category = "cancelled" }
        else { category = "other" }
        return "edit-unverified:\(stage.rawValue):\(category)"
    }
}
