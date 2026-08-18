import Testing
import Foundation
@testable import MailKit

/// extra31 (Q11 batch 3): the error class a failed account resolution reports, pinned pure.
/// A directory that FAILED TO LOAD (Mail stalled / automation denied / AppleScript timeout)
/// must report the upstream cause (exit 69) — "unknown account" would be a lie there. A
/// directory that loaded fine and simply lacks the name keeps the honest not_found (65).
@Suite("Account resolution error class (extra31)")
struct AccountResolutionTests {
    private struct Stall: Error, CustomStringConvertible { var description: String { "osascript timed out after 30s" } }

    @Test func directoryLoadFailureIsUpstreamWithCause() {
        let e = MailContext.accountResolutionError(selector: "iCloud",
                                                   directoryLoadError: Stall(),
                                                   knownNames: [])
        #expect(e.type == "upstream_error")
        #expect(e.exitCode == 69)
        // The message must carry the thrown error's description (for the real RunError that
        // is the failure CLASS — "osascript exited N"; stderr is deliberately suppressed)
        // and the headless UUID escape hatch; both are load-bearing remediation.
        #expect(e.message.contains("osascript timed out after 30s"))
        #expect(e.message.contains("UUID"))
    }

    @Test func cleanDirectoryWithoutTheNameStaysNotFound() {
        let e = MailContext.accountResolutionError(selector: "Bogus",
                                                   directoryLoadError: nil,
                                                   knownNames: ["iCloud", "Gmail"])
        #expect(e.type == "not_found")
        #expect(e.exitCode == 65)
        #expect(e.message.contains("unknown account 'Bogus'"))
        #expect(e.message.contains("iCloud, Gmail"))
    }
}
