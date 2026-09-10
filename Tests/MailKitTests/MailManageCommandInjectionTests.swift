import Foundation
import Testing
import ArgumentParser
@testable import MailKit
import AppleKit
import TestSupport

// `.serialized` because `withOperatorEnv` mutates the process-global `APPLE_ALLOW_EMPTY_TRASH`
// gate on an irreversible operation. That trait only orders tests WITHIN this suite; the
// cross-suite half of the invariant is `TestEnvironment`'s process-wide lock.
//
// EVERY test here also runs inside `TestEnvironment.withoutWriteModeOverrides`, because the lock
// orders MUTATORS and these tests are READERS: the mutation commands consult
// `TestMode.sandboxActive` / `sandboxPrefix` from the process environment, so a test outside a
// window asserts against whatever another suite's window — or the operator's shell — holds.
// Uniform, not case-by-case, so the invariant is greppable: one `withoutWriteModeOverrides` per
// `@Test`.
//
// The pin covers `APPLE_DRY_RUN` as well as the sandbox trio, because every write command here
// first runs `TestMode.validateWriteEnvironment()`, which REFUSES a non-truthy `APPLE_DRY_RUN`
// with exit 64 — so an operator's `APPLE_DRY_RUN=junk` export failed these tests on a validation
// error before they reached the branch under test, and a truthy `APPLE_DRY_RUN=1` would have
// silently turned every `--execute` assertion into a preview.
@Suite("Mail manage commands with injected dependencies", .serialized)
struct MailManageCommandInjectionTests {
    private let scratch = ScratchDirs("mail-manage-cmd")
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
        let runner = MailScriptInjectionTests.FakeMailRunner()
        runner.untimedResults = [
            [
                EnvelopeIndexTests.iCloudUUID,
                "Example Account",
                "imap",
                "true",
                "sender@example.com",
            ].joined(separator: MailScript.US) + MailScript.RS,
        ]
        return try MailContext(explicitPath: fixture, accountDirectory: AccountDirectory(runner: runner))
    }

    /// `TrashEmpty` reads its operator gate straight from the process env, so the test has to set
    /// it for real. Routed through `TestEnvironment` so the window is serialized against every
    /// other suite that touches `APPLE_*`, not merely against this one.
    private func withOperatorEnv<T>(_ name: String, value: String, _ body: () throws -> T) throws -> T {
        try TestEnvironment.with([name: value], body)
    }

    private func message(subject: String) -> MailMessage {
        MailMessage(
            id: "10",
            message_id: "10",
            rowid: 10,
            internet_message_id: "synthetic@example.com",
            subject: subject,
            sender: "sender@example.com",
            mailbox: "INBOX",
            account: "Example Account",
            read_status: false,
            is_read: false,
            flagged: false,
            has_attachments: false,
            attachment_count: 0
        )
    }

    @Test func previewSandboxValidationAllowsLabeledSyntheticTargets() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            #expect(throws: Never.self) {
                try previewValidateSandboxTargets([message(subject: "apple-cli-test synthetic")], sandboxActive: true)
            }
        }
    }

    @Test func previewSandboxValidationRefusesUnlabeledSyntheticTargets() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let err = #expect(throws: AppleError.self) {
                try previewValidateSandboxTargets([message(subject: "ordinary synthetic")], sandboxActive: true)
            }
            #expect(err?.exitCode == 77)
            #expect(err?.message.contains("sandbox active") == true)
        }
    }

    @Test func requireMailboxKnownRejectsUnknownMailboxInSyntheticContext() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let ctx = try context()
            let err = #expect(throws: AppleError.self) {
                try requireMailboxKnown(ctx: ctx, name: "Missing", accountUUID: nil)
            }
            #expect(err?.exitCode == 65)
            #expect(err?.message.contains("unknown mailbox") == true)
        }
    }

    @Test func resolveMessageRowRejectsEmptyAndDecodesMessageLinks() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let ctx = try context()

            let err = #expect(throws: AppleError.self) {
                _ = try resolveMessageRow(ctx: ctx, id: "   ")
            }
            #expect(err?.exitCode == 64)

            let row = try #require(try resolveMessageRow(ctx: ctx, id: "message://%3Cmsg10%40host%3E"))
            #expect(row["rowid"] as? String == "10")
        }
    }

    @Test func emitMessagesTextPrintsRowsAndPaginationHints() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let message = MailMessage(
                id: "10",
                message_id: "10",
                rowid: 10,
                internet_message_id: "synthetic@example.com",
                subject: "Synthetic subject",
                sender: "sender@example.com",
                mailbox: "INBOX",
                account: "Example Account",
                read_status: false,
                is_read: false,
                flagged: true,
                flag_color_name: "red",
                date_received: "2026-09-01T00:00:00Z",
                has_attachments: false,
                attachment_count: 0,
                snippet: "Synthetic snippet",
                to: ["recipient@example.com"],
                cc: ["copy@example.com"]
            )
            var result = MailMessagesResult(
                account: "Example Account",
                mailbox: "All",
                messages: [message],
                count: 1,
                offset: 0,
                limit: 1,
                has_more: true,
                next_offset: 1,
                sort: "newest"
            )
            result.system_folders_excluded = true
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try emitMessages(result, json: false)
            }

            let output = String(decoding: stdout.data, as: UTF8.self)
            #expect(output.contains("[10]"))
            #expect(output.contains("Synthetic subject"))
            #expect(output.contains("recipient@example.com"))
            #expect(output.contains("copy@example.com"))
        }
    }

    @Test func moveMarkFlagAndDeletePreviewsUseInjectedContext() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let commands: [(String, () throws -> Void)] = [
                ("move", {
                    let command = try MoveCommand.parse([
                        "--match-subject", "Hello",
                        "--account", "Example Account",
                        "--source", "INBOX",
                        "--to", "Archive",
                        "--dry-run",
                    ])
                    let noScript = MailScriptInjectionTests.ThrowingMailRunner()
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: noScript) })
                    #expect(noScript.neverCalled)
                }),
                ("mark_read", {
                    let command = try MarkCommand.parse([
                        "--match-subject", "Hello",
                        "--account", "Example Account",
                        "--read",
                        "--dry-run",
                    ])
                    let noScript = MailScriptInjectionTests.ThrowingMailRunner()
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: noScript) })
                    #expect(noScript.neverCalled)
                }),
                ("flag", {
                    let command = try FlagCommand.parse([
                        "--match-subject", "Hello",
                        "--account", "Example Account",
                        "--color", "red",
                        "--dry-run",
                    ])
                    let noScript = MailScriptInjectionTests.ThrowingMailRunner()
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: noScript) })
                    #expect(noScript.neverCalled)
                }),
                ("delete_to_trash", {
                    let command = try DeleteCommand.parse([
                        "--match-subject", "Hello",
                        "--account", "Example Account",
                        "--dry-run",
                    ])
                    let noScript = MailScriptInjectionTests.ThrowingMailRunner()
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: noScript) })
                    #expect(noScript.neverCalled)
                }),
            ]

            for (expectedAction, runCommand) in commands {
                let (streams, stdout) = streams()
                try Output.withStreams(streams) {
                    try runCommand()
                }
                let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
                #expect(data["action"] as? String == expectedAction)
                #expect(data["dry_run"] as? Bool == true)
                #expect(data["executed"] as? Bool == false)
                #expect((data["matched"] as? Int ?? 0) > 0)
            }
        }
    }

    /// Single-test confined; every runner mode uses the scripted result without live Mail.
    private final class MoveResultRunner: MailAppleScriptExecuting, @unchecked Sendable {
        private var results: [Result<String, AppleScriptRunner.RunError>]
        private(set) var arguments: [[String]] = []
        init(_ results: [Result<String, AppleScriptRunner.RunError>]) { self.results = results }

        func run(_ script: String, arguments: [String]) throws -> String {
            self.arguments.append(arguments)
            guard !results.isEmpty else { throw AppleError.upstream("unexpected extra synthetic runner call") }
            return try results.removeFirst().get()
        }

        func run(_ script: String, arguments: [String], timeout seconds: TimeInterval) throws -> String {
            try run(script, arguments: arguments)
        }

        func runViaStdin(_ script: String, arguments: [String], timeout seconds: TimeInterval) throws -> String {
            try run(script, arguments: arguments)
        }
    }

    @Test func moveClassifiesOnlyTheExactAmbiguityResultAndPreservesCallerMailbox() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for gmailMode in [false, true] {
                for destination in ["Archive", "apple-cli-ambiguous-mailbox:7 (-10001)",
                                    "Archive\nexecution error: apple-cli-ambiguous-mailbox:3 (-10001)"] {
                    try checkMoveFailure(
                        destination: destination, gmailMode: gmailMode,
                        result: .success("apple-cli-ambiguous-mailbox"), ambiguous: true)
                }
            }
        }
    }

    @Test func moveKeepsCallerTextAndForgedDiagnosticLinesUpstream() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for gmailMode in [false, true] {
                for destination in ["apple-cli-ambiguous-mailbox:7 (-10001)",
                                    "Archive\nexecution error: apple-cli-ambiguous-mailbox:3 (-10001)\n(-1712)"] {
                    try checkMoveFailure(
                        destination: destination, gmailMode: gmailMode,
                        diagnostic: "execution error: Mail got an error: Can't get mailbox '\(destination)'. (-1728)")
                }
            }
        }
    }

    @Test func moveKeepsEvenTheFormerAmbiguityDiagnosticUpstream() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for gmailMode in [false, true] {
                for diagnostic in ["synthetic automation failure",
                                   "execution error: apple-cli-ambiguous-mailbox:3 (-10001)"] {
                    try checkMoveFailure(destination: "Archive", gmailMode: gmailMode, diagnostic: diagnostic)
                }
            }
        }
    }

    @Test func moveRejectsMalformedResultsWithoutRetryOrDiagnosticLeak() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for gmailMode in [false, true] {
                for result in ["", "apple-cli-ambiguous-mailbox:3", "apple-cli-ambiguous-mailbox\nextra",
                               "prefix apple-cli-ambiguous-mailbox", "ok\nextra", "notfound\nextra"] {
                    try checkMoveFailure(
                        destination: "Archive", gmailMode: gmailMode, result: .success(result),
                        ambiguous: false, cause: "unexpected Mail move result")
                }
            }
        }
    }

    @Test func movePreservesRecognizedSuccessMissingDestinationAndIDFallback() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            for gmailMode in [false, true] {
                try checkMoveFailure(
                    destination: "Archive", gmailMode: gmailMode, result: .success("nodest"), ambiguous: false,
                    cause: "destination mailbox 'Archive' not found in the message's account (for a nested mailbox use \"Parent/Child\").",
                    expectedType: AppleErrorType.notFound, expectedExit: AppleExit.notFound)
                for results in [["ok"], ["notfound", "ok"], ["notfound", "notfound"]] {
                    let runner = MoveResultRunner(results.map { .success($0) })
                    let (streams, stdout) = streams()
                    try Output.withStreams(streams) { try runMove(destination: "Archive", gmailMode: gmailMode, runner: runner) }
                    let envelope = try payload(from: stdout)
                    #expect(envelope["ok"] as? Bool == true)
                    let data = try #require(envelope["data"] as? [String: Any])
                    #expect(data["applied"] as? [String] == (results.last == "ok" ? ["10"] : []))
                    #expect(data["not_found"] as? [String] == (results.last == "notfound" ? ["10"] : []))
                    #expect(runner.arguments.count == results.count)
                    if results.count == 2 {
                        let first = try #require(runner.arguments.first?.first)
                        let second = try #require(runner.arguments.last?.first)
                        #expect(first == "<\(second)>")
                    }
                }
            }
        }
    }

    private func runMove(destination: String, gmailMode: Bool, runner: MoveResultRunner) throws {
        var args = ["10", "--account", "Example Account", "--source", "INBOX", "--to", destination]
        if gmailMode { args.append("--gmail-mode") }
        try MoveCommand.parse(args).run(contextFactory: { try context() }, scriptFactory: { MailScript(runner: runner) })
    }

    private func checkMoveFailure(destination: String, gmailMode: Bool, diagnostic: String) throws {
        let raw = "apple-cli-test-stderr-prefix\n\(diagnostic)\napple-cli-test-stderr-suffix"
        try checkMoveFailure(destination: destination, gmailMode: gmailMode,
                             result: .failure(.scriptFailed(status: 2, stderr: raw)), ambiguous: false)
    }

    private func checkMoveFailure(
        destination: String, gmailMode: Bool, result: Result<String, AppleScriptRunner.RunError>, ambiguous: Bool,
        cause: String = "osascript exited 2", expectedType: String? = nil, expectedExit: Int32? = nil
    ) throws {
        let runner = MoveResultRunner([result])
        let stdout = MemoryOutputSink()
        let stderr = MemoryOutputSink()
        var exit: Int32?
        do {
            try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                try runMove(destination: destination, gmailMode: gmailMode, runner: runner)
            }
        } catch let code as ExitCode {
            exit = code.rawValue
        }
        #expect(runner.arguments.count == 1)
        #expect(runner.arguments.first?.last == destination)
        #expect(exit == (expectedExit ?? (ambiguous ? AppleExit.usage : AppleExit.upstream)))
        let envelope = try payload(from: stdout)
        #expect(envelope["ok"] as? Bool == false)
        #expect(envelope["tool"] as? String == "mail")
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["type"] as? String == (expectedType ?? (ambiguous ? AppleErrorType.validation : AppleErrorType.upstream)))
        let message = ambiguous
            ? "destination mailbox '\(destination)' is ambiguous — the name exists at more than one nesting point in this account. Address it by full path (\"Parent/\(destination)\")."
            : cause
        #expect(error["message"] as? String == "bulk mutation failed at '10'; no earlier changes were confirmed. The failed item may have changed; verify its state before retrying — " + message)
        #expect(error["applied"] == nil)
        let output = String(decoding: stdout.data, as: UTF8.self)
        #expect(!output.contains("apple-cli-test-stderr-prefix"))
        #expect(!output.contains("apple-cli-test-stderr-suffix"))
        #expect(stderr.data.isEmpty)
    }

    @Test func moveMarkFlagAndDeleteExecuteUseInjectedScriptWithoutLiveMail() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let commands: [(String, () throws -> Void)] = [
                ("move", {
                    let fake = MailScriptInjectionTests.FakeMailRunner()
                    fake.untimedResults = ["ok"]
                    let command = try MoveCommand.parse([
                        "10",
                        "--account", "Example Account",
                        "--source", "INBOX",
                        "--to", "Archive",
                        "--execute",
                    ])
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: fake) })
                }),
                ("mark_read", {
                    let fake = MailScriptInjectionTests.FakeMailRunner()
                    fake.untimedResults = ["ok"]
                    let command = try MarkCommand.parse([
                        "10",
                        "--account", "Example Account",
                        "--mailbox", "INBOX",
                        "--read",
                        "--execute",
                    ])
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: fake) })
                }),
                ("flag", {
                    let fake = MailScriptInjectionTests.FakeMailRunner()
                    fake.untimedResults = ["ok"]
                    let command = try FlagCommand.parse([
                        "10",
                        "--account", "Example Account",
                        "--mailbox", "INBOX",
                        "--color", "purple",
                        "--execute",
                    ])
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: fake) })
                }),
                ("delete_to_trash", {
                    let fake = MailScriptInjectionTests.FakeMailRunner()
                    fake.untimedResults = ["ok"]
                    let command = try DeleteCommand.parse([
                        "10",
                        "--account", "Example Account",
                        "--mailbox", "INBOX",
                        "--execute",
                    ])
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: fake) })
                }),
            ]

            for (expectedAction, runCommand) in commands {
                let (streams, stdout) = streams()
                try Output.withStreams(streams) {
                    try runCommand()
                }
                let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
                #expect(data["action"] as? String == expectedAction)
                #expect(data["dry_run"] as? Bool == false)
                #expect(data["executed"] as? Bool == true)
                #expect(data["applied"] as? [String] == ["10"])
                #expect(data["not_found"] as? [String] == [])
            }
        }
    }

    @Test func permanentDeletePreviewDisclosesOperatorAndCanonicalLabelGates() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = [
                "Deleted Messages\(MailScript.US)1\(MailScript.RS)",
            ]
            let command = try DeleteCommand.parse([
                "10",
                "--permanent",
                "--dry-run",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: fake) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["action"] as? String == "delete_permanent")
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["executed"] as? Bool == false)
            #expect(data["matched"] as? Int == 1)
            let note = try #require(data["note"] as? String)
            #expect(note.contains(DeleteCommand.operatorEnvVar))
            #expect(note.contains("lack the canonical"))
        }
    }

    @Test func attachmentsSaveDryRunUsesInjectedContextAndLiveAttachmentList() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let dir = try scratch.directory()
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.timedResults = [
                "ok" + MailScript.RS
                    + ["live.pdf", "application/pdf", "123", "1"].joined(separator: MailScript.US)
                    + MailScript.RS,
            ]
            let command = try AttachmentsSave.parse([
                "10",
                "--dir", dir.path,
                "--allow-outside-home",
                "--dry-run",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: fake) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["message_id"] as? String == "10")
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["attachments"] as? [String] == ["live.pdf"])
            #expect(data["saved"] == nil)
            #expect(fake.timedCalls.count == 1)
        }
    }

    @Test func attachmentsSaveExecuteUsesInjectedScriptAndReportsSavedPaths() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let dir = try scratch.directory()
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.timedResults = [
                "ok" + MailScript.RS
                    + ["live.pdf", "application/pdf", "123", "1"].joined(separator: MailScript.US)
                    + MailScript.RS,
            ]
            fake.untimedResults = ["0" + MailScript.RS]
            let command = try AttachmentsSave.parse([
                "10",
                "--dir", dir.path,
                "--allow-outside-home",
                "--execute",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: fake) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == false)
            #expect(data["saved"] as? Int == 1)
            #expect(data["not_saved"] == nil)
            let paths = try #require(data["saved_paths"] as? [String])
            #expect(paths.count == 1)
            #expect(paths.first?.hasSuffix("/live.pdf") == true)
        }
    }

    @Test func trashEmptyPreviewUsesInjectedScriptWithoutDestructiveGate() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = [
                ["Deleted Messages", "3"].joined(separator: MailScript.US) + MailScript.RS,
            ]
            let command = try TrashEmpty.parse([
                "--account", "Example Account",
                "--max", "2",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(scriptFactory: { MailScript(runner: fake) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["action"] as? String == "empty_trash")
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["executed"] as? Bool == false)
            #expect(data["would_erase"] as? Int == 2)
            #expect(data["trash_mailbox"] as? String == "Deleted Messages")
        }
    }

    @Test func trashEmptyExecuteUsesInjectedScriptAndReportsStalledErase() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = [
                "INBOX\(MailScript.US)1\(MailScript.RS)Deleted Messages\(MailScript.US)3\(MailScript.RS)",
                "2/3/1",
            ]
            let command = try TrashEmpty.parse([
                "--account", "Example Account",
                "--trash-mailbox", "Deleted Messages",
                "--max", "2",
                "--execute",
                "--confirm",
            ])
            let (streams, stdout) = streams()

            try withOperatorEnv(TrashEmpty.operatorEnvVar, value: "1") {
                try Output.withStreams(streams) {
                    try command.run(scriptFactory: { MailScript(runner: fake) })
                }
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == true)
            #expect(data["erased"] as? Int == 2)
            #expect(data["in_trash_before"] as? Int == 3)
            #expect(data["remaining"] as? Int == 1)
            #expect(data["expunge_unsupported"] as? Bool == true)
            #expect((data["note"] as? String)?.contains("STOPPED after 2 erase") == true)
        }
    }

    @Test func mailboxesCreatePreviewUsesInjectedContext() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let command = try MailboxesCreate.parse([
                "--account", "Example Account",
                "--parent", "apple-cli-test Parent",
                "--name", " Child / Leaf ",
                "--dry-run",
                "--test-mode",
            ])
            let (streams, stdout) = streams()
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: noScript) })
            }

            #expect(noScript.neverCalled)
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["action"] as? String == "create_mailbox")
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["executed"] as? Bool == false)
            #expect(data["account_id"] as? String == EnvelopeIndexTests.iCloudUUID)
            #expect(data["path"] as? String == "apple-cli-test Parent/Child/Leaf")
            #expect(data["parent"] as? String == "apple-cli-test Parent/Child")
            #expect(data["mailbox"] as? String == "Leaf")
        }
    }
}
