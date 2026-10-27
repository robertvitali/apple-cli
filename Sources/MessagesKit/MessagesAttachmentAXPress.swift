import AppleKit
import Foundation

/// Performs one native press on a retained exact-part route. This adapter does
/// not verify download completion and must run inside the journaled worker.
struct MessagesAttachmentAXPress {
    enum Failure: Error, Equatable { case accessibilityDenied, pressUnavailable, observationRefused }
    let driver: any MessagesAXProcessDriving
    let isTargetEligible: MessagesAXNavigator.TargetEligibility

    func perform(messageGUID: String, nativePartIndex: Int, nativePartGUID: String?,
                 deadline: WorkerDeadline, validateTarget: () throws -> MessagesAttachmentRetrievalState.Outcome) throws {
        try checkMessagesAXDeadline(deadline)
        let url = try NativeMessagesURL.message(messageGUID: messageGUID,
            nativePartIndex: nativePartIndex, nativePartGUID: nativePartGUID)
        guard driver.checkAccessibilityTrusted(prompt: false) else { throw Failure.accessibilityDenied }
        guard try needsPress(validateTarget()) else { return }
        try checkMessagesAXDeadline(deadline)
        let process = try driver.openMessages(url: url, deadline: deadline)
        let navigator = MessagesAXNavigator(driver: driver)
        let route = try navigator.captureInitialRoute(process: process, isTargetEligible: isTargetEligible, deadline: deadline)
        guard try needsPress(validateTarget()) else { return }
        try navigator.revalidate(route, isTargetEligible: isTargetEligible, deadline: deadline)
        guard try driver.messagesProcessIsFrontmost(process, deadline: deadline) else { throw MessagesAXNavigationError.targetDrift }
        guard try route.selected.enabled(deadline: deadline) == true,
              try route.selected.actions(deadline: deadline).filter({ $0 == "AXPress" }).count == 1 else {
            throw Failure.pressUnavailable
        }
        try checkMessagesAXDeadline(deadline)
        try route.selected.performAction(named: "AXPress", deadline: deadline)
        try checkMessagesAXDeadline(deadline)
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
