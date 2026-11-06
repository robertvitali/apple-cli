import Foundation
import Testing
@testable import AppleKit

@Suite struct AttachmentDiagnosticProtocolTests {
    @Test func fixedAttachmentDetailsSurviveAndUntrustedValuesAreRemoved() {
        let stages = ["initial-read", "initial-binding", "initial-files", "initial-state", "titles", "trust",
            "eligibility", "navigation", "route", "revalidation", "frontmost", "enabled", "actions", "press",
            "post-press-process", "verification-read", "verification-binding", "verification-files", "verification-state"]
        let categories = ["deadline-expired", "target-drift", "ambiguous-selected-message", "unknown-ax-value",
            "traversal-limit", "ax-failure", "route-drift", "cancelled", "other", "accessibility-denied",
            "press-unavailable", "observation-refused", "membership-drift", "incomplete-membership",
            "state-unavailable", "state-failed"]
        for stage in stages {
            for category in categories {
                let detail = "attachment-unverified:\(stage):\(category)"
                #expect(WorkerOperationResult.failed(detail).detail == detail)
                #expect(WorkerOperationResult.refused(detail).detail == detail)
                for suffix in [":extra", "\n", "/private/path", "\0", ":synthetic-message"] {
                    #expect(WorkerOperationResult.failed(detail + suffix).detail == nil)
                }
            }
        }
        for value in ["", "attachment-unverified::other", "attachment-unverified:press:",
                      "attachment-unverified:unknown:other", "attachment-unverified:press:synthetic-secret",
                      " attachment-unverified:press:other", "attachment-unverified:press:other ",
                      "attachment-unverified:PRESS:other", "Attachment-unverified:press:other",
                      String(repeating: "x", count: 129)] {
            #expect(WorkerOperationResult.failed(value).detail == nil)
        }
    }
}
