import Foundation
import Testing
@testable import ContactsKit
import AppleKit
import TestSupport

// Logic-tier tests for the CONTACTS write-safety decision logic (no Contacts.framework / TCC).
// The fetched-target GUARDS (`requireLabeledContactTarget` / `requireLabeledGroupTarget`) fetch
// from the live store, so their wiring is live-tier only — but the DECISION they make routes
// through the pure `ContactsLabel` selector, which is locked here. Both the create-side label
// gate and the fetched-target guards call `ContactsLabel`, so this also proves they can't drift.

@Suite("Contacts write-safety label selection")
struct ContactsWriteSafetyTests {
    // The CANONICAL constant, not the live `TestMode.sandboxPrefix`. Every literal below is
    // an "apple-cli-test…" name, so reading the env-backed prefix would make these assertions
    // depend on `APPLE_TEST_SANDBOX` — which `MailKitTests/WriteSafetyTests` setenv()s to
    // "qa-fixture" while these run in parallel. Same class of race as the APPLE_DRY_RUN one
    // documented in AppleKitTests/WriteModelV2CoreTests; the fix is not to read live env from
    // a test whose expectations are hard-coded.
    let prefix = TestMode.canonicalSandboxPrefix

    @Test("primaryName picks the first non-empty of given → family → org")
    func primaryNameOrder() {
        #expect(ContactsLabel.primaryName(given: "apple-cli-test G", family: "F", organization: "O") == "apple-cli-test G")
        #expect(ContactsLabel.primaryName(given: "   ", family: "apple-cli-test F", organization: "O") == "apple-cli-test F")
        #expect(ContactsLabel.primaryName(given: "", family: "", organization: "apple-cli-test Org") == "apple-cli-test Org")
        #expect(ContactsLabel.primaryName(given: nil, family: nil, organization: nil) == "")
        #expect(ContactsLabel.primaryName(given: "  ", family: nil, organization: "") == "")
    }

    @Test("isLabeled is a strict prefix match that can't be vacated")
    func labeling() {
        #expect(ContactsLabel.isLabeled("apple-cli-test Mom", prefix: prefix) == true)
        #expect(ContactsLabel.isLabeled("Mom", prefix: prefix) == false)
        // Prefix, not substring: a near-miss must NOT pass.
        #expect(ContactsLabel.isLabeled("almost-apple-cli-test thing", prefix: prefix) == false)
        #expect(ContactsLabel.isLabeled("", prefix: prefix) == false)
        // The default prefix is never empty, so no real name is a labeled test item by accident.
        #expect(prefix.isEmpty == false)
    }

    @Test("create-side and fetched-target-guard selection agree (no drift)")
    func selectionConsistency() {
        // A contact labeled by ANY of the three name fields is recognized by the same selector
        // the create gate uses — so create can never label something the guard later rejects.
        for triple in [("apple-cli-test A", "B", "C"), ("", "apple-cli-test B", "C"), ("", "", "apple-cli-test C")] {
            let name = ContactsLabel.primaryName(given: triple.0, family: triple.1, organization: triple.2)
            #expect(ContactsLabel.isLabeled(name, prefix: prefix) == true)
        }
        // A fully-real contact is rejected regardless of which field holds the name.
        for triple in [("Mom", "", ""), ("", "Smith", ""), ("", "", "Acme Inc")] {
            let name = ContactsLabel.primaryName(given: triple.0, family: triple.1, organization: triple.2)
            #expect(ContactsLabel.isLabeled(name, prefix: prefix) == false)
        }
    }
}

// MARK: - Write-model v2 posture (docs/write-model-v2.md)

/// Pins the v2 DECISION `resolveWrite` makes, which nothing else can catch: the bats tier
/// cannot assert "a flagless contacts write executes" without actually mutating the
/// operator's address book, and the AppleKit core tier only proves the precedence chain,
/// not that THIS domain opted into it. A silent revert to dry-run-by-default (or a
/// re-tightening of the lifted label gate) fails here and only here.
///
/// `resolveWrite` reads `APPLE_TEST_MODE` and `APPLE_DRY_RUN` from the PROCESS environment, so
/// every test that calls it runs inside `withPinnedWriteEnv` — the three sandbox variables plus
/// `APPLE_DRY_RUN`, all pinned ABSENT under the test process's single recursive lock. Reading them
/// live (the previous shape) meant these pins raced every other suite's mutation window and
/// additionally inherited whatever the operator had exported. The env-SET branches remain the
/// AppleKit core tier's job — it owns the `envVar:` seam.
@Suite("Contacts write-model v2 posture")
struct ContactsWriteModelV2Tests {
    func opts(_ args: [String]) throws -> GlobalOptions { try GlobalOptions.parse(args) }

    /// Pin every variable this suite's gates read: the sandbox trio plus `APPLE_DRY_RUN`.
    /// `withoutSandboxOverrides` covers the first three; the nested window adds the fourth.
    func withPinnedWriteEnv<T>(_ body: () throws -> T) rethrows -> T {
        try TestEnvironment.withoutSandboxOverrides {
            try TestEnvironment.with([TestMode.dryRunVar: String?.none], body)
        }
    }

    @Test("the pin actually clears the variables every gate below depends on")
    func pinnedEnvironmentIsClean() {
        withPinnedWriteEnv {
            let env = ProcessInfo.processInfo.environment
            for key in ["APPLE_TEST_MODE", "APPLE_DRY_RUN", "APPLE_TEST_SANDBOX", "APPLE_TEST_RECIPIENTS"] {
                #expect(env[key] == nil, "\(key) must be pinned absent inside the window")
            }
            // Inside the pin the label prefix is deterministically the built-in constant.
            #expect(TestMode.sandboxPrefix == TestMode.canonicalSandboxPrefix)
        }
    }

    @Test("DEFAULT PIN: a flagless contacts write EXECUTES and is unsandboxed")
    func defaultsToExecute() throws {
        try withPinnedWriteEnv {
            let gate = try resolveWrite(self.opts([]))
            #expect(gate.willExecute == true)
            #expect(gate.sandboxActive == false)
        }
    }

    @Test("--dry-run previews; --execute is redundant; --dry-run wins over --execute")
    func dryRunPrecedence() throws {
        // The `try`s are hoisted OUT of `#expect`: the macro wraps its argument in an autoclosure,
        // which the compiler cannot prove throwing inside a `rethrows` closure ("errors thrown
        // from here are not handled"). Compute first, assert second.
        try withPinnedWriteEnv {
            let dryRun = try resolveWrite(self.opts(["--dry-run"]))
            let execute = try resolveWrite(self.opts(["--execute"]))
            let both = try resolveWrite(self.opts(["--dry-run", "--execute"]))
            #expect(dryRun.willExecute == false)
            #expect(execute.willExecute == true)
            #expect(both.willExecute == false)
        }
    }

    @Test("--test-mode alone engages the sandbox without forcing a preview")
    func flagEngagesSandbox() throws {
        try withPinnedWriteEnv {
            let gate = try resolveWrite(self.opts(["--test-mode"]))
            #expect(gate.sandboxActive == true)
            #expect(gate.willExecute == true)
        }
    }

    /// Pinned via the `prefix:` seam — `TestMode.sandboxPrefix` is env-backed and MailKitTests
    /// setenv()s `APPLE_TEST_SANDBOX=qa-fixture` in parallel, which flaked this test 1-in-6
    /// before the seam existed.
    @Test("LIFT PIN: the create label gate applies ONLY inside the sandbox")
    func labelGateIsSandboxOnly() throws {
        let p = TestMode.canonicalSandboxPrefix
        try withPinnedWriteEnv {
            // Unsandboxed, an unlabeled create is allowed — that IS the v2 flip (the oracle
            // creates real contacts on call). A throw here means the gate was re-tightened.
            let unsandboxed = try resolveWrite(self.opts([]), labeledName: "Jane Doe", prefix: p)
            #expect(unsandboxed.willExecute == true)
            // Sandboxed, the same name is refused.
            #expect(throws: AppleError.self) {
                _ = try resolveWrite(self.opts(["--test-mode"]), labeledName: "Jane Doe", prefix: p)
            }
            // ...and a labeled one passes.
            let labeled = try resolveWrite(self.opts(["--test-mode"]), labeledName: p + " Jane", prefix: p)
            #expect(labeled.sandboxActive == true)
        }
    }

    @Test("the label gate is checked on the PREVIEW path too (no dishonest dry-run)")
    func labelGateRunsOnPreview() {
        withPinnedWriteEnv {
            #expect(throws: AppleError.self) {
                _ = try resolveWrite(self.opts(["--test-mode", "--dry-run"]), labeledName: "Jane Doe",
                                     prefix: TestMode.canonicalSandboxPrefix)
            }
        }
    }

    @Test("SECURITY PIN: the delete gate reads the ENV only — no flag can grant it")
    func deleteGateIsEnvKeyed() {
        // `contactsDeleteEnvGranted` takes only an environment-variable NAME, so a --test-mode
        // flag is structurally incapable of satisfying it; with APPLE_TEST_MODE pinned absent it
        // is false. This mirrors apple-contacts-mcp's require_test_mode_for/CONTACTS_TEST_MODE,
        // which the oracle likewise reserves to the environment. The read is pinned rather than
        // live: an operator (or a concurrent suite) with APPLE_TEST_MODE set would otherwise flip
        // this assertion and it would read as a product regression.
        withPinnedWriteEnv { #expect(contactsDeleteEnvGranted() == false) }
        let msg = contactsDeleteGateMessage("delete_contact")
        #expect(msg.contains("delete_contact"))
        #expect(msg.contains("APPLE_TEST_MODE=1"))
        #expect(msg.contains("FLAG deliberately does NOT satisfy"))
    }

    @Test("gate notes join cleanly and vanish when empty")
    func gateNoteJoining() {
        #expect(joinedGateNote([nil, nil]) == nil)
        #expect(joinedGateNote([]) == nil)
        #expect(joinedGateNote(["a", nil, "b"]) == "a b")
        #expect(sandboxTargetUncheckedNote("the target contact").contains("did not run it"))
    }
}
