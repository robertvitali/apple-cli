import Testing
import Foundation
@testable import AppleKit

// Logic-tier tests — no Apple permissions / TCC required; runnable in CI.
// These test the PURE prefix-normalization helper directly (no process-env mutation),
// so they can't race with the sibling suites that read APPLE_TEST_MODE in parallel.

@Suite("TestMode sandbox-prefix normalization")
struct TestModeTests {
    @Test("nil / empty / whitespace override falls back to the default prefix (fail-closed)")
    func emptyFallsBackToDefault() {
        // The security-critical case: an empty override must NOT vacate the label gate.
        // If normalizedPrefix returned "", `name.hasPrefix("")` would be true for ANY name,
        // and the sandbox label check would wave every unlabeled real item through.
        #expect(TestMode.normalizedPrefix(from: nil) == "apple-cli-test")
        #expect(TestMode.normalizedPrefix(from: "") == "apple-cli-test")
        #expect(TestMode.normalizedPrefix(from: "   ") == "apple-cli-test")
        #expect(TestMode.normalizedPrefix(from: "\t\n") == "apple-cli-test")
    }

    @Test("a real override is honored (and trimmed)")
    func realOverrideHonored() {
        #expect(TestMode.normalizedPrefix(from: "custom-prefix") == "custom-prefix")
        #expect(TestMode.normalizedPrefix(from: "  padded  ") == "padded")
    }

    @Test("the default prefix can never be a strict prefix of an arbitrary real name")
    func defaultPrefixGatesUnlabeledNames() {
        // Belt-and-braces: with the default prefix, ordinary real item names are NOT labeled.
        let prefix = TestMode.normalizedPrefix(from: "")
        #expect("Mom's Birthday".hasPrefix(prefix) == false)
        #expect("Q3 Planning".hasPrefix(prefix) == false)
        #expect("apple-cli-test Mom's Birthday".hasPrefix(prefix) == true)
    }
}
