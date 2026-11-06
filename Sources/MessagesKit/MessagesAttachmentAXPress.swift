import AppleKit
import Foundation

/// Performs one native press on a retained exact-part route. This adapter does
/// not verify download completion and must run inside the journaled worker.
struct MessagesAttachmentAXPress {
    enum Failure: Error, Equatable { case accessibilityDenied, pressUnavailable, observationRefused }
    let driver: any MessagesAXProcessDriving
    let isTargetEligible: MessagesAXNavigator.TargetEligibility

    func perform(messageGUID: String, nativePartIndex: Int, nativePartGUID: String?,
                 deadline: WorkerDeadline, diagnostic: MessagesAttachmentDiagnostic? = nil, validateTarget: () throws -> MessagesAttachmentRetrievalState.Outcome) throws {
        diagnostic?.record(.trust)
        try checkMessagesAXDeadline(deadline)
        let url = try NativeMessagesURL.message(messageGUID: messageGUID,
            nativePartIndex: nativePartIndex, nativePartGUID: nativePartGUID)
        guard driver.checkAccessibilityTrusted(prompt: false) else { throw Failure.accessibilityDenied }
        diagnostic?.record(.revalidation)
        guard try needsPress(validateTarget()) else { return }
        try checkMessagesAXDeadline(deadline)
        diagnostic?.record(.navigation)
        let process = try driver.openMessages(url: url, deadline: deadline)
        let navigator = MessagesAXNavigator(driver: driver)
        diagnostic?.record(.route)
        let route = try navigator.captureInitialRoute(process: process, isTargetEligible: isTargetEligible, deadline: deadline)
        diagnostic?.record(.revalidation)
        guard try needsPress(validateTarget()) else { return }
        diagnostic?.record(.route)
        try navigator.revalidate(route, isTargetEligible: isTargetEligible, deadline: deadline)
        diagnostic?.record(.frontmost)
        guard try driver.messagesProcessIsFrontmost(process, deadline: deadline) else { throw MessagesAXNavigationError.targetDrift }
        diagnostic?.record(.enabled)
        guard try route.selected.enabled(deadline: deadline) == true else {
            throw Failure.pressUnavailable
        }
        diagnostic?.record(.actions)
        guard try route.selected.actions(deadline: deadline).filter({ $0 == "AXPress" }).count == 1 else {
            throw Failure.pressUnavailable
        }
        try checkMessagesAXDeadline(deadline)
        diagnostic?.record(.press)
        try route.selected.performAction(named: "AXPress", deadline: deadline)
        try checkMessagesAXDeadline(deadline)
        diagnostic?.record(.postPressProcess)
        try navigator.checkProcess(process, deadline: deadline)
    }

    private func needsPress(_ outcome: MessagesAttachmentRetrievalState.Outcome) throws -> Bool {
        switch outcome {
        case .downloaded: return false
        case .pending, .missing: return true
        case .failed, .unavailable: throw Failure.observationRefused
        }
    }
}
