import Foundation
import Testing
@testable import AppleKit
@testable import MessagesKit

@Suite struct MessagesAttachmentDiagnosticTests {
    @Test func sharedProductionErrorsKeepTheirKnownCategories() {
        let diagnostic = MessagesAttachmentDiagnostic()
        diagnostic.record(.navigation)
        let expected: [MessagesReactionAXError: String] = [
            .deadlineExpired: "deadline-expired", .targetDrift: "target-drift",
            .ambiguousSelectedMessage: "ambiguous-selected-message",
            .unknownAXValue: "unknown-ax-value", .traversalLimit: "traversal-limit",
            .axFailure: "ax-failure"
        ]
        for error in MessagesReactionAXError.allCases {
            let category = expected[error] ?? "other"
            #expect(diagnostic.detail(error) == "attachment-unverified:navigation:\(category)")
        }
    }
    @Test func actualTitleValidationErrorKeepsUnknownCategory() {
        let diagnostic = MessagesAttachmentDiagnostic()
        diagnostic.record(.titles)
        var caught = false
        do {
            _ = try MessagesReactionActionTitleResolver.canonicalize(["synthetic-invalid\n"])
        } catch {
            caught = true
            #expect(error as? MessagesReactionAXError == .unknownAXValue)
            #expect(diagnostic.detail(error) == "attachment-unverified:titles:unknown-ax-value")
        }
        #expect(caught)
    }

    @Test func typedErrorsNeverDiscloseUnderlyingValues() {
        let secret = "synthetic-secret /private/path\nmessage:body"
        let errors: [any Error] = MessagesAXNavigationError.allCases.map { $0 as any Error }
            + [MessagesAXRouteDrift(), CancellationError(), WorkerProtocolError.deadlineExpired,
               WorkerProtocolError.cancelled, MessagesAttachmentAXPress.Failure.accessibilityDenied,
               MessagesAttachmentAXPress.Failure.pressUnavailable, MessagesAttachmentAXPress.Failure.observationRefused,
               MessagesAttachmentObservation.Failure.deadline, MessagesAttachmentObservation.Failure.cancelled,
               MessagesAttachmentObservation.Failure.incompleteMembership,
               MessagesAttachmentObservation.Failure.membershipDrift,
               NSError(domain: secret, code: 7, userInfo: [NSLocalizedDescriptionKey: secret])]
        for stage in MessagesAttachmentDiagnostic.Stage.allCases {
            let diagnostic = MessagesAttachmentDiagnostic()
            diagnostic.record(stage)
            for error in errors {
                let detail = diagnostic.detail(error)
                #expect(WorkerOperationResult.failed(detail).detail == detail)
                #expect(!detail.contains(secret))
            }
            for category in MessagesAttachmentDiagnostic.Category.allCases {
                let detail = diagnostic.detail(category: category)
                #expect(WorkerOperationResult.failed(detail).detail == detail)
            }
        }
    }

    @Test func nestedSuccessRestoresCallerButFailureRetainsInnermostStage() throws {
        let diagnostic = MessagesAttachmentDiagnostic()
        diagnostic.at(.route) {
            diagnostic.at(.eligibility) { #expect(diagnostic.stage == .eligibility) }
            #expect(diagnostic.stage == .route)
        }
        #expect(diagnostic.stage == .initialRead)
        let sentinel = NSError(domain: "synthetic-error", code: 9)
        var caught = false
        do {
            try diagnostic.at(.navigation) {
                try diagnostic.at(.verificationFiles) { throw sentinel }
            }
        } catch {
            caught = true
            #expect((error as NSError) === sentinel)
            #expect(diagnostic.detail(error) == "attachment-unverified:verification-files:other")
        }
        #expect(caught)
    }
}
