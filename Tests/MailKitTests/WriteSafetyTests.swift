import Testing
import Foundation
@testable import MailKit
import AppleKit

// Logic-tier coverage for the Mail WRITE-SAFETY gates — the decision logic proven by the live
// e2e run (self-send refused to non-self, unlabeled real messages refused for mutation, etc.),
// captured here so the gates are regression-locked WITHOUT needing a live Mac + TCC. These test
// the real `guardOutbound` / `requireLiveMessageMutation` / `splitRecipients` used by every write
// command; only the final AppleScript call (which these gates run BEFORE) needs the live tier.
//
// The suite is `.serialized` because the gates read process env (APPLE_TEST_MODE /
// APPLE_TEST_RECIPIENTS / APPLE_TEST_SANDBOX); each test sets + restores it around its body.

@Suite("Mail write-safety gates", .serialized)
struct MailWriteSafetyTests {

    /// Set the sandbox env for the duration of `body`, restoring the prior values after.
    private func withEnv(testMode: Bool, recipients: String?, sandbox: String? = nil, _ body: () -> Void) {
        func get(_ k: String) -> String? { getenv(k).map { String(cString: $0) } }
        func set(_ k: String, _ v: String?) { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
        let prev = (get("APPLE_TEST_MODE"), get("APPLE_TEST_RECIPIENTS"), get("APPLE_TEST_SANDBOX"))
        set("APPLE_TEST_MODE", testMode ? "1" : nil)
        set("APPLE_TEST_RECIPIENTS", recipients)
        set("APPLE_TEST_SANDBOX", sandbox)
        defer { set("APPLE_TEST_MODE", prev.0); set("APPLE_TEST_RECIPIENTS", prev.1); set("APPLE_TEST_SANDBOX", prev.2) }
        body()
    }

    /// Build a MailMessage with a controllable subject + Message-ID (no store needed).
    private func msg(subject: String, imid: String?) -> MailMessage {
        MailMessage.fromSelection(.init(applescriptID: "1", internetMessageID: imid, subject: subject,
                                        sender: "me@self.test", readStatus: false, flagged: false, content: nil))
    }

    // MARK: guardOutbound (send / reply / forward)

    @Test("outbound refuses when the --test-mode FLAG is off, even with env set + self recipient")
    func outboundRefusesFlagOff() {
        withEnv(testMode: true, recipients: "me@self.test") {
            #expect(throws: AppleError.self) { try guardOutbound(recipients: ["me@self.test"], testMode: false) }
        }
    }

    @Test("outbound refuses when APPLE_TEST_MODE env is off, even with the flag + self recipient")
    func outboundRefusesEnvOff() {
        withEnv(testMode: false, recipients: "me@self.test") {
            #expect(throws: AppleError.self) { try guardOutbound(recipients: ["me@self.test"], testMode: true) }
        }
    }

    @Test("outbound refuses a non-allowlisted (non-self) recipient — the core self-only guarantee")
    func outboundRefusesNonSelf() {
        withEnv(testMode: true, recipients: "me@self.test") {
            let err = #expect(throws: AppleError.self) {
                try guardOutbound(recipients: ["me@self.test", "someone-else@example.com"], testMode: true)
            }
            #expect(err?.exitCode == 77)          // safety_violation, not a generic failure
        }
    }

    @Test("outbound ALLOWS when test-mode on AND every recipient is an allowlisted self address")
    func outboundAllowsSelfOnly() {
        withEnv(testMode: true, recipients: "me@self.test,alias@self.test") {
            #expect(throws: Never.self) {
                try guardOutbound(recipients: ["me@self.test", "alias@self.test"], testMode: true)
            }
        }
    }

    @Test("outbound refuses when the allowlist is empty (no APPLE_TEST_RECIPIENTS set)")
    func outboundRefusesEmptyAllowlist() {
        withEnv(testMode: true, recipients: nil) {
            #expect(throws: AppleError.self) { try guardOutbound(recipients: ["me@self.test"], testMode: true) }
        }
    }

    // MARK: requireLiveMessageMutation (mark / flag / move / delete-to-trash)

    @Test("mutation gate refuses a REAL (unlabeled) message even with test-mode on — protects real mail")
    func mutationRefusesUnlabeled() {
        withEnv(testMode: true, recipients: nil) {
            let err = #expect(throws: AppleError.self) {
                _ = try requireLiveMessageMutation(msg(subject: "Q3 planning notes", imid: "abc@id"), testMode: true)
            }
            #expect(err?.exitCode == 77)
        }
    }

    @Test("mutation gate refuses when test-mode is off, even for a labeled message")
    func mutationRefusesTestModeOff() {
        withEnv(testMode: false, recipients: nil) {
            #expect(throws: AppleError.self) {
                _ = try requireLiveMessageMutation(msg(subject: "apple-cli-test hi", imid: "abc@id"), testMode: false)
            }
        }
    }

    @Test("mutation gate refuses a labeled message that has no RFC Message-ID (cannot address it)")
    func mutationRefusesNoMessageID() {
        withEnv(testMode: true, recipients: nil) {
            #expect(throws: AppleError.self) {
                _ = try requireLiveMessageMutation(msg(subject: "apple-cli-test hi", imid: nil), testMode: true)
            }
        }
    }

    @Test("mutation gate RETURNS the Message-ID for a labeled message with test-mode on")
    func mutationAllowsLabeled() {
        withEnv(testMode: true, recipients: nil) {
            let imid = try? requireLiveMessageMutation(msg(subject: "apple-cli-test hello", imid: "wanted@id"), testMode: true)
            #expect(imid == "wanted@id")
        }
    }

    @Test("a custom APPLE_TEST_SANDBOX prefix is honored by the label gate")
    func mutationHonorsCustomPrefix() {
        withEnv(testMode: true, recipients: nil, sandbox: "qa-fixture") {
            // A message labeled with the custom prefix passes; the default prefix no longer does.
            #expect((try? requireLiveMessageMutation(msg(subject: "qa-fixture x", imid: "i@d"), testMode: true)) == "i@d")
            #expect(throws: AppleError.self) {
                _ = try requireLiveMessageMutation(msg(subject: "apple-cli-test x", imid: "i@d"), testMode: true)
            }
        }
    }

    // MARK: splitRecipients (pure)

    @Test("splitRecipients flattens repeated + comma-joined options, trims, drops empties")
    func splitRecipientsParsing() {
        #expect(splitRecipients(["a@x.com,b@y.com", " c@z.com "]) == ["a@x.com", "b@y.com", "c@z.com"])
        #expect(splitRecipients(["a@x.com, ,b@x.com"]) == ["a@x.com", "b@x.com"])
        #expect(splitRecipients([]) == [])
    }

    // MARK: executeMessageMutation — the all-or-nothing batch guarantee (the single most important
    // behavioral property: a mixed batch containing one real/unlabeled message mutates NOTHING).

    @Test("a mixed batch aborts before ANY op runs — real mail is never partially mutated")
    func batchAllOrNothing() {
        withEnv(testMode: true, recipients: nil) {
            var opCalls = 0
            let batch = [msg(subject: "apple-cli-test one", imid: "a@id"),
                         msg(subject: "Real inbox mail", imid: "b@id"),   // unlabeled → must abort the whole batch
                         msg(subject: "apple-cli-test three", imid: "c@id")]
            #expect(throws: AppleError.self) {
                _ = try executeMessageMutation(batch, testMode: true) { _, _ in opCalls += 1; return true }
            }
            #expect(opCalls == 0)   // phase-1 gate threw before any phase-2 mutation
        }
    }

    @Test("an all-labeled batch applies to every target")
    func batchAllLabeled() {
        withEnv(testMode: true, recipients: nil) {
            var opCalls = 0
            let batch = [msg(subject: "apple-cli-test one", imid: "a@id"),
                         msg(subject: "apple-cli-test two", imid: "b@id")]
            let result = try? executeMessageMutation(batch, testMode: true) { _, _ in opCalls += 1; return true }
            #expect(opCalls == 2)
            #expect(result?.applied.count == 2)
            #expect(result?.notFound.isEmpty == true)
        }
    }

    @Test("a located-but-unmutable target collects into not_found instead of throwing")
    func batchNotFound() {
        withEnv(testMode: true, recipients: nil) {
            let batch = [msg(subject: "apple-cli-test x", imid: "a@id")]
            // op returns false → Mail couldn't locate it (e.g. archived); reported, not thrown.
            let result = try? executeMessageMutation(batch, testMode: true) { _, _ in false }
            #expect(result?.applied.isEmpty == true)
            #expect(result?.notFound == ["1"])   // fromSelection sets id = "1"
        }
    }
}
