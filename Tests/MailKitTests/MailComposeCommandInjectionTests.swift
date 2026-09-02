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
    private func streams() -> (CLIStreams, MemoryOutputSink) {
        let stdout = MemoryOutputSink()
        return (CLIStreams(stdout: stdout, stderr: MemoryOutputSink()), stdout)
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
        return try TestEnvironment.withoutSandboxOverrides {
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
            let (streams, stdout) = streams()
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
            let (streams, stdout) = streams()
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
            let (streams, stdout) = streams()

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
            let (streams, stdout) = streams()

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
            let (streams, stdout) = streams()

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
            let (streams, stdout) = streams()

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
            let (streams, stdout) = streams()
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
            let (streams, stdout) = streams()
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
            let (streams, stdout) = streams()

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
            let (streams, stdout) = streams()
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
            let (streams, stdout) = streams()

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
            let (streams, stdout) = streams()
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
            let (streams, stdout) = streams()
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
            let (streams, stdout) = streams()

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
            let (streams, stdout) = streams()
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
            let (listStreams, listStdout) = streams()
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
            let (createStreams, createStdout) = streams()
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
            let (deleteStreams, deleteStdout) = streams()
            try Output.withStreams(deleteStreams) {
                try delete.run(scriptFactory: { script }, directoryFactory: { directory() })
            }
            let deleteData = try #require(try payload(from: deleteStdout)["data"] as? [String: Any])
            #expect(deleteData["executed"] as? Bool == true)
            #expect((deleteData["note"] as? String)?.contains("deleted 2 draft") == true)
        }
    }
}
