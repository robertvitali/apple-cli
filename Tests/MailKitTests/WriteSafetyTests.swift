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

// Logic-tier regression lock for `DraftSendResult.parse` — the safety-critical string→enum mapping
// of `sendDraftScript`'s raw stdout. The AppleScript itself needs a live Mac, but THIS mapping is
// where a future edit could silently mishandle a `blocked` verdict (→ send to a non-self recipient)
// or misparse the sent-recipient list; it is pure, so it's CI-lockable without Mail. `us` is the
// unit separator the script emits between the "sent" tag and each verified recipient.
@Suite("DraftSendResult.parse (pure)")
struct DraftSendResultParseTests {
    private let US = MailScript.US

    @Test("a bare `sent` (no recipients appended) parses to .sent([])")
    func sentNoRecipients() {
        #expect(MailScript.DraftSendResult.parse("sent", us: US) == .sent([]))
    }

    @Test("`sent<US>addr…` parses to .sent with the verified recipient list, dropping empties")
    func sentWithRecipients() {
        #expect(MailScript.DraftSendResult.parse("sent\(US)me@self.test", us: US) == .sent(["me@self.test"]))
        #expect(MailScript.DraftSendResult.parse("sent\(US)a@self.test\(US)b@self.test", us: US)
                == .sent(["a@self.test", "b@self.test"]))
        // a stray trailing separator must not yield a phantom empty recipient
        #expect(MailScript.DraftSendResult.parse("sent\(US)a@self.test\(US)", us: US) == .sent(["a@self.test"]))
    }

    @Test("a `blocked:<addr>` verdict maps to .blocked carrying the EXACT address (the refuse signal)")
    func blockedCarriesAddress() {
        #expect(MailScript.DraftSendResult.parse("blocked:someone-else@example.com", us: US)
                == .blocked("someone-else@example.com"))
        // the fail-closed empty-address sentinel round-trips as a block, never as success
        #expect(MailScript.DraftSendResult.parse("blocked:<empty-address>", us: US) == .blocked("<empty-address>"))
    }

    @Test("the status sentinels each map to their case")
    func statusSentinels() {
        #expect(MailScript.DraftSendResult.parse("notfound", us: US) == .notFound)
        #expect(MailScript.DraftSendResult.parse("norecipients", us: US) == .noRecipients)
        #expect(MailScript.DraftSendResult.parse("openfailed", us: US) == .openFailed)
        #expect(MailScript.DraftSendResult.parse("senderror:-1708", us: US) == .sendError("-1708"))
    }

    @Test("an UNRECOGNIZED string parses to nil so the caller throws — never a silent .sent")
    func unrecognizedIsNil() {
        #expect(MailScript.DraftSendResult.parse("", us: US) == nil)
        #expect(MailScript.DraftSendResult.parse("garbage", us: US) == nil)
        // critically: a near-miss that is NOT exactly a known sentinel must not read as success
        #expect(MailScript.DraftSendResult.parse("sentinel", us: US) == nil)
        #expect(MailScript.DraftSendResult.parse("SENT", us: US) == nil)
    }
}

/// Trash-mailbox resolution for the IRREVERSIBLE erase paths (audit gap I). Pure — no Mail.
/// These rules decide what an empty-trash actually erases, so getting them wrong is unrecoverable;
/// they are deliberately Swift-side (rather than buried in AppleScript) so they can be locked here.
@Suite("Trash mailbox resolution (gap I)")
struct TrashResolutionTests {
    typealias TB = MailScript.TrashMailbox

    @Test func trashNameDetectionIsCaseInsensitiveAndCoversRealAccounts() {
        // Real names observed on this fleet: iCloud exposes BOTH "Trash" and "Deleted Messages";
        // Gmail exposes "[Gmail]Trash". A hardcoded "Trash" match would pick iCloud's empty decoy.
        #expect(MailScript.isTrashMailboxName("Trash"))
        #expect(MailScript.isTrashMailboxName("Deleted Messages"))
        #expect(MailScript.isTrashMailboxName("[Gmail]Trash"))
        #expect(MailScript.isTrashMailboxName("deleted items"))
        #expect(MailScript.isTrashMailboxName("Bin"))
        #expect(!MailScript.isTrashMailboxName("INBOX"))
        #expect(!MailScript.isTrashMailboxName("Archive"))
        #expect(!MailScript.isTrashMailboxName("Sent Messages"))
        // EXACT names only. A substring rule would match these personal folders and could
        // auto-select one as the erase target — never acceptable for an irreversible op.
        #expect(!MailScript.isTrashMailboxName("Deleted drafts to revisit"))
        #expect(!MailScript.isTrashMailboxName("Trash ideas"))
        #expect(!MailScript.isTrashMailboxName("Recently Deleted Receipts"))
    }

    @Test func resolvesTheSingleNonEmptyTrash() throws {
        // The real iCloud shape: an empty "Trash" decoy alongside the actual "Deleted Messages".
        let boxes = [TB(name: "Trash", count: 0), TB(name: "Deleted Messages", count: 34)]
        #expect(try MailScript.resolveTrashMailbox(boxes, explicit: nil)?.name == "Deleted Messages")
    }

    @Test func nothingToEraseResolvesToNil() throws {
        #expect(try MailScript.resolveTrashMailbox([TB(name: "Trash", count: 0)], explicit: nil) == nil)
        #expect(try MailScript.resolveTrashMailbox([], explicit: nil) == nil)
    }

    /// FAIL-CLOSED: with two plausible targets the tool must refuse rather than guess which mail
    /// to destroy.
    @Test func ambiguousTrashRefusesRatherThanGuessing() {
        let boxes = [TB(name: "Trash", count: 3), TB(name: "Deleted Messages", count: 34)]
        #expect(throws: Error.self) { _ = try MailScript.resolveTrashMailbox(boxes, explicit: nil) }
    }

    @Test func explicitTrashMailboxWinsAndIsValidated() throws {
        let boxes = [TB(name: "Trash", count: 3), TB(name: "Deleted Messages", count: 34)]
        // An explicit name disambiguates — including selecting the smaller one.
        #expect(try MailScript.resolveTrashMailbox(boxes, explicit: "Trash")?.name == "Trash")
        #expect(try MailScript.resolveTrashMailbox(boxes, explicit: "deleted messages")?.name == "Deleted Messages")
        // An explicit name that isn't a trash mailbox on this account is a hard error, never a
        // silent fallback to some other mailbox.
        #expect(throws: Error.self) { _ = try MailScript.resolveTrashMailbox(boxes, explicit: "Archive") }
    }

    /// An explicit empty trash is still a valid target (erasing 0 is a no-op, not an error).
    @Test func explicitEmptyTrashIsSelectable() throws {
        let boxes = [TB(name: "Trash", count: 0), TB(name: "Deleted Messages", count: 5)]
        #expect(try MailScript.resolveTrashMailbox(boxes, explicit: "Trash")?.count == 0)
    }
}

/// The canonical-label control for IRREVERSIBLE erases (audit gap I). This is the check that stops
/// an `APPLE_TEST_SANDBOX` override from widening what `delete --permanent` may destroy, so it is
/// worth locking directly rather than only via a live run.
@Suite("Canonical label gate (irreversible ops)")
struct CanonicalLabelTests {
    private func msg(_ subject: String) -> MailMessage {
        MailMessage.fromSelection(.init(applescriptID: "1", internetMessageID: "x@y", subject: subject,
                                        sender: "me@self.test", readStatus: false, flagged: false, content: nil))
    }

    @Test func acceptsOnlyCanonicallyLabeledTargets() throws {
        try requireCanonicalLabels([msg("apple-cli-test permdel-1"), msg("apple-cli-test-2")])
        try requireCanonicalLabels([])                       // nothing to erase → nothing to refuse
    }

    @Test func refusesAnyUnlabeledTargetInTheBatch() {
        #expect(throws: Error.self) { try requireCanonicalLabels([msg("Re: 2025 Tax Returns")]) }
        // ALL-OR-NOTHING: one real message anywhere in the batch refuses the whole erase.
        #expect(throws: Error.self) {
            try requireCanonicalLabels([msg("apple-cli-test ok"), msg("Quarterly invoice")])
        }
        // A label that merely CONTAINS the prefix isn't a prefix match.
        #expect(throws: Error.self) { try requireCanonicalLabels([msg("Fwd: apple-cli-test leak")]) }
    }

    /// The whole point: the check must ignore a widened APPLE_TEST_SANDBOX. `sandboxPrefix` is
    /// caller-redefinable; `canonicalSandboxPrefix` is a constant, so a widened override cannot
    /// make real mail erasable.
    @Test func canonicalPrefixIsNotRedefinableByEnv() {
        // `canonicalSandboxPrefix` is a `let`, so no env value can move it — whereas
        // `sandboxPrefix` reads APPLE_TEST_SANDBOX and can be pointed at real mail's subjects.
        #expect(TestMode.canonicalSandboxPrefix == "apple-cli-test")
        // A target labeled only under a widened override is still refused by the canonical check.
        #expect(throws: Error.self) { try requireCanonicalLabels([msg("Re: real mail")]) }
    }
}

/// Native reply/forward outcome parsing. This is the safety-critical half of the native-compose
/// path. The AppleScript reports `ok<US><id><US><recipients>` / `sendfail<US><id>` /
/// `refused<US><addrs><US><discardedFlag>` / `notfound`, and ANY other output (a Mail error
/// string, a truncated read, a future script revision) must map to a REFUSAL — never to a silent
/// success, which would report `executed: true` for a send that never happened, or treat an
/// unverified recipient set as allowlisted.
@Suite("Native reply/forward outcome parsing")
struct NativeComposeOutcomeTests {
    static let US = "\u{1F}"
    static let RS = "\u{1E}"

    @Test func okCarriesTheNewMessageIDAndMailsActualRecipients() {
        #expect(MailScript.parseNativeCompose("ok\(Self.US)78321\(Self.US)me@self.test")
                == .sent(newMessageID: "78321", recipients: ["me@self.test"]))
        // Reply-to-all: the RS-joined list is what MAIL populated, not the caller's prediction.
        #expect(MailScript.parseNativeCompose("ok\(Self.US)9\(Self.US)a@x.test\(Self.RS)b@x.test")
                == .sent(newMessageID: "9", recipients: ["a@x.test", "b@x.test"]))
        // A missing recipient field is tolerated (empty list), still a success.
        #expect(MailScript.parseNativeCompose("ok\(Self.US)5") == .sent(newMessageID: "5", recipients: []))
    }

    @Test func notFoundIsNilOutput() {
        // runLocated collapses "notfound" on BOTH id forms to nil.
        #expect(MailScript.parseNativeCompose(nil) == .notFound)
    }

    /// `send` returns a BOOLEAN in Mail.sdef. A false result must NOT be reported as sent.
    @Test func sendFailIsNotASuccess() {
        #expect(MailScript.parseNativeCompose("sendfail\(Self.US)4242") == .sendFailed(newMessageID: "4242"))
    }

    @Test func refusedCarriesTheOffendingAddressesAndDiscardFlag() {
        #expect(MailScript.parseNativeCompose("refused\(Self.US)outsider@x.test\(Self.US)1")
                == .refused(nonSelfRecipients: "outsider@x.test", discarded: true))
        // Multiple offenders arrive RS-joined and are rendered as a readable list.
        #expect(MailScript.parseNativeCompose("refused\(Self.US)a@x.test\(Self.RS)b@x.test\(Self.US)1")
                == .refused(nonSelfRecipients: "a@x.test, b@x.test", discarded: true))
    }

    /// `outgoing message` responds-to is save/close/send — NOT delete. If `close … saving no`
    /// fails, a message addressed to a non-self recipient is still sitting in Mail, so the
    /// discard flag MUST surface as false rather than being assumed true.
    @Test func undiscardedDraftIsReportedNotAssumedGone() {
        #expect(MailScript.parseNativeCompose("refused\(Self.US)boss@corp.test\(Self.US)0")
                == .refused(nonSelfRecipients: "boss@corp.test", discarded: false))
        // A refusal with NO discard field is read pessimistically as not-discarded.
        #expect(MailScript.parseNativeCompose("refused\(Self.US)boss@corp.test")
                == .refused(nonSelfRecipients: "boss@corp.test", discarded: false))
        // ...and the operator-facing message says so, loudly.
        let warn = refusalMessage(kind: "reply", bad: "boss@corp.test", discarded: false)
        #expect(warn.contains("could NOT be discarded"))
        #expect(warn.contains("delete it manually"))
        #expect(refusalMessage(kind: "reply", bad: "x@y.test", discarded: true).contains("was discarded"))
    }

    /// The unreadable-recipient-list sentinel the script seeds the readback with — an AppleScript
    /// error while reading recipients must refuse, not send.
    @Test func unreadableRecipientListRefuses() {
        #expect(MailScript.parseNativeCompose("refused\(Self.US)(unreadable)\(Self.US)1")
                == .refused(nonSelfRecipients: "(unreadable)", discarded: true))
    }

    /// A ZERO-recipient message must refuse: "every recipient is allowlisted" is vacuously true
    /// of the empty set, and an empty read can also mean the property access half-failed.
    @Test func zeroRecipientsRefuses() {
        #expect(MailScript.parseNativeCompose("refused\(Self.US)(no recipients populated)\(Self.US)1")
                == .refused(nonSelfRecipients: "(no recipients populated)", discarded: true))
    }

    /// A throw from the native verb itself: no draft was ever created, so there is nothing to
    /// discard — but it is still a refusal, never a success.
    @Test func createFailIsARefusalWithNothingToDiscard() {
        let o = MailScript.parseNativeCompose("createfail\(Self.US)Mail got an error: -1728")
        #expect(o == .refused(nonSelfRecipients: "(Mail could not create the message: Mail got an error: -1728)",
                              discarded: true))
    }

    /// A throw AFTER the draft exists is the dangerous shape: the draft may be addressed to a
    /// real third party. The discard result must be reported, not assumed.
    @Test func setupFailReportsWhetherTheDraftSurvived() {
        #expect(MailScript.parseNativeCompose("setupfail\(Self.US)bad sender\(Self.US)1")
                == .refused(nonSelfRecipients: "(composing the message failed: bad sender)", discarded: true))
        #expect(MailScript.parseNativeCompose("setupfail\(Self.US)bad sender\(Self.US)0")
                == .refused(nonSelfRecipients: "(composing the message failed: bad sender)", discarded: false))
        // No flag at all → pessimistic.
        #expect(MailScript.parseNativeCompose("setupfail\(Self.US)x")
                == .refused(nonSelfRecipients: "(composing the message failed: x)", discarded: false))
    }

    /// FAIL-CLOSED: anything unrecognized is a refusal, and never claims the draft was cleaned up.
    @Test func unrecognizedOutputIsARefusalNotASuccess() {
        for junk in ["", "ok", "sent", "Mail got an error: -1728", "OK\(Self.US)1", "true", "sendfail"] {
            let outcome = MailScript.parseNativeCompose(junk)
            guard case .refused(_, let discarded) = outcome else {
                Issue.record("output '\(junk)' mapped to \(outcome) — must be .refused")
                return
            }
            #expect(discarded == false)
        }
    }
}
