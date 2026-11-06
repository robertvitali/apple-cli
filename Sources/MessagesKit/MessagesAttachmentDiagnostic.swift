import Foundation
import AppleKit

/// Fixed diagnostics only; never retains target values or underlying errors.
final class MessagesAttachmentDiagnostic {
    enum Stage: String, CaseIterable {
        case initialRead = "initial-read", initialBinding = "initial-binding"
        case initialFiles = "initial-files", initialState = "initial-state"
        case titles, trust, eligibility, navigation, route, revalidation, frontmost
        case enabled, actions, press, postPressProcess = "post-press-process"
        case verificationRead = "verification-read", verificationBinding = "verification-binding"
        case verificationFiles = "verification-files", verificationState = "verification-state"
    }
    enum Category: String, CaseIterable {
        case deadline = "deadline-expired", targetDrift = "target-drift"
        case ambiguous = "ambiguous-selected-message", unknown = "unknown-ax-value"
        case traversal = "traversal-limit", axFailure = "ax-failure", routeDrift = "route-drift"
        case cancelled, other, accessibility = "accessibility-denied"
        case press = "press-unavailable", observation = "observation-refused"
        case membership = "membership-drift", incomplete = "incomplete-membership"
        case unavailable = "state-unavailable", failed = "state-failed"
    }
    private(set) var stage: Stage = .initialRead
    func record(_ stage: Stage) { self.stage = stage }

    // Successful nested observations restore the caller's stage. A throw retains
    // the innermost failing stage and propagates the original error unchanged.
    func at<T>(_ next: Stage, _ body: () throws -> T) rethrows -> T {
        let previous = stage
        stage = next
        let value = try body()
        stage = previous
        return value
    }

    func detail(_ error: any Error) -> String {
        let category: Category
        switch error {
        case let value as MessagesAXNavigationError:
            category = Category(rawValue: value.rawValue) ?? .other
        case let value as MessagesReactionAXError:
            switch value {
            case .deadlineExpired: category = .deadline
            case .targetDrift: category = .targetDrift
            case .ambiguousSelectedMessage: category = .ambiguous
            case .unknownAXValue: category = .unknown
            case .traversalLimit: category = .traversal
            case .axFailure: category = .axFailure
            default: category = .other
            }
        case is MessagesAXRouteDrift: category = .routeDrift
        case is CancellationError: category = .cancelled
        case WorkerProtocolError.deadlineExpired: category = .deadline
        case WorkerProtocolError.cancelled: category = .cancelled
        case MessagesAttachmentAXPress.Failure.accessibilityDenied: category = .accessibility
        case MessagesAttachmentAXPress.Failure.pressUnavailable: category = .press
        case MessagesAttachmentAXPress.Failure.observationRefused: category = .observation
        case MessagesAttachmentObservation.Failure.deadline: category = .deadline
        case MessagesAttachmentObservation.Failure.cancelled: category = .cancelled
        case MessagesAttachmentObservation.Failure.incompleteMembership: category = .incomplete
        case MessagesAttachmentObservation.Failure.membershipDrift: category = .membership
        default: category = .other
        }
        return detail(category: category)
    }

    func detail(category: Category) -> String {
        "attachment-unverified:\(stage.rawValue):\(category.rawValue)"
    }

}
