import Foundation
import Testing
import ArgumentParser
@testable import MailKit
import AppleKit
import TestSupport

// EVERY test in this suite runs inside `pinnedEnvironment` (see its doc). These commands read the
// sandbox AND the send/reply rate-limit budget from the process environment, so a test standing
// outside that window asserts against whatever another suite's open window, the operator's shell,
// or the PREVIOUS run of this same suite happened to leave behind. Both failure modes were
// observed on the canonical suite: a cross-suite `APPLE_TEST_SANDBOX=qa-fixture` window, and a
// forward test spending the operator's real 3-per-60s send budget. Uniform, not case-by-case, so
// the invariant is greppable: one `pinnedEnvironment` per `@Test`.
@Suite("Mail compose commands with injected dependencies", .serialized)
struct MailComposeCommandInjectionTests {
    private let scratch = ScratchDirs("mail-compose-cmd")
    /// Scoped streams plus BOTH sinks. Returning the stderr sink is what makes a warning these
    /// commands write assertable at all — including the degraded-rate-limit warnings below, whose
    /// entire contract is "on stderr, not stdout". Most tests ignore it (`_`); those tests are the
    /// reason it is returned.
    private func streams() -> (CLIStreams, MemoryOutputSink, MemoryOutputSink) {
        let stdout = MemoryOutputSink()
        let stderr = MemoryOutputSink()
        return (CLIStreams(stdout: stdout, stderr: stderr), stdout, stderr)
    }

    private func payload(from stdout: MemoryOutputSink) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: stdout.data)
        return try #require(object as? [String: Any])
    }

    private func context() throws -> MailContext {
        let fixture = EnvelopeIndexTests.makeFixture(in: try scratch.directory())
        let accountRunner = MailScriptInjectionTests.FakeMailRunner()
        accountRunner.untimedResults = [
            [
                EnvelopeIndexTests.iCloudUUID,
                "Example Account",
                "imap",
                "true",
                "sender@example.com",
            ].joined(separator: MailScript.US) + MailScript.RS,
        ]
        return try MailContext(explicitPath: fixture, accountDirectory: AccountDirectory(runner: accountRunner))
    }

    private func directory() -> AccountDirectory {
        let accountRunner = MailScriptInjectionTests.FakeMailRunner()
        accountRunner.untimedResults = [
            [
                EnvelopeIndexTests.iCloudUUID,
                "Example Account",
                "imap",
                "true",
                "sender@example.com",
            ].joined(separator: MailScript.US) + MailScript.RS,
        ]
        return AccountDirectory(runner: accountRunner)
    }

    private func scratchFile(_ label: String, contents: String = "synthetic") throws -> URL {
        let file = try scratch.directory().appendingPathComponent("\(label).txt")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The one window EVERY test in this suite runs inside. It pins two kinds of process-global
    /// state, neither of which has a seam reachable from a `ParsableCommand`:
    ///
    /// * the sandbox-engaging variables, pinned ABSENT — see `TestEnvironment` for why a READER
    ///   outside a window is exposed even though the lock serializes writers;
    /// * both rate-limiter STATE FILES. `SendRateLimiter`/`ReplyRateLimiter` default to
    ///   `~/.apple-cli/*-rate-limit.json`, resolved from the passwd entry (so exporting `HOME`
    ///   cannot redirect it) — the OPERATOR's real budget, 3 sends per 60 seconds. A test that
    ///   skipped the pin spent that budget for real and left it spent for the NEXT run, which is
    ///   what made `forwardExecuteNative…` fail 10 of 12 consecutive full runs with a
    ///   `validation_error` rate-limit refusal. Per-test scratch files give every test an empty
    ///   window and leave the operator's file untouched.
    ///
    /// The scratch paths deliberately keep the REAL `.apple-cli/<tier>-rate-limit.json` tail. The
    /// limiter tiers' own suites (`SendRateLimiterTests` / `ReplyRateLimiterTests`, both outside
    /// MailKit) assert `stateURL().path.hasSuffix(".apple-cli/…-rate-limit.json")` on the AMBIENT
    /// value; they now pin the redirects absent via `TestEnvironment.withoutRateLimitOverrides`.
    /// Preserving the tail means this window cannot falsify their assertion while it is
    /// open, so the pin costs them nothing (a flat `send-rate.json` did: it failed one full run in
    /// twelve). The distinct leaf filenames keep `stateURL() != stateURL()` true as well; the limiter
    /// mkdir-p's the parent, so nothing needs creating here.
    private func pinnedEnvironment<T>(_ body: () throws -> T) throws -> T {
        let dir = try scratch.directory().appendingPathComponent(".apple-cli", isDirectory: true)
        // `withoutWriteModeOverrides`, not `withoutSandboxOverrides`: it adds `APPLE_DRY_RUN` to
        // the same pin. Every command here runs `TestMode.validateWriteEnvironment()` first, which
        // REFUSES a non-truthy `APPLE_DRY_RUN` (exit 64) — so with an operator's
        // `APPLE_DRY_RUN=junk` exported, all 20 tests failed on a validation error before reaching
        // the branch under test, and a truthy `APPLE_DRY_RUN=1` would have silently turned every
        // `--execute` assertion into a preview.
        return try TestEnvironment.withoutWriteModeOverrides {
            try TestEnvironment.with([
                "APPLE_SEND_RATELIMIT_STATE": dir.appendingPathComponent("send-rate-limit.json").path,
                "APPLE_REPLY_RATELIMIT_STATE": dir.appendingPathComponent("reply-rate-limit.json").path,
            ], body)
        }
    }

    /// `APPLE_TEST_RECIPIENTS` gates the sandboxed self-only outbound allowlist and is read from the
    /// env at call time. `MailWriteSafetyTests` mutates the SAME variable, so both go through the
    /// one process-wide lock — two suites doing save-mutate-restore concurrently is how a safety
    /// gate ends up asserted against another suite's value.
    private func withTestRecipients<T>(_ recipients: String, _ body: () throws -> T) throws -> T {
        try TestEnvironment.with(["APPLE_TEST_RECIPIENTS": recipients], body)
    }

    @Test func sendHtmlOpenDryRunPlansEmlWithoutWritingOrOpeningMail() throws {
        try pinnedEnvironment {
            let out = try scratch.directory().appendingPathComponent("compose.eml").path
            let command = try SendCommand.parse([
                "--to", "recipient@example.com",
                "--subject", "Synthetic subject",
                "--body", "Plain fallback",
                "--html", "<p>Hello</p>",
                "--mode", "open",
                "--out", out,
                "--dry-run",
            ])
            let (streams, stdout, _) = streams()
            // Fail-closed on BOTH halves of the Mail.app boundary: the runner THROWS if AppleScript is
            // touched, and the opener THROWS if LaunchServices would raise a compose window. A fake
            // runner alone would not have caught the latter — `openEml` does not route through it.
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()
            let noOpen = MailScriptInjectionTests.ThrowingMailOpener()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: noScript, opener: noOpen) },
                                directoryFactory: { AccountDirectory(runner: MailScriptInjectionTests.FakeMailRunner()) })
            }

            #expect(noScript.neverCalled)
            #expect(noOpen.neverCalled)
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["executed"] as? Bool == false)
            #expect(data["opened"] as? Bool == false)
            #expect(data["has_html"] as? Bool == true)
            #expect(data["eml_path"] as? String == out)
            #expect(FileManager.default.fileExists(atPath: out) == false)
        }
    }

    /// The counterpart to the dry-run above, and the reason the opener seam exists: on the reliable
    /// HTML route `--execute` hands the rendered `.eml` to Mail through LaunchServices and touches
    /// AppleScript not at all. Before the seam this was the one command path that ran a real
    /// `open -a Mail` while every runner assertion still passed.
    @Test func sendExecuteHtmlOpenHandsTheEmlToTheInjectedOpener() throws {
        try pinnedEnvironment {
            let out = try scratch.directory().appendingPathComponent("compose-open.eml").path
            let command = try SendCommand.parse([
                "--to", "recipient@example.com",
                "--subject", "Synthetic subject",
                "--body", "Plain fallback",
                "--html", "<p>Hello</p>",
                "--out", out,
                "--execute",
            ])
            let (streams, stdout, _) = streams()
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()
            let opener = MailScriptInjectionTests.FakeMailOpener()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: noScript, opener: opener) },
                                directoryFactory: { directory() })
            }

            #expect(noScript.neverCalled)
            #expect(opener.openedPaths == [out])
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["opened"] as? Bool == true)
            #expect(data["executed"] as? Bool == false)
            #expect(data["eml_path"] as? String == out)
        }
    }

    @Test func sendExecutePlainUsesInjectedScriptWithoutLiveMail() throws {
        try pinnedEnvironment {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = ["sent"]
            let command = try SendCommand.parse([
                "--to", "recipient@example.com",
                "--subject", "Synthetic subject",
                "--body", "Synthetic body",
                "--execute",
            ])
            let (streams, stdout, _) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake) },
                                directoryFactory: { directory() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == false)
            #expect(data["executed"] as? Bool == true)
            #expect(data["opened"] as? Bool == false)
            #expect(fake.untimedArguments.first?[0] == "Synthetic subject")
        }
    }

    @Test func sendExecuteAttachmentUsesInjectedScriptWithoutLiveMail() throws {
        try pinnedEnvironment {
            let file = try scratchFile("send-attachment")
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = ["sent"]
            let command = try SendCommand.parse([
                "--to", "recipient@example.com",
                "--subject", "Synthetic subject",
                "--body", "Synthetic body",
                "--attach", file.path,
                "--execute",
            ])
            let (streams, stdout, _) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake) },
                                directoryFactory: { directory() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == true)
            #expect(data["eml_path"] is String)
            #expect(fake.untimedArguments.first?[5] == file.path)
        }
    }

    @Test func sendExecuteHtmlGuiSendUsesInjectedStdinRunner() throws {
        try pinnedEnvironment {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.stdinResults = ["sent"]
            let command = try SendCommand.parse([
                "--to", "recipient@example.com",
                "--subject", "Synthetic HTML",
                "--body", "Plain fallback",
                "--html", "<p>Hello</p>",
                "--gui-send",
                "--execute",
                "--test-mode",
            ])
            let (streams, stdout, _) = streams()

            try withTestRecipients("recipient@example.com") {
                try Output.withStreams(streams) {
                    try command.run(scriptFactory: { MailScript(runner: fake) },
                                    directoryFactory: { directory() })
                }
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == true)
            #expect(data["opened"] as? Bool == false)
            #expect((data["note"] as? String)?.contains("GUI keystroke") == true)
            #expect(fake.stdinArguments.count == 1)
            #expect(fake.stdinArguments.first?[1] == "Synthetic HTML")
        }
    }

    @Test func sendExecuteDraftUsesInjectedScriptWithoutLiveMail() throws {
        try pinnedEnvironment {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = ["saved"]
            let command = try SendCommand.parse([
                "--to", "recipient@example.com",
                "--subject", "apple-cli-test draft",
                "--body", "Synthetic body",
                "--mode", "draft",
                "--execute",
                "--test-mode",
            ])
            let (streams, stdout, _) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake) },
                                directoryFactory: { directory() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["drafted"] as? Bool == true)
            #expect(data["executed"] as? Bool == false)
            #expect(fake.untimedArguments.first?[0] == "apple-cli-test draft")
        }
    }

    @Test func sendExecuteHtmlDraftWritesEmlAndDoesNotTouchMail() throws {
        try pinnedEnvironment {
            let command = try SendCommand.parse([
                "--to", "recipient@example.com",
                "--subject", "apple-cli-test html draft",
                "--body", "Plain fallback",
                "--html", "<p>Hello</p>",
                "--mode", "draft",
                "--execute",
                "--test-mode",
            ])
            let (streams, stdout, _) = streams()
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()
            let noOpen = MailScriptInjectionTests.ThrowingMailOpener()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: noScript, opener: noOpen) },
                                directoryFactory: { directory() })
            }

            #expect(noScript.neverCalled)
            // The HTML draft is written and reported, never handed to Mail.
            #expect(noOpen.neverCalled)
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["drafted"] as? Bool == false)
            #expect(data["executed"] as? Bool == false)
            #expect(data["eml_path"] is String)
            #expect((data["note"] as? String)?.contains("can't be saved to Drafts headlessly") == true)
        }
    }

    @Test func replyDryRunUsesInjectedContextWithoutMailAutomation() throws {
        try pinnedEnvironment {
            let command = try ReplyCommand.parse([
                "10",
                "--body", "Synthetic reply",
                "--all",
                "--dry-run",
            ])
            let (streams, stdout, _) = streams()
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: noScript) },
                                directoryFactory: { directory() })
            }

            #expect(noScript.neverCalled)
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["action"] as? String == "reply")
            #expect(data["matched_message_id"] as? String == "10")
            #expect(data["reply_all"] as? Bool == true)
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["executed"] as? Bool == false)
            #expect(data["original_message_id"] as? String == "10")
            #expect(data["to"] as? [String] == ["alice@example.com", "me@example.com", "bob@example.org"])
        }
    }

    @Test func replyExecuteNativeUsesInjectedScriptWithoutLiveMail() throws {
        try pinnedEnvironment {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.stdinResults = [
                "ok\(MailScript.US)new-reply\(MailScript.US)alice@example.com\(MailScript.RS)",
            ]
            let command = try ReplyCommand.parse([
                "10",
                "--body", "Synthetic reply",
                "--execute",
            ])
            let (streams, stdout, _) = streams()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: fake) },
                                directoryFactory: { directory() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == true)
            #expect(data["reply_id"] as? String == "new-reply")
            #expect(data["to"] as? [String] == ["alice@example.com"])
        }
    }

    @Test func forwardDryRunUsesInjectedContextWithoutMailAutomation() throws {
        try pinnedEnvironment {
            let command = try ForwardCommand.parse([
                "--subject", "Hello",
                "--account", "Example Account",
                "--mailbox", "All",
                "--to", "recipient@example.com",
                "--cc", "copy@example.com",
                "--dry-run",
            ])
            let (streams, stdout, _) = streams()
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: noScript) },
                                directoryFactory: { directory() })
            }

            #expect(noScript.neverCalled)
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["action"] as? String == "forward")
            #expect(data["matched_message_id"] as? String == "12")
            #expect(data["sender_address"] == nil)
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["executed"] as? Bool == false)
            #expect(data["recipients"] as? [String] == ["recipient@example.com"])
        }
    }

    @Test func forwardExecuteNativeUsesInjectedScriptWithoutLiveMail() throws {
        try pinnedEnvironment {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.stdinResults = [
                "ok\(MailScript.US)new-forward\(MailScript.US)recipient@example.com\(MailScript.RS)",
            ]
            let command = try ForwardCommand.parse([
                "10",
                "--to", "recipient@example.com",
                "--body", "Synthetic prepend",
                "--execute",
            ])
            let (streams, stdout, _) = streams()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: fake) },
                                directoryFactory: { directory() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == true)
            #expect(data["forward_id"] as? String == "new-forward")
            #expect(data["recipients"] as? [String] == ["recipient@example.com"])
        }
    }

    @Test func draftRichDryRunReportsDeterministicPathWithoutWriting() throws {
        try pinnedEnvironment {
            let command = try DraftRichCommand.parse([
                "--account", "Example Account",
                "--subject", "Synthetic Rich Draft",
                "--to", "recipient@example.com",
                "--html", "<p>Hello</p>",
                "--no-open",
                "--dry-run",
            ])
            let (streams, stdout, _) = streams()
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()
            let noOpen = MailScriptInjectionTests.ThrowingMailOpener()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: noScript, opener: noOpen) },
                                directoryFactory: { directory() })
            }

            #expect(noScript.neverCalled)
            #expect(noOpen.neverCalled)
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            let emlPath = try #require(data["eml_path"] as? String)
            #expect(emlPath.hasSuffix("/Library/Caches/apple-cli/rich-drafts/Synthetic-Rich-Draft.eml"))
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["opened"] as? Bool == false)
            #expect(data["sender_address"] == nil)
            #expect(FileManager.default.fileExists(atPath: emlPath) == false)
        }
    }

    @Test func draftRichExecuteNoOpenWritesSyntheticEmlWithoutMailAutomation() throws {
        try pinnedEnvironment {
            let out = try scratch.directory().appendingPathComponent("synthetic.eml")
            let fake = MailScriptInjectionTests.FakeMailRunner()
            let command = try DraftRichCommand.parse([
                "--account", "Example Account",
                "--subject", "Synthetic Rich Draft",
                "--to", "recipient@example.com",
                "--cc", "copy@example.com",
                "--bcc", "blind@example.com",
                "--text-body", "Plain body",
                "--html", "<p>Plain body</p>",
                "--out", out.path,
                "--no-open",
                "--execute",
            ])
            let (streams, stdout, _) = streams()
            let noOpen = MailScriptInjectionTests.ThrowingMailOpener()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                directoryFactory: { directory() })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(noOpen.neverCalled)                 // --no-open really means no LaunchServices call
            #expect(data["dry_run"] as? Bool == false)
            #expect(data["opened"] as? Bool == false)
            #expect(data["eml_path"] as? String == out.path)
            #expect(data["sender_address"] as? String == "sender@example.com")
            #expect(data["cc"] as? [String] == ["copy@example.com"])
            #expect(data["bcc"] as? [String] == ["blind@example.com"])
            #expect(fake.untimedArguments.isEmpty)
            let eml = try String(contentsOf: out, encoding: .utf8)
            #expect(eml.contains("Subject: Synthetic Rich Draft"))
            #expect(eml.contains("Bcc: blind@example.com"))
        }
    }

    /// `draft-rich` opens by DEFAULT (`--open`/`--no-open`, defaulting to true), so this is the
    /// path an author would most easily reach without noticing — and, before the opener seam, the
    /// path that would have raised a real compose window under `#expect(noScript.neverCalled)`.
    /// `--save-as-draft` additionally routes back through the runner, so both seams are asserted:
    /// the opener got the written `.eml`, and the save attempt went to the fake runner.
    @Test func draftRichExecuteOpenAndSaveUseBothInjectedSeams() throws {
        try pinnedEnvironment {
            let out = try scratch.directory().appendingPathComponent("rich-open.eml")
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = ["saved"]
            let opener = MailScriptInjectionTests.FakeMailOpener()
            let command = try DraftRichCommand.parse([
                "--account", "Example Account",
                "--subject", "Synthetic Rich Draft",
                "--to", "recipient@example.com",
                "--text-body", "Plain body",
                "--out", out.path,
                "--save-as-draft",
                "--execute",
            ])
            let (streams, stdout, _) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake, opener: opener) },
                                directoryFactory: { directory() })
            }

            #expect(opener.openedPaths == [out.path])
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["opened"] as? Bool == true)
            #expect(data["saved"] as? Bool == true)
            #expect(fake.untimedArguments == [["Synthetic Rich Draft"]])
        }
    }

    @Test func draftRichNoClobberRefusesExistingOutputBeforeMailAutomation() throws {
        try pinnedEnvironment {
            let out = try scratch.directory().appendingPathComponent("existing.eml")
            try "existing".write(to: out, atomically: true, encoding: .utf8)
            let command = try DraftRichCommand.parse([
                "--subject", "Synthetic Rich Draft",
                "--to", "recipient@example.com",
                "--text-body", "Plain body",
                "--out", out.path,
                "--no-open",
                "--no-clobber",
                "--execute",
            ])
            let (streams, stdout, _) = streams()
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()
            let noOpen = MailScriptInjectionTests.ThrowingMailOpener()

            do {
                try Output.withStreams(streams) {
                    try command.run(scriptFactory: { MailScript(runner: noScript, opener: noOpen) },
                                    directoryFactory: { directory() })
                }
                Issue.record("expected no-clobber refusal to exit")
            } catch let exitCode as ExitCode {
                #expect(exitCode.rawValue == 77)
            }

            #expect(noScript.neverCalled)
            #expect(noOpen.neverCalled)
            let payload = try payload(from: stdout)
            #expect(payload["ok"] as? Bool == false)
            let error = try #require(payload["error"] as? [String: Any])
            #expect(error["type"] as? String == "safety_violation")
            #expect((error["message"] as? String)?.contains("--no-clobber") == true)
            #expect(try String(contentsOf: out, encoding: .utf8) == "existing")
        }
    }

    @Test func draftCommandsUseInjectedScriptForListCreateAndDelete() throws {
        try pinnedEnvironment {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = [
                [
                    "apple-cli-test draft",
                    "recipient@example.com",
                    "2026-01-01",
                ].joined(separator: MailScript.US) + MailScript.RS,
                "ok",
                "2",
            ]
            let script = MailScript(runner: fake)

            let list = try DraftCommand.parse(["list"])
            let (listStreams, listStdout, _) = streams()
            try Output.withStreams(listStreams) {
                try list.run(scriptFactory: { script }, directoryFactory: { directory() })
            }
            let listData = try #require(try payload(from: listStdout)["data"] as? [String: Any])
            #expect(listData["count"] as? Int == 1)

            let create = try DraftCommand.parse([
                "create",
                "--subject", "apple-cli-test draft",
                "--to", "recipient@example.com",
                "--body", "Synthetic body",
                "--execute",
                "--test-mode",
            ])
            let (createStreams, createStdout, _) = streams()
            try Output.withStreams(createStreams) {
                try create.run(scriptFactory: { script }, directoryFactory: { directory() })
            }
            let createData = try #require(try payload(from: createStdout)["data"] as? [String: Any])
            #expect(createData["executed"] as? Bool == true)

            let delete = try DraftCommand.parse([
                "delete",
                "--subject", "apple-cli-test draft",
                "--execute",
                "--test-mode",
            ])
            let (deleteStreams, deleteStdout, _) = streams()
            try Output.withStreams(deleteStreams) {
                try delete.run(scriptFactory: { script }, directoryFactory: { directory() })
            }
            let deleteData = try #require(try payload(from: deleteStdout)["data"] as? [String: Any])
            #expect(deleteData["executed"] as? Bool == true)
            #expect((deleteData["note"] as? String)?.contains("deleted 2 draft") == true)
        }
    }

    // MARK: - Degraded rate limiter warns on stderr, and only on stderr
    //
    // `SendRateLimiter`/`ReplyRateLimiter` FAIL OPEN: when their state file cannot be read or
    // written they permit the call and set `degraded`, and each of the four compose call sites
    // (send, reply, forward, draft send) is then responsible for saying so. That warning is the
    // ONLY signal the operator gets that a runaway-loop cap silently stopped applying, and it has
    // two halves that are equally load-bearing: it must be EMITTED, and it must go to stderr —
    // stdout is the versioned JSON contract, and a warning line prepended there turns every
    // machine consumer's parse into a syntax error. Both halves are asserted below, per call site:
    // deleting an `if rl.degraded` block or swapping its `Output.writeError` for `Output.write`
    // fails these tests and nothing else.

    /// A rate-limit state path whose parent can never be created: a regular FILE with further path
    /// components appended, so the limiter's `mkdir -p` of the parent fails with `ENOTDIR`. That is
    /// `RateLimitStore.load`'s `.unreadable` branch — allow, `degraded`. The write is never
    /// attempted: `load` returns `.unreadable` the moment `createDirectory` throws, and `consume`
    /// returns straight from that case.
    ///
    /// A path under `/dev/null` also produces this today, but it rests on how this OS treats a
    /// path below a character device; "a component of the path is a regular file" is plain POSIX
    /// and stays true if that ever changes.
    private func unwritableStatePath(_ label: String) throws -> String {
        try scratchFile("ratelimit-\(label)")
            .appendingPathComponent("x", isDirectory: true)
            .appendingPathComponent("state.json").path
    }

    /// Nest inside `pinnedEnvironment`, which already redirects both limiters to writable scratch
    /// files: this re-points ONE of them at an unwritable path for the duration. The restore is the
    /// outer window's value, not the operator's — so a degraded window can never leak into the
    /// operator's real `~/.apple-cli` state.
    private func degraded<T>(_ variable: String, _ label: String, _ body: () throws -> T) throws -> T {
        try TestEnvironment.with([variable: try unwritableStatePath(label)], body)
    }

    private static let sendWarning =
        "warning: send rate-limit state is unwritable — the oracle's 3-sends/60s cap "
        + "is NOT being enforced for this call (failing open).\n"
    private static let replyWarning =
        "warning: reply rate-limit state is unwritable — the oracle's 20-replies/60s "
        + "(expensive_ops) cap is NOT being enforced for this call (failing open).\n"

    /// The LaunchServices half of the Mail.app boundary, fail-closed. `openEml` does not route
    /// through the AppleScript runner, so a fake runner alone leaves the real
    /// `LaunchServicesMailOpener()` default live and a stray `--mode open` regression would raise a
    /// compose window on the operator's desktop mid-test. Every `MailScript` these degraded-warning
    /// tests build takes one, and asserts it was never called.
    private func noMailApp() -> MailScriptInjectionTests.ThrowingMailOpener {
        MailScriptInjectionTests.ThrowingMailOpener()
    }

    /// Assert the two halves at once: `expected` is exactly what stderr carries, and stdout parses
    /// as a single JSON envelope that contains no part of it. Parsing is the strict half — a
    /// warning written to stdout would sit in front of the envelope and make this throw.
    private func expectWarning(_ expected: String, stdout: MemoryOutputSink,
                               stderr: MemoryOutputSink) throws -> [String: Any] {
        #expect(String(decoding: stderr.data, as: UTF8.self) == expected)
        let rendered = String(decoding: stdout.data, as: UTF8.self)
        #expect(!rendered.contains("rate-limit state is unwritable"),
                "the warning must not reach the JSON contract stream")
        let payload = try payload(from: stdout)
        #expect(payload["ok"] as? Bool == true, "the limiter fails OPEN — the call still succeeds")
        return try #require(payload["data"] as? [String: Any])
    }

    @Test func sendExecuteWarnsOnStderrWhenTheSendRateLimitStateIsUnwritable() throws {
        try pinnedEnvironment {
            try degraded("APPLE_SEND_RATELIMIT_STATE", "send") {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.untimedResults = ["sent"]
                let noOpen = noMailApp()
                let command = try SendCommand.parse([
                    "--to", "recipient@example.com",
                    "--subject", "Synthetic subject",
                    "--body", "Synthetic body",
                    "--execute",
                ])
                let (streams, stdout, stderr) = streams()

                try Output.withStreams(streams) {
                    try command.run(scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                    directoryFactory: { directory() })
                }

                let data = try expectWarning(Self.sendWarning, stdout: stdout, stderr: stderr)
                #expect(data["executed"] as? Bool == true, "failing open means the send still happens")
                #expect(noOpen.neverCalled)
            }
        }
    }

    /// `forward` consumes the SAME `sends` bucket as `send`, but through its own `consume` +
    /// `if rl.degraded` block — so it needs its own test: deleting the block at one call site
    /// leaves the other's test green.
    @Test func forwardExecuteWarnsOnStderrWhenTheSendRateLimitStateIsUnwritable() throws {
        try pinnedEnvironment {
            try degraded("APPLE_SEND_RATELIMIT_STATE", "forward") {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.stdinResults = [
                    "ok\(MailScript.US)new-forward\(MailScript.US)recipient@example.com\(MailScript.RS)",
                ]
                let noOpen = noMailApp()
                let command = try ForwardCommand.parse([
                    "10",
                    "--to", "recipient@example.com",
                    "--execute",
                ])
                let (streams, stdout, stderr) = streams()

                try Output.withStreams(streams) {
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                    directoryFactory: { directory() })
                }

                let data = try expectWarning(Self.sendWarning, stdout: stdout, stderr: stderr)
                #expect(data["executed"] as? Bool == true)
                #expect(noOpen.neverCalled)
            }
        }
    }

    /// `reply` is on the SEPARATE `expensive_ops` window with its own state file and its own
    /// wording (20/60s, not 3/60s). Pinning the send file unwritable must not warn here, and this
    /// asserts the reply text verbatim, so the two warnings cannot be transposed.
    @Test func replyExecuteWarnsOnStderrWhenTheReplyRateLimitStateIsUnwritable() throws {
        try pinnedEnvironment {
            try degraded("APPLE_REPLY_RATELIMIT_STATE", "reply") {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.stdinResults = [
                    "ok\(MailScript.US)new-reply\(MailScript.US)alice@example.com\(MailScript.RS)",
                ]
                let noOpen = noMailApp()
                let command = try ReplyCommand.parse([
                    "10",
                    "--body", "Synthetic reply",
                    "--execute",
                ])
                let (streams, stdout, stderr) = streams()

                try Output.withStreams(streams) {
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                    directoryFactory: { directory() })
                }

                let data = try expectWarning(Self.replyWarning, stdout: stdout, stderr: stderr)
                #expect(data["executed"] as? Bool == true)
                #expect(noOpen.neverCalled)
            }
        }
    }

    /// `draft send` delivers real mail from an existing Drafts item, so it consumes the `sends`
    /// bucket like `send`/`forward` — the fourth and most easily forgotten call site.
    @Test func draftSendWarnsOnStderrWhenTheSendRateLimitStateIsUnwritable() throws {
        try pinnedEnvironment {
            try degraded("APPLE_SEND_RATELIMIT_STATE", "draft-send") {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.untimedResults = ["sent"]
                let noOpen = noMailApp()
                let command = try DraftCommand.parse([
                    "send",
                    "--subject", "apple-cli-test draft",
                    "--execute",
                    "--test-mode",
                ])
                let (streams, stdout, stderr) = streams()

                try withTestRecipients("recipient@example.com") {
                    try Output.withStreams(streams) {
                        try command.run(scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                        directoryFactory: { directory() })
                    }
                }

                let data = try expectWarning(Self.sendWarning, stdout: stdout, stderr: stderr)
                #expect(data["executed"] as? Bool == true)
                #expect(noOpen.neverCalled)
            }
        }
    }

    // MARK: - Rate-limit REFUSAL: the guard itself, at each of the four call sites
    //
    // Every test above drives the limiter fail-OPEN (`allowed == true`), so deleting a
    // `guard rl.allowed else { throw … }` at any call site left the suite green — the cap's
    // warning was tested and the cap itself was not. These drive `allowed == false` by handing
    // each call site a state file whose window is already FULL, and pin three things: the refusal
    // is the `validation` error (exit 64, not a silent no-op), nothing reached the AppleScript
    // runner or LaunchServices (the refusal precedes the send), and the refusal text names the
    // tier's cap, so the operator can tell a rate-limit refusal from any other validation error.

    /// Point `variable` at a scratch state file already holding `calls` stamps inside the window,
    /// so the NEXT `consume` refuses. Nests inside `pinnedEnvironment` like `degraded` does, and
    /// the stamps are `now` — the far edge of the window, so a slow test cannot age them out.
    private func exhausted<T>(_ variable: String, _ label: String, calls: Int,
                              _ body: () throws -> T) throws -> T {
        let file = try scratch.directory().appendingPathComponent("exhausted-\(label).json")
        let stamps = Array(repeating: Date().timeIntervalSince1970, count: calls)
        try JSONEncoder().encode(stamps).write(to: file)
        return try TestEnvironment.with([variable: file.path], body)
    }

    /// Run a compose command expected to be REFUSED by its rate limiter. `runGuarded` converts the
    /// thrown `AppleError` into the error envelope on stdout plus an `ExitCode`, so both halves
    /// are read back from there: exit 64 and `error.type == validation`, with a message that names
    /// the tier's cap.
    private func expectRateLimitRefusal(tier: String, stdout: MemoryOutputSink,
                                        _ body: () throws -> Void) throws {
        var exit: ExitCode?
        do { try body() } catch let code as ExitCode { exit = code }
        #expect(try #require(exit, "the call site must refuse").rawValue == AppleExit.usage)
        let envelope = try payload(from: stdout)
        #expect(envelope["ok"] as? Bool == false)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["type"] as? String == AppleErrorType.validation)
        let message = error["message"] as? String ?? ""
        #expect(message.contains("Rate limit exceeded"), Comment(rawValue: message))
        #expect(message.contains(tier), Comment(rawValue: message))
    }

    @Test func sendExecuteIsRefusedWhenTheSendWindowIsFull() throws {
        try pinnedEnvironment {
            try exhausted("APPLE_SEND_RATELIMIT_STATE", "send", calls: SendRateLimiter.maxCalls) {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.untimedResults = ["sent"]
                let noOpen = noMailApp()
                let command = try SendCommand.parse([
                    "--to", "recipient@example.com",
                    "--subject", "Synthetic subject",
                    "--body", "Synthetic body",
                    "--execute",
                ])
                let (streams, stdout, _) = streams()

                try expectRateLimitRefusal(tier: "sends", stdout: stdout) {
                    try Output.withStreams(streams) {
                        try command.run(scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                        directoryFactory: { directory() })
                    }
                }
                #expect(fake.neverCalled, "the refusal must precede the send")
                #expect(noOpen.neverCalled)
            }
        }
    }

    @Test func forwardExecuteIsRefusedWhenTheSendWindowIsFull() throws {
        try pinnedEnvironment {
            try exhausted("APPLE_SEND_RATELIMIT_STATE", "forward", calls: SendRateLimiter.maxCalls) {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.stdinResults = [
                    "ok\(MailScript.US)new-forward\(MailScript.US)recipient@example.com\(MailScript.RS)",
                ]
                let noOpen = noMailApp()
                let command = try ForwardCommand.parse([
                    "10",
                    "--to", "recipient@example.com",
                    "--body", "Synthetic prepend",
                    "--execute",
                ])
                let (streams, stdout, _) = streams()

                try expectRateLimitRefusal(tier: "sends", stdout: stdout) {
                    try Output.withStreams(streams) {
                        try command.run(contextFactory: { try context() },
                                        scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                        directoryFactory: { directory() })
                    }
                }
                #expect(fake.neverCalled)
                #expect(noOpen.neverCalled)
            }
        }
    }

    @Test func replyExecuteIsRefusedWhenTheReplyWindowIsFull() throws {
        try pinnedEnvironment {
            try exhausted("APPLE_REPLY_RATELIMIT_STATE", "reply", calls: ReplyRateLimiter.maxCalls) {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.stdinResults = [
                    "ok\(MailScript.US)new-reply\(MailScript.US)alice@example.com\(MailScript.RS)",
                ]
                let noOpen = noMailApp()
                let command = try ReplyCommand.parse([
                    "10",
                    "--body", "Synthetic reply",
                    "--execute",
                ])
                let (streams, stdout, _) = streams()

                try expectRateLimitRefusal(tier: "expensive_ops", stdout: stdout) {
                    try Output.withStreams(streams) {
                        try command.run(contextFactory: { try context() },
                                        scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                        directoryFactory: { directory() })
                    }
                }
                #expect(fake.neverCalled)
                #expect(noOpen.neverCalled)
            }
        }
    }

    @Test func draftSendIsRefusedWhenTheSendWindowIsFull() throws {
        try pinnedEnvironment {
            try exhausted("APPLE_SEND_RATELIMIT_STATE", "draft-send", calls: SendRateLimiter.maxCalls) {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.untimedResults = ["sent"]
                let noOpen = noMailApp()
                let command = try DraftCommand.parse([
                    "send",
                    "--subject", "apple-cli-test draft",
                    "--execute",
                    "--test-mode",
                ])
                let (streams, stdout, _) = streams()

                try expectRateLimitRefusal(tier: "sends", stdout: stdout) {
                    try withTestRecipients("recipient@example.com") {
                        try Output.withStreams(streams) {
                            try command.run(scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                            directoryFactory: { directory() })
                        }
                    }
                }
                #expect(fake.neverCalled)
                #expect(noOpen.neverCalled)
            }
        }
    }

    /// A window one short of full still ALLOWS — so the four refusals above come from the cap,
    /// not from the exhausted-state fixture being unusable. One control for the shared fixture.
    @Test func sendExecuteIsAllowedWhenTheSendWindowHasOneSlotLeft() throws {
        try pinnedEnvironment {
            try exhausted("APPLE_SEND_RATELIMIT_STATE", "send-control", calls: SendRateLimiter.maxCalls - 1) {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.untimedResults = ["sent"]
                let noOpen = noMailApp()
                let command = try SendCommand.parse([
                    "--to", "recipient@example.com",
                    "--subject", "Synthetic subject",
                    "--body", "Synthetic body",
                    "--execute",
                ])
                let (streams, stdout, _) = streams()
                try Output.withStreams(streams) {
                    try command.run(scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                    directoryFactory: { directory() })
                }
                let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
                #expect(data["executed"] as? Bool == true)
                #expect(noOpen.neverCalled)
            }
        }
    }

    /// The SECOND way a call site sees `degraded`, and the one the fixtures above cannot reach.
    /// `RateLimitStore.load` has two degrading arms: `.unreadable` (the state file cannot be read
    /// at all — what every test above pins) and `.corrupt` (the file IS readable but does not
    /// decode as a `[TimeInterval]`, so the window silently resets to empty). The corrupt arm is
    /// the more dangerous of the two: a persistently-unparseable file resets the cap to zero on
    /// EVERY call, so without the warning a runaway loop would face no cap at all and nothing on
    /// any stream would say so.
    ///
    /// The remaining `degraded` sources are deliberately not fixtured here:
    ///
    /// * `!wrote` on the allowed path (the state file loads fine but the save fails) needs a
    ///   readable state file inside an unwritable directory — a combination neither fixture above
    ///   can produce, since an unwritable parent makes `load` return `.unreadable` first. Its
    ///   observable outcome at the call site is byte-identical to both arms that ARE covered
    ///   (allowed + degraded + this same warning), so the extra chmod fixture would exercise no
    ///   new line of the command.
    /// * `degraded` on the REFUSAL path is unreachable as a warning by construction: every call
    ///   site is `guard rl.allowed else { throw … }` FOLLOWED by `if rl.degraded { warn }`, so a
    ///   degraded refusal leaves as a validation error and never reaches the warning block.
    @Test func sendExecuteWarnsOnStderrWhenTheSendRateLimitStateIsCorrupt() throws {
        try pinnedEnvironment {
            // Readable, decodable as UTF-8, and NOT a JSON array of numbers — the torn-write /
            // hand-edited shape `load` classifies `.corrupt` rather than `.unreadable`.
            let corrupt = try scratchFile("ratelimit-corrupt", contents: "{not a window}")
            try TestEnvironment.with(["APPLE_SEND_RATELIMIT_STATE": corrupt.path]) {
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.untimedResults = ["sent"]
                let noOpen = noMailApp()
                let command = try SendCommand.parse([
                    "--to", "recipient@example.com",
                    "--subject", "Synthetic subject",
                    "--body", "Synthetic body",
                    "--execute",
                ])
                let (streams, stdout, stderr) = streams()

                try Output.withStreams(streams) {
                    try command.run(scriptFactory: { MailScript(runner: fake, opener: noOpen) },
                                    directoryFactory: { directory() })
                }

                let data = try expectWarning(Self.sendWarning, stdout: stdout, stderr: stderr)
                #expect(data["executed"] as? Bool == true, "the limiter fails open on a corrupt file")
                #expect(noOpen.neverCalled)
                // The corrupt file is REPLACED by a valid one-stamp window, which is what makes the
                // reset silent without the warning: the next call reads a clean, plausible state.
                let rewritten = try Data(contentsOf: corrupt)
                #expect((try? JSONDecoder().decode([TimeInterval].self, from: rewritten))?.count == 1)
            }
        }
    }
}
