import Foundation
import Testing
@testable import MailKit
import AppleKit

// The fakes below neutralize the Mail.app boundary — AppleScript via `MailAppleScriptExecuting`,
// LaunchServices via `MailAppOpening`. They do NOT neutralize the process environment: the safety
// gates a command runs before it reaches a runner read `APPLE_TEST_SANDBOX` / `APPLE_TEST_MODE` /
// `APPLE_TEST_RECIPIENTS` (and the limiters read `APPLE_*_RATELIMIT_STATE`) straight from the
// process, with no seam. So injecting a fake is only half of an isolated test: any test that
// drives a command through those gates must ALSO run inside a `TestEnvironment.with` window that
// pins the variables it depends on — see `TestEnvironment`'s doc, and `pinnedEnvironment` in
// `MailComposeCommandInjectionTests` for the worked form.
@Suite("Mail AppleScript injection")
struct MailScriptInjectionTests {
    /// Records BOTH halves of every call: the argv the wrapper passed, and the script SOURCE it
    /// passed them alongside. Recording the source is what makes the RCE-class invariant assertable
    /// — argv-only assertions are positive-only ("the value appears at arguments[N]") and cannot
    /// distinguish argv-passing from argv-passing PLUS interpolation into the source.
    ///
    /// `@unchecked Sendable` confinement argument: every field is unsynchronized, and that is safe
    /// only because a fake is constructed inside one test and never escapes it. swift-testing runs
    /// a single test body on one task, so there is no concurrent access. Sharing one instance
    /// across concurrent work would break this; don't.
    final class FakeMailRunner: MailAppleScriptExecuting, @unchecked Sendable {
        struct TimedCall: Equatable {
            let arguments: [String]
            let timeout: TimeInterval
        }

        var untimedResults: [String] = []
        var timedResults: [String] = []
        var stdinResults: [String] = []
        var untimedArguments: [[String]] = []
        var timedCalls: [TimedCall] = []
        var stdinArguments: [[String]] = []
        private(set) var untimedScripts: [String] = []
        private(set) var timedScripts: [String] = []
        private(set) var stdinScripts: [String] = []

        /// Every script source this runner was handed, in call order across all three modes.
        var allScripts: [String] { untimedScripts + timedScripts + stdinScripts }

        /// True when nothing at all reached the runner.
        var neverCalled: Bool {
            untimedArguments.isEmpty && timedCalls.isEmpty && stdinArguments.isEmpty
        }

        /// What a mode does once its scripted results run out.
        ///
        /// `.fail` (the default) THROWS. The empty string used to be returned instead, and that is
        /// a silent trap on any wrapper that retries: `saveOpenDraft` loops 10 × 0.5s on anything
        /// that is neither `"saved"` nor an `"error:"`-prefixed string, so a test that forgot to
        /// stub it would have stalled five seconds and then asserted against a fabricated `false`
        /// rather than failing on the missing stub. Failing fast turns a missing stub into an
        /// immediate, named error.
        ///
        /// `.empty` restores the old behavior for the wrappers that legitimately probe more than
        /// once and treat "" as "not found" — `body`, `mutateLocated`, and friends try the
        /// bracketed then the bare message-id form, so a one-result stub is correct there.
        enum Exhaustion { case fail, empty }
        var whenExhausted: Exhaustion = .fail

        private func next(_ results: inout [String], mode: String) throws -> String {
            if !results.isEmpty { return results.removeFirst() }
            switch whenExhausted {
            case .empty: return ""
            case .fail:
                throw AppleError.upstream(
                    "FakeMailRunner: no scripted \(mode) result left — stub one, or set "
                    + "`whenExhausted = .empty` if this wrapper legitimately probes until empty.")
            }
        }

        func run(_ script: String, arguments: [String]) throws -> String {
            untimedScripts.append(script)
            untimedArguments.append(arguments)
            return try next(&untimedResults, mode: "untimed")
        }

        func run(_ script: String, arguments: [String], timeout seconds: TimeInterval) throws -> String {
            timedScripts.append(script)
            timedCalls.append(TimedCall(arguments: arguments, timeout: seconds))
            return try next(&timedResults, mode: "timed")
        }

        func runViaStdin(_ script: String, arguments: [String]) throws -> String {
            stdinScripts.append(script)
            stdinArguments.append(arguments)
            return try next(&stdinResults, mode: "stdin")
        }
    }

    /// Records `openEml` calls instead of raising a real Mail compose window. The LaunchServices
    /// half of the Mail.app boundary (`MailAppOpening`) — a fake RUNNER does not cover it.
    ///
    /// `@unchecked Sendable`: same single-test confinement argument as `FakeMailRunner`.
    final class FakeMailOpener: MailAppOpening, @unchecked Sendable {
        private(set) var openedPaths: [String] = []
        var neverCalled: Bool { openedPaths.isEmpty }

        func openEml(path: String) throws { openedPaths.append(path) }
    }

    /// The FAIL-CLOSED opener, the `ThrowingMailRunner` of the LaunchServices seam: pass it
    /// wherever a path must NOT raise a Mail compose window, so a refactor that moves an
    /// `openEml` above a dry-run `return` goes red instead of opening Mail on the operator's
    /// machine. Records the attempt for the call sites that swallow errors.
    ///
    /// `@unchecked Sendable`: same single-test confinement argument as `FakeMailRunner`.
    final class ThrowingMailOpener: MailAppOpening, @unchecked Sendable {
        private(set) var attempts: [String] = []
        var neverCalled: Bool { attempts.isEmpty }

        func openEml(path: String) throws {
            attempts.append(path)
            throw AppleError.upstream(
                "ThrowingMailOpener: this code path must not open Mail.app (path: \(path))")
        }
    }

    /// The FAIL-CLOSED runner: use it wherever a code path is expected NOT to touch AppleScript.
    /// It throws on every mode, so a refactor that moves a script call above a dry-run `return`
    /// turns a silently-passing test red instead of driving the operator's real Mail.app. It also
    /// RECORDS the attempt, because a handful of production paths wrap the call in `try?` and would
    /// otherwise swallow the throw — those call sites assert `neverCalled` explicitly.
    ///
    /// `@unchecked Sendable`: same single-test confinement argument as `FakeMailRunner`.
    final class ThrowingMailRunner: MailAppleScriptExecuting, @unchecked Sendable {
        private(set) var attempts: [[String]] = []
        var neverCalled: Bool { attempts.isEmpty }

        private func refuse(_ arguments: [String]) throws -> Never {
            attempts.append(arguments)
            throw AppleError.upstream(
                "ThrowingMailRunner: this code path must not reach AppleScript (argv: \(arguments))")
        }

        func run(_ script: String, arguments: [String]) throws -> String { try refuse(arguments) }

        func run(_ script: String, arguments: [String], timeout seconds: TimeInterval) throws -> String {
            try refuse(arguments)
        }

        func runViaStdin(_ script: String, arguments: [String]) throws -> String { try refuse(arguments) }
    }

    /// An AppleScript-hostile string: a quote-break into `do shell script`, plus a backslash, a
    /// newline, and both quote flavours. If any wrapper concatenated a user value into its script
    /// source, this payload would change that source (and, on a live runner, execute).
    static let hostilePayload = "\" & (do shell script \"id\") & \"\nback\\slash 'single' \"double\""

    @Test func accountDirectoryLoadsFromInjectedRunner() {
        let fake = FakeMailRunner()
        fake.untimedResults = [
            [
                "ACCOUNT-1",
                "Example Account",
                "imap",
                "true",
                "sender@example.com,alt@example.com",
            ].joined(separator: MailScript.US) + MailScript.RS,
        ]

        let directory = AccountDirectory(runner: fake)

        #expect(directory.isLoaded)
        #expect(directory.resolveUUID("Example Account") == "ACCOUNT-1")
        #expect(directory.name(forUUID: "ACCOUNT-1") == "Example Account")
        #expect(directory.sendAddress(for: "ACCOUNT-1") == "sender@example.com")
        #expect(fake.untimedArguments == [[]])
    }

    @Test func accountDirectoryNormalizesTypesAndFallsBackWhenRunnerFails() {
        #expect(AccountDirectory.normalizeType(" iCloud IMAP ") == "iCloud")
        #expect(AccountDirectory.normalizeType("Exchange Web Services") == "exchange")
        #expect(AccountDirectory.normalizeType(" POP ") == "pop")
        #expect(AccountDirectory.normalizeType(" ") == "unknown")

        let directory = AccountDirectory(runner: ThrowingMailRunner())
        #expect(directory.isLoaded == false)
        #expect(directory.accounts.isEmpty)
        #expect(directory.loadError != nil)
        #expect(directory.name(forUUID: "ACCOUNT-1") == "ACCOUNT-1")
        #expect(directory.resolveUUID("Example Account") == nil)
        #expect(directory.displayName(for: "Example Account") == nil)
        #expect(directory.sendAddress(for: "Example Account") == nil)
    }

    @Test func mailScriptUsesInjectedTimedRunnerForBodySearch() throws {
        let fake = FakeMailRunner()
        fake.timedResults = ["id-1@example.com\(MailScript.RS)"]
        let script = MailScript(runner: fake)

        let ids = try script.bodySearch(
            needle: "needle",
            subjectTerms: ["subject"],
            sender: "sender@example.com",
            readStatus: false,
            flagged: true,
            fromUnix: nil,
            toUnix: nil,
            hasAttachment: true,
            accountName: "Example Account",
            mailboxName: "INBOX",
            collectLimit: 3,
            includeSystemFolders: true,
            hostTimeout: 12)

        #expect(ids == ["id-1@example.com"])
        #expect(fake.timedCalls.count == 1)
        #expect(fake.timedCalls.first?.timeout == 12)
        #expect(fake.timedCalls.first?.arguments[0] == "needle")
        #expect(fake.timedCalls.first?.arguments[3] == "unread")
        #expect(fake.timedCalls.first?.arguments[7] == "flagged")
        #expect(fake.timedCalls.first?.arguments[11] == "include")
        #expect(fake.untimedArguments.isEmpty)
    }

    @Test func mailScriptUsesInjectedStdinRunnerForGuiHtmlSend() throws {
        let fake = FakeMailRunner()
        fake.stdinResults = ["sent"]
        let script = MailScript(runner: fake)

        try script.sendHtmlViaGui(
            htmlPath: "/tmp/synthetic.html",
            subject: "Synthetic subject",
            to: ["recipient@example.com"],
            cc: [],
            bcc: [],
            attachmentPaths: ["/tmp/synthetic.txt"],
            sender: "sender@example.com")

        let arguments = try #require(fake.stdinArguments.first)
        #expect(arguments[0] == "/tmp/synthetic.html")
        #expect(arguments[1] == "Synthetic subject")
        #expect(arguments[2] == "recipient@example.com")
        #expect(arguments[3] == "")
        #expect(arguments[4] == "")
        #expect(arguments[5] == "/tmp/synthetic.txt")
        #expect(arguments[6] == "sender@example.com")
        #expect(arguments[7].hasPrefix("[apple-cli-"))
    }

    @Test func mailScriptSendWrappersUseInjectedRunnerArguments() throws {
        let fake = FakeMailRunner()
        fake.untimedResults = ["sent"]
        let script = MailScript(runner: fake)

        try script.send(
            subject: "Synthetic subject",
            body: "Synthetic body",
            to: ["to@example.com"],
            cc: ["cc@example.com"],
            bcc: ["bcc@example.com"],
            sender: "sender@example.com")

        let sendArgs = try #require(fake.untimedArguments.first)
        #expect(sendArgs[0] == "Synthetic subject")
        #expect(sendArgs[2] == "to@example.com")
        #expect(sendArgs[3] == "cc@example.com")
        #expect(sendArgs[4] == "bcc@example.com")
        #expect(sendArgs[5] == "sender@example.com")

        fake.untimedResults = ["sent"]
        try script.sendWithAttachments(
            subject: "Attachment subject",
            body: "Attachment body",
            to: ["to@example.com"],
            cc: [],
            bcc: [],
            attachmentPaths: ["/tmp/synthetic.pdf"],
            sender: nil)

        let attachmentArgs = try #require(fake.untimedArguments.last)
        #expect(attachmentArgs[0] == "Attachment subject")
        #expect(attachmentArgs[5] == "/tmp/synthetic.pdf")
        #expect(attachmentArgs[6] == "")
    }

    @Test func nativeReplyAndForwardUseInjectedStdinRunner() throws {
        let fake = FakeMailRunner()
        fake.stdinResults = [
            "ok\(MailScript.US)new-reply\(MailScript.US)to@example.com\(MailScript.RS)",
            "drafted\(MailScript.US)new-forward\(MailScript.US)to@example.com\(MailScript.RS)",
        ]
        let script = MailScript(runner: fake)

        let reply = try script.nativeReplyHtml(
            internetMessageID: "message@example.com",
            accountName: "Example Account",
            replyAll: true,
            sender: "sender@example.com",
            selfAllowlist: ["to@example.com"],
            cc: ["copy@example.com"],
            bcc: [],
            attachmentPaths: ["/tmp/synthetic.pdf"],
            mailboxHint: "INBOX",
            mode: "send",
            htmlFragmentPath: "/tmp/reply.html")
        #expect(reply == .sent(newMessageID: "new-reply", recipients: ["to@example.com"]))

        let forward = try script.nativeForward(
            internetMessageID: "<message@example.com>",
            accountName: "Example Account",
            htmlFragmentPath: "/tmp/forward.html",
            to: ["to@example.com"],
            cc: [],
            bcc: [],
            sender: nil,
            selfAllowlist: ["to@example.com"],
            mailboxHint: "INBOX")
        #expect(forward == .drafted(newMessageID: "new-forward", recipients: ["to@example.com"]))
        #expect(fake.stdinArguments.count == 2)
        #expect(fake.stdinArguments[0].first == "<message@example.com>")
        #expect(fake.stdinArguments[1].first == "<message@example.com>")
    }

    @Test func mailScriptMailboxTrashAttachmentAndDraftWrappersUseInjectedRunner() throws {
        let fake = FakeMailRunner()
        fake.untimedResults = [
            ["INBOX", "2"].joined(separator: MailScript.US) + MailScript.RS
                + ["Deleted Messages", "3"].joined(separator: MailScript.US) + MailScript.RS,
            ["INBOX", "2"].joined(separator: MailScript.US) + MailScript.RS
                + ["Deleted Messages", "3"].joined(separator: MailScript.US) + MailScript.RS,
            "2/3/1",
            "0" + MailScript.RS,
            "ok",
            "apple-cli-test draft\(MailScript.US)recipient@example.com\(MailScript.US)2026-01-01\(MailScript.RS)",
            "ok",
            "2",
            "sent\(MailScript.US)recipient@example.com",
            "saved",
            "opened",
        ]
        let script = MailScript(runner: fake)

        let boxes = try script.allMailboxes(accountName: "Example Account")
        #expect(boxes.map(\.name) == ["INBOX", "Deleted Messages"])
        #expect(try script.trashMailboxes(accountName: "Example Account").map(\.name) == ["Deleted Messages"])

        let empty = try script.emptyTrash(accountName: "Example Account", mailboxName: "Deleted Messages", max: 3)
        #expect(empty.removed == 2)
        #expect(empty.total == 3)
        #expect(empty.stalled)

        let saved = try script.saveAttachments(
            internetMessageID: "message@example.com",
            accountName: "Example Account",
            pairs: [(index: 0, destPath: "/tmp/synthetic.pdf")])
        #expect(saved == [0])

        try script.createMailbox(accountName: "Example Account", path: "apple-cli-test Mailbox")

        let drafts = try script.listDrafts()
        #expect(drafts.first?.subject == "apple-cli-test draft")

        try script.createDraft(
            subject: "apple-cli-test draft",
            body: "Synthetic body",
            to: ["recipient@example.com"],
            sender: "sender@example.com")
        #expect(try script.deleteDrafts(subject: "apple-cli-test draft", prefix: "apple-cli-test") == 2)

        let sent = try script.sendDraft(
            subject: "apple-cli-test draft",
            prefix: "apple-cli-test",
            account: nil,
            allowlist: ["recipient@example.com"],
            recipientCap: 100)
        #expect(sent == .sent(["recipient@example.com"]))

        try script.saveDraft(
            subject: "apple-cli-test draft",
            body: "Synthetic body",
            to: ["recipient@example.com"],
            cc: [],
            bcc: [],
            attachmentPaths: [],
            sender: nil)
        #expect(try script.openDraft(subject: "apple-cli-test draft", account: nil) == true)
    }

    // MARK: - Script SOURCE safety (the RCE-class invariant)
    //
    // These are the tests the suite's name promises. Everything above asserts that a value lands at
    // a known argv position — necessary, but positive-only: a wrapper that ALSO concatenated the
    // value into its script source would satisfy every one of them. Each test below runs a wrapper
    // twice, once benign and once with `hostilePayload`, and asserts three things:
    //
    //   1. the script SOURCE is byte-identical across the two runs — no input reaches it at all;
    //   2. the payload does not appear anywhere in the recorded source;
    //   3. the payload DOES appear in argv, so the value was actually delivered, not dropped.
    //
    // (1) is the load-bearing one. Absence checks alone can be defeated by an escaping scheme that
    // still builds source from input; invariance cannot.

    /// Assert the argv-only contract for one wrapper, given the two runners it was exercised with.
    private func expectSourceInvariant(benign: FakeMailRunner,
                                       hostile: FakeMailRunner,
                                       payloadReachedArgv: Bool,
                                       _ label: Comment) {
        #expect(!benign.allScripts.isEmpty, label)
        #expect(benign.allScripts == hostile.allScripts, label)
        #expect(hostile.allScripts.allSatisfy { !$0.contains(Self.hostilePayload) }, label)
        #expect(hostile.allScripts.allSatisfy { !$0.contains("(do shell script \"id\")") }, label)
        #expect(payloadReachedArgv, label)
    }

    @Test func sendScriptSourceIsInvariantUnderHostileInput() throws {
        func exercise(_ value: String) throws -> FakeMailRunner {
            let runner = FakeMailRunner()
            runner.untimedResults = ["sent"]
            try MailScript(runner: runner).send(
                subject: value, body: value,
                to: [value], cc: [value], bcc: [value], sender: value)
            return runner
        }

        let benign = try exercise("plain subject")
        let hostile = try exercise(Self.hostilePayload)

        expectSourceInvariant(
            benign: benign, hostile: hostile,
            payloadReachedArgv: hostile.untimedArguments.first?.contains(Self.hostilePayload) == true,
            "send")
    }

    @Test func sendWithAttachmentsScriptSourceIsInvariantUnderHostileInput() throws {
        func exercise(_ value: String) throws -> FakeMailRunner {
            let runner = FakeMailRunner()
            runner.untimedResults = ["sent"]
            try MailScript(runner: runner).sendWithAttachments(
                subject: value, body: value, to: [value], cc: [], bcc: [],
                attachmentPaths: ["/tmp/synthetic.pdf"], sender: value)
            return runner
        }

        let benign = try exercise("plain subject")
        let hostile = try exercise(Self.hostilePayload)

        expectSourceInvariant(
            benign: benign, hostile: hostile,
            payloadReachedArgv: hostile.untimedArguments.first?.contains(Self.hostilePayload) == true,
            "sendWithAttachments")
    }

    @Test func bodySearchScriptSourceIsInvariantUnderHostileInput() throws {
        func exercise(_ value: String) throws -> FakeMailRunner {
            let runner = FakeMailRunner()
            runner.timedResults = ["id-1@example.com\(MailScript.RS)"]
            _ = try MailScript(runner: runner).bodySearch(
                needle: value, subjectTerms: [value], sender: value,
                readStatus: nil, flagged: nil, fromUnix: nil, toUnix: nil,
                hasAttachment: nil, accountName: value, mailboxName: value,
                collectLimit: 3, includeSystemFolders: false, hostTimeout: 12)
            return runner
        }

        let benign = try exercise("needle")
        let hostile = try exercise(Self.hostilePayload)

        expectSourceInvariant(
            benign: benign, hostile: hostile,
            payloadReachedArgv: hostile.timedCalls.first?.arguments.contains(Self.hostilePayload) == true,
            "bodySearch")
    }

    /// The stdin/AppleScriptObjC mode, and the one wrapper whose FIXED source legitimately contains
    /// `do shell script` (it `cat`s the HTML fragment path). That is exactly why invariance, not a
    /// blanket substring ban, is the assertion that generalises: the source is allowed to contain
    /// anything as long as no input can change it.
    @Test func guiHtmlSendScriptSourceIsInvariantUnderHostileInput() throws {
        func exercise(_ value: String) throws -> FakeMailRunner {
            let runner = FakeMailRunner()
            runner.stdinResults = ["sent"]
            try MailScript(runner: runner).sendHtmlViaGui(
                htmlPath: "/tmp/synthetic.html", subject: value,
                to: [value], cc: [], bcc: [], attachmentPaths: [], sender: value)
            return runner
        }

        let benign = try exercise("plain subject")
        let hostile = try exercise(Self.hostilePayload)

        #expect(benign.stdinScripts == hostile.stdinScripts)
        #expect(hostile.stdinScripts.allSatisfy { !$0.contains(Self.hostilePayload) })
        let arguments = try #require(hostile.stdinArguments.first)
        #expect(arguments[1] == Self.hostilePayload)
        #expect(arguments[2] == Self.hostilePayload)
    }

    @Test func nativeReplyScriptSourceIsInvariantUnderHostileInput() throws {
        func exercise(_ value: String) throws -> FakeMailRunner {
            let runner = FakeMailRunner()
            runner.stdinResults = ["ok\(MailScript.US)new-reply\(MailScript.US)to@example.com\(MailScript.RS)"]
            _ = try MailScript(runner: runner).nativeReplyHtml(
                internetMessageID: value, accountName: value, replyAll: true,
                sender: value, selfAllowlist: [value], cc: [value], bcc: [],
                attachmentPaths: [], mailboxHint: value, mode: "send",
                htmlFragmentPath: "/tmp/reply.html")
            return runner
        }

        let benign = try exercise("message@example.com")
        let hostile = try exercise(Self.hostilePayload)

        expectSourceInvariant(
            benign: benign, hostile: hostile,
            payloadReachedArgv: hostile.stdinArguments.first?.contains(Self.hostilePayload) == true,
            "nativeReplyHtml")
    }

    /// The SECOND shared locator helper. `runLocated` is pinned transitively through
    /// `nativeReplyHtml` above; `mutateLocated` had no invariance test at all, and it is the one
    /// that backs the mutation family — `setRead`, `setFlag`, and the trash/delete wrappers. Those
    /// were covered only by argv-position assertions, which are positive-only: they establish that
    /// the value reached argv, never that it did not ALSO reach the source. Pinning the shared
    /// helper covers the whole family in one test, the same way `nativeReplyHtml` covers
    /// `runLocated`.
    ///
    /// `mutateLocated` composes its source as `body + "\n" + locator` from two static constants, so
    /// invariance also proves that composition carries no input — the shape most likely to tempt a
    /// future edit into interpolating the message id.
    @Test func mutateLocatedScriptSourceIsInvariantUnderHostileInput() throws {
        func exercise(_ value: String) throws -> FakeMailRunner {
            let runner = FakeMailRunner()
            runner.untimedResults = ["ok"]
            _ = try MailScript(runner: runner).setFlag(
                internetMessageID: value, accountName: value, flagged: true, colorIndex: 2)
            return runner
        }

        let benign = try exercise("message@example.com")
        let hostile = try exercise(Self.hostilePayload)

        expectSourceInvariant(
            benign: benign, hostile: hostile,
            payloadReachedArgv: hostile.untimedArguments.first?.contains(Self.hostilePayload) == true,
            "setFlag / mutateLocated")
    }

    /// The LaunchServices seam is fail-closed the same way the runner seam is, and `openEml`
    /// really does route through it — so injecting a fake opener is enough to keep a compose
    /// window off the operator's screen.
    @Test func openerSeamRecordsThePathAndTheThrowingOpenerRefuses() throws {
        let recorder = FakeMailOpener()
        #expect(recorder.neverCalled)
        try MailScript(runner: ThrowingMailRunner(), opener: recorder).openEml(path: "/tmp/synthetic.eml")
        #expect(recorder.openedPaths == ["/tmp/synthetic.eml"])

        let refuser = ThrowingMailOpener()
        #expect(throws: AppleError.self) {
            try MailScript(runner: ThrowingMailRunner(), opener: refuser).openEml(path: "/tmp/synthetic.eml")
        }
        #expect(refuser.neverCalled == false)
    }

    /// A stub that runs out is a test defect, not a `""` result: `saveOpenDraft` would otherwise
    /// spin its 10 × 0.5s retry loop and then report a fabricated `false`.
    @Test func fakeRunnerFailsFastWhenScriptedResultsAreExhausted() throws {
        let runner = FakeMailRunner()
        #expect(throws: AppleError.self) {
            try MailScript(runner: runner).send(
                subject: "s", body: "b", to: ["recipient@example.com"], cc: [], bcc: [], sender: nil)
        }

        // …and the opt-out restores the probe-until-empty behavior the multi-candidate wrappers need.
        let probing = FakeMailRunner()
        probing.whenExhausted = .empty
        #expect(try MailScript(runner: probing).body(internetMessageID: "m@example.com", accountName: nil) == nil)
        #expect(probing.untimedArguments.count == 2)   // bracketed form, then bare
    }

    /// A runner that must not be called is fail-closed, not merely unasserted: it THROWS.
    @Test func throwingRunnerRefusesEveryModeAndRecordsTheAttempt() {
        let runner = ThrowingMailRunner()
        #expect(runner.neverCalled)
        #expect(throws: AppleError.self) {
            try MailScript(runner: runner).send(
                subject: "s", body: "b", to: ["recipient@example.com"], cc: [], bcc: [], sender: nil)
        }
        #expect(runner.neverCalled == false)
    }
}
