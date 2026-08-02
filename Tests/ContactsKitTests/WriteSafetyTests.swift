import Foundation
import Testing
@testable import ContactsKit
import AppleKit

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
/// These read the real process environment. They assume `APPLE_TEST_MODE` / `APPLE_DRY_RUN`
/// are unset — asserted below so a polluted env fails legibly instead of mysteriously. The
/// env-SET branches are the AppleKit core tier's job (it owns the `envVar:` seam); mutating
/// the process env here would race the parallel suites.
@Suite("Contacts write-model v2 posture")
struct ContactsWriteModelV2Tests {
    func opts(_ args: [String]) throws -> GlobalOptions { try GlobalOptions.parse(args) }

    @Test("the test environment is clean (precondition for every pin below)")
    func cleanEnvironment() {
        let env = ProcessInfo.processInfo.environment
        #expect(env["APPLE_TEST_MODE"] == nil || env["APPLE_TEST_MODE"]!.isEmpty)
        #expect(env["APPLE_DRY_RUN"] == nil || env["APPLE_DRY_RUN"]!.isEmpty)
    }

    @Test("DEFAULT PIN: a flagless contacts write EXECUTES and is unsandboxed")
    func defaultsToExecute() throws {
        let gate = try resolveWrite(opts([]))
        #expect(gate.willExecute == true)
        #expect(gate.sandboxActive == false)
    }

    @Test("--dry-run previews; --execute is redundant; --dry-run wins over --execute")
    func dryRunPrecedence() throws {
        #expect(try resolveWrite(opts(["--dry-run"])).willExecute == false)
        #expect(try resolveWrite(opts(["--execute"])).willExecute == true)
        #expect(try resolveWrite(opts(["--dry-run", "--execute"])).willExecute == false)
    }

    @Test("--test-mode alone engages the sandbox without forcing a preview")
    func flagEngagesSandbox() throws {
        let gate = try resolveWrite(opts(["--test-mode"]))
        #expect(gate.sandboxActive == true)
        #expect(gate.willExecute == true)
    }

    /// Pinned via the `prefix:` seam — `TestMode.sandboxPrefix` is env-backed and MailKitTests
    /// setenv()s `APPLE_TEST_SANDBOX=qa-fixture` in parallel, which flaked this test 1-in-6
    /// before the seam existed.
    @Test("LIFT PIN: the create label gate applies ONLY inside the sandbox")
    func labelGateIsSandboxOnly() throws {
        let p = TestMode.canonicalSandboxPrefix
        // Unsandboxed, an unlabeled create is allowed — that IS the v2 flip (the oracle
        // creates real contacts on call). A throw here means the gate was re-tightened.
        #expect(try resolveWrite(opts([]), labeledName: "Ada Lovelace", prefix: p).willExecute == true)
        // Sandboxed, the same name is refused.
        #expect(throws: AppleError.self) {
            _ = try resolveWrite(self.opts(["--test-mode"]), labeledName: "Ada Lovelace",
                                 prefix: TestMode.canonicalSandboxPrefix)
        }
        // ...and a labeled one passes.
        #expect(try resolveWrite(opts(["--test-mode"]), labeledName: p + " Ada", prefix: p).sandboxActive == true)
    }

    @Test("the label gate is checked on the PREVIEW path too (no dishonest dry-run)")
    func labelGateRunsOnPreview() {
        #expect(throws: AppleError.self) {
            _ = try resolveWrite(self.opts(["--test-mode", "--dry-run"]), labeledName: "Ada Lovelace",
                                 prefix: TestMode.canonicalSandboxPrefix)
        }
    }

    @Test("SECURITY PIN: the delete gate reads the ENV only — no flag can grant it")
    func deleteGateIsEnvKeyed() {
        // `contactsDeleteEnvGranted` takes no arguments at all, so a --test-mode flag is
        // structurally incapable of satisfying it; with a clean env it is false. This mirrors
        // apple-contacts-mcp's require_test_mode_for/CONTACTS_TEST_MODE, which the oracle
        // likewise reserves to the environment.
        #expect(contactsDeleteEnvGranted == false)
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
