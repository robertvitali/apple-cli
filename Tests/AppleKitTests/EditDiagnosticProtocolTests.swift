import Foundation
import Testing
@testable import AppleKit

@Suite struct EditDiagnosticProtocolTests {
    @Test func admitsOnlyClosedEditDiagnosticFields() throws {
        let stages = ["native-action", "trust", "titles", "process", "inactive", "navigation", "route",
            "anchor", "open-editor", "capture-editor", "replacement", "confirmation", "completion", "persistence"]
        let categories = ["deadline-expired", "target-drift", "ambiguous-selected-message", "unknown-ax-value",
            "traversal-limit", "ax-failure", "route-drift", "cancelled", "other"]
        for stage in stages {
            for category in categories {
                let detail = "edit-unverified:\(stage):\(category)"
                #expect(WorkerOperationResult.failed(detail).detail == detail)
            }
        }
        for detail in ["edit-unverified:route:private-message", "edit-unverified:private-message:other",
                       "edit-unverified::other", "edit-unverified:route:", "edit-unverified:route:other:extra",
                       "edit-unverified:route:other\n", "edit-unverified:route:other/private/path"] {
            #expect(WorkerOperationResult.failed(detail).detail == nil)
        }
    }
}
