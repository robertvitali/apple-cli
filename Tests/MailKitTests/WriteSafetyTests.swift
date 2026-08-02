import Testing
import Foundation
@testable import MailKit
import AppleKit

// Logic-tier coverage for the Mail WRITE-SAFETY gates under WRITE-MODEL V2
// (docs/write-model-v2.md): the gates are SANDBOX-PARAMETERIZED pure functions — sandboxActive
// is an argument, so both branches are exercised as pure calls with no APPLE_TEST_MODE env
// mutation (the one thing the old suite had to serialize around). The env reads that remain
// (APPLE_TEST_RECIPIENTS / APPLE_TEST_SANDBOX) are still set + restored per test, so the suite
// stays `.serialized`.
//
// The v2 CONTRACT under test: UNSANDBOXED, the gates impose no restriction (the CLI behaves
// like the MCP — sends to any recipient, mutates any message); SANDBOXED, the self-only
// allowlist and the label gate hold exactly as v1's did.

@Suite("Mail write-safety gates (write-model v2)", .serialized)
struct MailWriteSafetyTests {

    /// Set the allowlist/sandbox-prefix env for the duration of `body`, restoring after.
    private func withEnv(recipients: String?, sandbox: String? = nil, _ body: () -> Void) {
        func get(_ k: String) -> String? { getenv(k).map { String(cString: $0) } }
        func set(_ k: String, _ v: String?) { if let v { setenv(k, v, 1) } else { unsetenv(k) } }
        let prev = (get("APPLE_TEST_RECIPIENTS"), get("APPLE_TEST_SANDBOX"))
        set("APPLE_TEST_RECIPIENTS", recipients)
        set("APPLE_TEST_SANDBOX", sandbox)
        defer { set("APPLE_TEST_RECIPIENTS", prev.0); set("APPLE_TEST_SANDBOX", prev.1) }
        body()
    }

    /// Build a MailMessage with a controllable subject + Message-ID (no store needed).
    private func msg(subject: String, imid: String?) -> MailMessage {
        MailMessage.fromSelection(.init(applescriptID: "1", internetMessageID: imid, subject: subject,
                                        sender: "me@self.test", readStatus: false, flagged: false, dateReceived: nil, content: nil))
    }

    // MARK: guardOutbound (send / reply / forward)

    @Test("UNSANDBOXED outbound is unrestricted — any recipient is allowed (MCP parity)")
    func outboundUnsandboxedUnrestricted() {
        withEnv(recipients: nil) {
            #expect(throws: Never.self) {
                try guardOutbound(recipients: ["someone-else@example.com"], sandboxActive: false, applyRecipientCap: true)
            }
        }
    }

    @Test("outbound refuses an EMPTY recipient list in both modes (validation, not sandbox)")
    func outboundRefusesEmptyRecipients() {
        withEnv(recipients: "me@self.test") {
            #expect(throws: AppleError.self) { try guardOutbound(recipients: [], sandboxActive: false, applyRecipientCap: true) }
            #expect(throws: AppleError.self) { try guardOutbound(recipients: [], sandboxActive: true, applyRecipientCap: true) }
        }
    }

    @Test("SANDBOXED outbound refuses a non-allowlisted recipient — the self-only guarantee")
    func outboundSandboxRefusesNonSelf() {
        withEnv(recipients: "me@self.test") {
            let err = #expect(throws: AppleError.self) {
                try guardOutbound(recipients: ["me@self.test", "someone-else@example.com"], sandboxActive: true, applyRecipientCap: true)
            }
            #expect(err?.exitCode == 77)          // safety_violation, not a generic failure
        }
    }

    @Test("SANDBOXED outbound allows when every recipient is an allowlisted self address")
    func outboundSandboxAllowsSelfOnly() {
        withEnv(recipients: "me@self.test,alias@self.test") {
            #expect(throws: Never.self) {
                try guardOutbound(recipients: ["me@self.test", "alias@self.test"], sandboxActive: true, applyRecipientCap: true)
            }
        }
    }

    @Test("SANDBOXED outbound refuses when the allowlist is empty (fail-closed inside the sandbox)")
    func outboundSandboxRefusesEmptyAllowlist() {
        withEnv(recipients: nil) {
            #expect(throws: AppleError.self) { try guardOutbound(recipients: ["me@self.test"], sandboxActive: true, applyRecipientCap: true) }
        }
    }

    // MARK: requireLiveMessageMutation (mark / flag / move / delete-to-trash)

    @Test("SANDBOXED mutation gate refuses a REAL (unlabeled) message — protects real mail")
    func mutationSandboxRefusesUnlabeled() {
        withEnv(recipients: nil) {
            let err = #expect(throws: AppleError.self) {
                _ = try requireLiveMessageMutation(msg(subject: "Q3 planning notes", imid: "abc@id"), sandboxActive: true)
            }
            #expect(err?.exitCode == 77)
        }
    }

    @Test("UNSANDBOXED mutation gate resolves a REAL message — the oracle mutates real mail on call")
    func mutationUnsandboxedAllowsReal() {
        withEnv(recipients: nil) {
            let imid = try? requireLiveMessageMutation(msg(subject: "Q3 planning notes", imid: "real@id"), sandboxActive: false)
            #expect(imid == "real@id")
        }
    }

    @Test("mutation gate refuses a message with no RFC Message-ID in BOTH modes (cannot address it)")
    func mutationRefusesNoMessageID() {
        withEnv(recipients: nil) {
            #expect(throws: AppleError.self) {
                _ = try requireLiveMessageMutation(msg(subject: "apple-cli-test hi", imid: nil), sandboxActive: true)
            }
            #expect(throws: AppleError.self) {
                _ = try requireLiveMessageMutation(msg(subject: "anything", imid: nil), sandboxActive: false)
            }
        }
    }

    @Test("SANDBOXED mutation gate RETURNS the Message-ID for a labeled message")
    func mutationSandboxAllowsLabeled() {
        withEnv(recipients: nil) {
            let imid = try? requireLiveMessageMutation(msg(subject: "apple-cli-test hello", imid: "wanted@id"), sandboxActive: true)
            #expect(imid == "wanted@id")
        }
    }

    @Test("a custom APPLE_TEST_SANDBOX prefix is honored by the sandboxed label gate")
    func mutationHonorsCustomPrefix() {
        withEnv(recipients: nil, sandbox: "qa-fixture") {
            // A message labeled with the custom prefix passes; the default prefix no longer does.
            #expect((try? requireLiveMessageMutation(msg(subject: "qa-fixture x", imid: "i@d"), sandboxActive: true)) == "i@d")
            #expect(throws: AppleError.self) {
                _ = try requireLiveMessageMutation(msg(subject: "apple-cli-test x", imid: "i@d"), sandboxActive: true)
            }
        }
    }

    // MARK: splitRecipients (pure)

    @Test("splitRecipients flattens repeated + comma-joined options, trims, drops empties")
    func splitRecipientsParsing() throws {
        #expect(try splitRecipients(["a@x.com,b@y.com", " c@z.com "]) == ["a@x.com", "b@y.com", "c@z.com"])
        #expect(try splitRecipients(["a@x.com, ,b@x.com"]) == ["a@x.com", "b@x.com"])
        #expect(try splitRecipients([]) == [])
    }

    // MARK: executeMessageMutation — the all-or-nothing batch guarantee (sandboxed), and the
    // unsandboxed pass-through.

    @Test("SANDBOXED: a mixed batch aborts before ANY op runs — real mail is never partially mutated")
    func batchAllOrNothingSandboxed() {
        withEnv(recipients: nil) {
            var opCalls = 0
            let batch = [msg(subject: "apple-cli-test one", imid: "a@id"),
                         msg(subject: "Real inbox mail", imid: "b@id"),   // unlabeled → must abort the whole batch
                         msg(subject: "apple-cli-test three", imid: "c@id")]
            #expect(throws: AppleError.self) {
                _ = try executeMessageMutation(batch, sandboxActive: true) { _, _ in opCalls += 1; return true }
            }
            #expect(opCalls == 0)   // phase-1 gate threw before any phase-2 mutation
        }
    }

    @Test("UNSANDBOXED: a mixed batch applies to every addressable target (MCP parity)")
    func batchUnsandboxedAppliesAll() {
        withEnv(recipients: nil) {
            var opCalls = 0
            let batch = [msg(subject: "apple-cli-test one", imid: "a@id"),
                         msg(subject: "Real inbox mail", imid: "b@id")]
            let result = try? executeMessageMutation(batch, sandboxActive: false) { _, _ in opCalls += 1; return true }
            #expect(opCalls == 2)
            #expect(result?.applied.count == 2)
        }
    }

    @Test("an all-labeled batch applies to every target")
    func batchAllLabeled() {
        withEnv(recipients: nil) {
            var opCalls = 0
            let batch = [msg(subject: "apple-cli-test one", imid: "a@id"),
                         msg(subject: "apple-cli-test two", imid: "b@id")]
            let result = try? executeMessageMutation(batch, sandboxActive: true) { _, _ in opCalls += 1; return true }
            #expect(opCalls == 2)
            #expect(result?.applied.count == 2)
            #expect(result?.notFound.isEmpty == true)
        }
    }

    @Test("a located-but-unmutable target collects into not_found instead of throwing")
    func batchNotFound() {
        withEnv(recipients: nil) {
            let batch = [msg(subject: "apple-cli-test x", imid: "a@id")]
            // op returns false → Mail couldn't locate it (e.g. archived); reported, not thrown.
            let result = try? executeMessageMutation(batch, sandboxActive: true) { _, _ in false }
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
        #expect(MailScript.DraftSendResult.parse("wrongwindow", us: US) == .wrongWindow)
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

/// The allowlist handed to the AppleScript dispatch layer, and the per-surface execute defaults.
/// Both are one-expression decisions a refactor could silently invert with every suite green —
/// review round 1 demanded these pins.
@Suite("Outbound allowlist selection + per-surface defaults (write-model v2)")
struct OutboundAllowlistAndDefaultsTests {

    @Test("unsandboxed: the out-of-sandbox wildcard, regardless of what the env list holds")
    func unsandboxedIsWildcard() {
        #expect(outboundAllowlist(sandboxActive: false, allowed: ["a@self.test"]) == ["*"])
        #expect(outboundAllowlist(sandboxActive: false, allowed: []) == ["*"])
    }

    @Test("sandboxed: the operator's list passes through — minus any literal '*' (in-band sentinel)")
    func sandboxedFiltersWildcard() {
        #expect(outboundAllowlist(sandboxActive: true, allowed: ["a@self.test", "b@self.test"])
                == ["a@self.test", "b@self.test"])
        // APPLE_TEST_RECIPIENTS="*" must NOT disable the ACTIVE sandbox's recipient check:
        // the wildcard is the script layer's own sentinel, never derivable from operator data.
        #expect(outboundAllowlist(sandboxActive: true, allowed: ["*"]) == [])
        #expect(outboundAllowlist(sandboxActive: true, allowed: ["a@self.test", "*"]) == ["a@self.test"])
    }

    @Test("sandboxed: an entry CONTAINING a control character is dropped — the US-joined argv would re-split it into extra entries (incl. the sentinel)")
    func sandboxedFiltersControlCharEntries() {
        // "a@x\u{1F}*" would materialize as TWO entries after the in-script split — the second
        // being the wildcard sentinel, silently disabling the ACTIVE sandbox (review-caught).
        #expect(outboundAllowlist(sandboxActive: true, allowed: ["a@x.test\u{1F}*"]) == [])
        #expect(outboundAllowlist(sandboxActive: true, allowed: ["ok@self.test", "bad\u{1E}entry"]) == ["ok@self.test"])
        #expect(outboundAllowlist(sandboxActive: true, allowed: ["nul\u{00}x"]) == [])
    }

    @Test("splitRecipients refuses a control character — US would split one vetted address into two")
    func splitRecipientsRefusesControlCharacters() throws {
        // The list is US-joined into the send/draft argv; an embedded US would produce a second
        // address that guardOutbound's allowlist comparison never saw.
        #expect(throws: AppleError.self) { _ = try splitRecipients(["a@self.test\u{1F}evil@x.test"]) }
        #expect(throws: AppleError.self) { _ = try splitRecipients(["ok@self.test", "b\u{1E}d@x.test"]) }
        // Legitimate splitting/trimming is unchanged.
        #expect(try splitRecipients(["a@x.test, b@x.test", " c@x.test "]) == ["a@x.test", "b@x.test", "c@x.test"])
    }

    @Test("outboundAddressFromIndex takes the bare addr-spec and refuses a control character in it")
    func outboundAddressFromIndexStripsAndRefuses() throws {
        // The display name is REMOTE data (a hostile sender's decoded RFC-2047 name) and is
        // discarded outright — including a US byte planted in it, which would otherwise inject
        // an extra recipient after the in-script split on the --gui-send route.
        #expect(try outboundAddressFromIndex("Ops\u{1F}Ops <attacker@evil.test>\u{1F}pad <ops@victim.test>")
                == "ops@victim.test")
        #expect(try outboundAddressFromIndex("Display Name <a@x.test>") == "a@x.test")
        #expect(try outboundAddressFromIndex("  bare@x.test ") == "bare@x.test")
        // A control character in the ADDRESS itself (not the name) still refuses.
        #expect(throws: AppleError.self) { _ = try outboundAddressFromIndex("Name <a@x.test\u{1F}b@y.test>") }
    }

    @Test("resolveAttachmentPath refuses a control character in the path — US would split one vetted path into two")
    func attachmentPathRefusesControlCharacters() {
        for p in ["/tmp/a\u{1F}/Users/x/.ssh/id_rsa", "/tmp/a\u{1E}b", "/tmp/a\nb", "/tmp/a\u{7F}b"] {
            do {
                _ = try resolveAttachmentPath(p)
                Issue.record("accepted \(String(reflecting: p))")
            } catch let e as AppleError {
                #expect(e.exitCode == AppleExit.permissionDenied)  // 77 — the mailSafety refusal
            } catch {
                Issue.record("wrong error type for \(String(reflecting: p)): \(error)")
            }
        }
    }

    @Test("the TRASH surface keeps dry-run as its default — the spec's most safety-critical carve-out")
    func trashSurfaceDefaults() {
        // Flipping either static to false makes a FLAGLESS delete/trash-empty touch real mail
        // by default while the rest of the suite stays green (every other invocation carries an
        // explicit flag or the env brake). The bats default-pin tests lock the behavior; these
        // lock the source-level constants the run() paths read.
        #expect(DeleteCommand.surfaceDefaultDryRun == true)
        #expect(TrashEmpty.surfaceDefaultDryRun == true)
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
                                        sender: "me@self.test", readStatus: false, flagged: false, dateReceived: nil, content: nil))
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
        // ...and the operator-facing message says so, loudly — in both modes.
        let warn = refusalMessage(kind: "reply", bad: "boss@corp.test", discarded: false, sandboxActive: true)
        #expect(warn.contains("could NOT be discarded"))
        #expect(warn.contains("delete it manually"))
        #expect(warn.contains("self-only allowlist"))
        #expect(refusalMessage(kind: "reply", bad: "x@y.test", discarded: true, sandboxActive: true)
                    .contains("was discarded"))
        // Unsandboxed, the allowlist claim would be false — the message must not make it. The
        // only unsandboxed-reachable `bad` is the empty-address sentinel, named plainly.
        let unsand = refusalMessage(kind: "reply", bad: "x@y.test", discarded: true, sandboxActive: false)
        #expect(!unsand.contains("allowlist"))
        #expect(refusalMessage(kind: "reply", bad: "<empty-address>", discarded: true, sandboxActive: false)
                    .contains("empty/blank recipient address"))
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
