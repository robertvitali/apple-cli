import Foundation
import Testing
import ArgumentParser
@testable import MailKit
import AppleKit
import TestSupport

// `.serialized`: these commands read process-global `APPLE_*` state through `TestMode`, so the
// suite pairs `TestEnvironment` windows (atomic against other suites, via its process-wide lock)
// with a trait that keeps the suite from queueing on itself.
@Suite("Mail analytics/export commands with injected dependencies", .serialized)
struct MailAnalyticsExportCommandInjectionTests {
    private let scratch = ScratchDirs("mail-analytics-cmd")
    /// `mail export` refuses a destination outside the home directory, so its scratch root has to
    /// be inside it — a `$TMPDIR` path fails the guard with exit 77 rather than exercising it.
    private let homeScratch = ConfinedScratchDirs("mail-export-cmd")
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

    private func mailScript(unread: Int = 2) -> MailScript {
        let runner = MailScriptInjectionTests.FakeMailRunner()
        runner.untimedResults = ["Example Account\(MailScript.US)INBOX\(MailScript.US)\(unread)\(MailScript.RS)"]
        return MailScript(runner: runner)
    }

    /// `ConfinedScratchDirs` roots inside the home directory, so unlike a `$TMPDIR` path nothing
    /// ever reaps it — the ROOT's mode is therefore load-bearing, not just the leaf's. It used to
    /// be created implicitly by `withIntermediateDirectories: true`, which applies the requested
    /// attributes to the leaf and leaves any intermediate at the process umask. This pins both.
    /// (Root REMOVAL happens in `deinit` and cannot be asserted here — sibling suites legitimately
    /// hold directories under the same root while this test runs, and the `rmdir` is a no-op then.)
    @Test func confinedScratchRootAndLeafAreOwnerOnly() throws {
        let leaf = try homeScratch.directory()
        let root = leaf.deletingLastPathComponent()
        func mode(_ url: URL) throws -> Int {
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            return try #require(value as? Int)
        }
        #expect(try mode(leaf) == 0o700)
        #expect(try mode(root) == 0o700)
    }

    @Test func topSendersUsesInjectedContext() throws {
        let command = try AnalyticsTopSenders.parse([
            "--account", "Example Account",
            "--mailbox", "All",
            "--days", "0",
            "--top-n", "2",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["account"] as? String == "Example Account")
        #expect(data["total_analyzed"] as? Int == 3)
        #expect(data["unique_senders"] as? Int == 2)
        let senders = try #require(data["senders"] as? [[String: Any]])
        #expect(senders.count == 2)
    }

    @Test func statsUsesInjectedContextAndMailboxBreakdown() throws {
        let command = try AnalyticsStats.parse([
            "--account", "Example Account",
            "--scope", "mailbox_breakdown",
            "--mailbox", "All",
            "--days", "30",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["scope"] as? String == "mailbox_breakdown")
        #expect(data["account"] as? String == "Example Account")
        #expect(data["system_folders_excluded"] as? Bool == true)
    }

    @Test func overviewUsesInjectedContextAndScript() throws {
        let command = try AnalyticsOverview.parse([])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() }, scriptFactory: { mailScript(unread: 3) })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["total_unread"] as? Int == 3)
        let recent = try #require(data["recent"] as? [[String: Any]])
        #expect(!recent.isEmpty)
    }

    @Test func needsResponseUsesInjectedContextAndSentSuppression() throws {
        let command = try AnalyticsNeedsResponse.parse([
            "--account", "Example Account",
            "--mailbox", "INBOX",
            "--days", "0",
            "--max", "5",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["account"] as? String == "Example Account")
        #expect(data["mailbox"] as? String == "INBOX")
        #expect(data["days_back"] as? Int == 0)
        #expect(data["sent_mailbox"] as? String == "Sent Messages")
        #expect(data["count"] as? Int == 0)
    }

    @Test func awaitingReplyUsesInjectedContextAndRecipientPairs() throws {
        let command = try AnalyticsAwaitingReply.parse([
            "--account", "Example Account",
            "--days", "0",
            "--max", "5",
            "--no-exclude-noreply",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(contextFactory: { try context() })
        }

        let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
        #expect(data["account"] as? String == "Example Account")
        #expect(data["days_back"] as? Int == 0)
        #expect(data["sent_mailbox"] as? String == "Sent Messages")
        #expect(data["count"] as? Int == 0)
        let items = try #require(data["items"] as? [[String: Any]])
        #expect(items.isEmpty)
    }

    @Test func dashboardDryRunUsesInjectedContextAndScriptWithoutWriting() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let out = try scratch.directory().appendingPathComponent("dashboard.html").path
            let command = try AnalyticsDashboard.parse(["--out", out, "--dry-run"])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() }, scriptFactory: { mailScript(unread: 4) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["total_unread"] as? Int == 4)
            #expect(FileManager.default.fileExists(atPath: out) == false)
        }
    }

    @Test func dashboardExecuteUsesInjectedContextAndWritesSyntheticHtml() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let out = try scratch.directory().appendingPathComponent("dashboard.html")
            let command = try AnalyticsDashboard.parse(["--out", out.path, "--execute"])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() }, scriptFactory: { mailScript(unread: 5) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == false)
            #expect(data["total_unread"] as? Int == 5)
            let html = try String(contentsOf: out, encoding: .utf8)
            #expect(html.contains("Inbox Dashboard"))
            #expect(html.contains("Total unread"))
        }
    }

    @Test func exportDryRunUsesInjectedContextWithoutFetchingBodyOrWriting() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            // A not-yet-created child of an owned scratch directory: the assertion below is that the
            // dry-run creates NOTHING, and it used to be checked against a path in the repo working
            // tree — where a regressed gate would have deposited an untracked, unignored artifact.
            let outDir = try homeScratch.directory().appendingPathComponent("export").path
            let command = try ExportCommand.parse([
                "--account", "Example Account",
                "--scope", "single_email",
                "--subject", "Hello",
                "--dir", outDir,
                "--dry-run",
            ])
            let (streams, stdout) = streams()
            // Fail-closed: a preview must not fetch a body over AppleScript.
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: noScript) })
            }

            #expect(noScript.neverCalled)
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == true)
            #expect(data["body_source"] as? String == "full_body")
            #expect(data["exported"] as? Int == 0)
            #expect(FileManager.default.fileExists(atPath: outDir) == false)
        }
    }

    @Test func exportExecuteFetchesFullBodyAndWritesSyntheticSingleEmail() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let outDir = try homeScratch.directory().appendingPathComponent("export")
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = ["Full synthetic body"]
            let command = try ExportCommand.parse([
                "--account", "Example Account",
                "--scope", "single_email",
                "--subject", "Hello",
                "--dir", outDir.path,
                "--format", "txt",
                "--execute",
                "--test-mode",
            ])
            let (streams, stdout) = streams()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: fake) })
            }

            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["dry_run"] as? Bool == false)
            #expect(data["exported"] as? Int == 1)
            #expect(data["body_source"] as? String == "full_body")
            let files = try #require(data["files"] as? [String])
            let written = try #require(files.first)
            #expect(written.hasSuffix("/Hello.txt"))
            let body = try String(contentsOfFile: written, encoding: .utf8)
            #expect(body.contains("Subject: Hello"))
            #expect(body.contains("Full synthetic body"))
            #expect(fake.untimedArguments.first == ["<msg10@host>", "Example Account"])
        }
    }

    @Test func exportExecuteWritesSyntheticEntireMailboxExport() throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let outDir = try homeScratch.directory().appendingPathComponent("export")
            let command = try ExportCommand.parse([
                "--account", "Example Account",
                "--scope", "entire_mailbox",
                "--mailbox", "INBOX",
                "--dir", outDir.path,
                "--max", "1",
                "--execute",
                "--test-mode",
            ])
            let (streams, stdout) = streams()
            // entire_mailbox never fetches a body, so this execute path must not reach AppleScript.
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()

            try Output.withStreams(streams) {
                try command.run(contextFactory: { try context() },
                                scriptFactory: { MailScript(runner: noScript) })
            }

            #expect(noScript.neverCalled)
            let data = try #require(try payload(from: stdout)["data"] as? [String: Any])
            #expect(data["exported"] as? Int == 1)
            #expect(data["dry_run"] as? Bool == false)
            #expect(data["write_failures"] == nil)
            #expect(data["directory"] as? String == outDir.appendingPathComponent("INBOX_export").path)
            let files = try #require(data["files"] as? [String])
            let written = try #require(files.first)
            #expect(written.hasSuffix("/INBOX_export/1_.txt"))
            #expect(try String(contentsOfFile: written, encoding: .utf8).contains("Subject:"))
        }
    }

    /// Expected names are pinned to the synthetic index fixture, not obtained from the planner
    /// under test: INBOX's newest row has no subject; its subject-matched row is named Hello.
    private func composedLeafCase(_ layout: String) -> (arguments: [String], name: String) {
        switch layout {
        case "single":
            return (["--scope", "single_email", "--subject", "Hello"], "Hello.txt")
        case "flat":
            return (["--scope", "entire_mailbox", "--max", "1", "--layout", "flat"], "11-untitled.txt")
        default:
            return (["--scope", "entire_mailbox", "--max", "1"], "INBOX_export/1_.txt")
        }
    }

    @Test(arguments: ["single", "mailbox", "flat"],
          [(false, false), (false, true), (true, false), (true, true)])
    func exportRefusesComposedLeafSymlinks(layout: String, posture: (Bool, Bool)) throws {
        let (execute, dangling) = posture
        try TestEnvironment.withoutWriteModeOverrides {
            for noClobber in [false, true] {
                let root = try homeScratch.directory().resolvingSymlinksInPath()
                let outDir = root.appendingPathComponent("export")
                let testCase = composedLeafCase(layout)
                let leaf = outDir.appendingPathComponent(testCase.name)
                try FileManager.default.createDirectory(at: leaf.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let sentinel = root.appendingPathComponent("sentinel.txt")
                let sentinelBytes = Data("synthetic sentinel".utf8)
                try sentinelBytes.write(to: sentinel)
                let target = dangling ? root.appendingPathComponent("missing-target.txt") : sentinel
                try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
                let before = try FileManager.default.subpathsOfDirectory(atPath: outDir.path).sorted()
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.untimedResults = ["Full synthetic body"]
                let args = ["--account", "Example Account", "--mailbox", "INBOX",
                            "--dir", outDir.path, "--test-mode", execute ? "--execute" : "--dry-run"]
                    + testCase.arguments + (noClobber ? ["--no-clobber"] : [])
                let command = try ExportCommand.parse(args)
                let (streams, stdout) = streams()
                var exit: ExitCode?
                try Output.withStreams(streams) {
                    do {
                        try command.run(contextFactory: { try context() },
                                        scriptFactory: { MailScript(runner: fake) })
                    } catch let code as ExitCode { exit = code }
                }

                // Unchanged target bytes alone are insufficient: an atomic replacement could
                // preserve the target while destroying the link. Require refusal AND both states.
                #expect(exit?.rawValue == AppleExit.permissionDenied)
                let envelope = try payload(from: stdout)
                #expect(envelope["tool"] as? String == "mail")
                #expect(envelope["ok"] as? Bool == false)
                #expect(envelope["data"] == nil)
                let error = envelope["error"] as? [String: Any]
                #expect(error?["type"] as? String == AppleErrorType.safetyViolation)
                #expect((error?["message"] as? String)?.contains("symlink") == true)
                #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: leaf.path)) == target.path)
                #expect(try Data(contentsOf: sentinel) == sentinelBytes)
                if dangling { #expect(!FileManager.default.fileExists(atPath: target.path)) }
                #expect(try FileManager.default.subpathsOfDirectory(atPath: outDir.path).sorted() == before)
                if !execute || layout != "single" { #expect(fake.untimedArguments.isEmpty) }
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func exportPreflightsLaterLinkedLeafBeforeWritingEarlierMessage(existingEarlier: Bool,
                                                                   dangling: Bool) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let root = try homeScratch.directory().resolvingSymlinksInPath()
            let outDir = root.appendingPathComponent("export")
            let mailboxDir = outDir.appendingPathComponent("INBOX_export")
            try FileManager.default.createDirectory(at: mailboxDir, withIntermediateDirectories: true)
            // The fixture's two INBOX rows are selected newest first: subjectless, then Hello.
            // A check only inside the write loop would already create/overwrite the first file.
            let earlier = mailboxDir.appendingPathComponent("1_.txt")
            let later = mailboxDir.appendingPathComponent("2_Hello.txt")
            let previous = Data("synthetic previous output".utf8)
            if existingEarlier { try previous.write(to: earlier) }
            let sentinel = root.appendingPathComponent("sentinel.txt")
            let sentinelBytes = Data("synthetic sentinel".utf8)
            try sentinelBytes.write(to: sentinel)
            let target = dangling ? root.appendingPathComponent("missing-target.txt") : sentinel
            try FileManager.default.createSymbolicLink(at: later, withDestinationURL: target)
            let before = try FileManager.default.subpathsOfDirectory(atPath: outDir.path).sorted()
            let noScript = MailScriptInjectionTests.ThrowingMailRunner()
            let command = try ExportCommand.parse([
                "--account", "Example Account", "--scope", "entire_mailbox",
                "--mailbox", "INBOX", "--dir", outDir.path, "--max", "2",
                "--execute", "--test-mode",
            ])
            let (streams, stdout) = streams()
            var exit: ExitCode?
            try Output.withStreams(streams) {
                do {
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: noScript) })
                } catch let code as ExitCode { exit = code }
            }

            #expect(exit?.rawValue == AppleExit.permissionDenied)
            let envelope = try payload(from: stdout)
            #expect(envelope["tool"] as? String == "mail")
            #expect(envelope["ok"] as? Bool == false)
            #expect(envelope["data"] == nil)
            let error = envelope["error"] as? [String: Any]
            #expect(error?["type"] as? String == AppleErrorType.safetyViolation)
            #expect((error?["message"] as? String)?.contains("symlink") == true)
            if existingEarlier {
                #expect(try Data(contentsOf: earlier) == previous)
            } else {
                #expect(!FileManager.default.fileExists(atPath: earlier.path))
            }
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: later.path)) == target.path)
            #expect(try Data(contentsOf: sentinel) == sentinelBytes)
            if dangling { #expect(!FileManager.default.fileExists(atPath: target.path)) }
            #expect(try FileManager.default.subpathsOfDirectory(atPath: outDir.path).sorted() == before)
            #expect(noScript.neverCalled)
        }
    }

    @Test(arguments: ["single", "mailbox", "flat"],
          [(false, false), (false, true), (true, false), (true, true)])
    func exportKeepsOrdinaryLeavesAndPermittedSymlinkParents(layout: String,
                                                            state: (Bool, Bool)) throws {
        let (symlinkParents, existingLeaf) = state
        try TestEnvironment.withoutWriteModeOverrides {
            let root = try homeScratch.directory().resolvingSymlinksInPath()
            let realDir = root.appendingPathComponent("export")
            try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
            var operatorDir = realDir
            if symlinkParents {
                operatorDir = root.appendingPathComponent("export-alias")
                try FileManager.default.createSymbolicLink(at: operatorDir, withDestinationURL: realDir)
                if layout == "mailbox" {
                    let inner = realDir.appendingPathComponent("real-parent")
                    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
                    try FileManager.default.createSymbolicLink(
                        at: realDir.appendingPathComponent("INBOX_export"), withDestinationURL: inner)
                }
            }
            let testCase = composedLeafCase(layout)
            let leaf = realDir.appendingPathComponent(testCase.name)
            if existingLeaf {
                try FileManager.default.createDirectory(at: leaf.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("synthetic previous output".utf8).write(to: leaf)
            }
            for execute in [false, true] {
                let before = try FileManager.default.subpathsOfDirectory(atPath: realDir.path).sorted()
                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.untimedResults = ["Full synthetic body"]
                let command = try ExportCommand.parse([
                    "--account", "Example Account", "--mailbox", "INBOX",
                    "--dir", operatorDir.path, "--test-mode", execute ? "--execute" : "--dry-run",
                ] + testCase.arguments)
                let (streams, stdout) = streams()
                try Output.withStreams(streams) {
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: fake) })
                }
                let envelope = try payload(from: stdout)
                #expect(envelope["ok"] as? Bool == true)
                let data = try #require(envelope["data"] as? [String: Any])
                #expect(data["dry_run"] as? Bool == !execute)
                #expect(data["exported"] as? Int == (execute ? 1 : 0))
                #expect(data["files"] as? [String] == [leaf.path])
                #expect(data["write_failures"] == nil)
                if execute {
                    let contents = try String(contentsOf: leaf, encoding: .utf8)
                    #expect(contents.contains("Subject:"))
                    #expect(!contents.contains("synthetic previous output"))
                    if layout == "single" { #expect(contents.contains("Full synthetic body")) }
                } else {
                    #expect(fake.untimedArguments.isEmpty)
                    #expect(try FileManager.default.subpathsOfDirectory(atPath: realDir.path).sorted() == before)
                    if existingLeaf {
                        #expect(try Data(contentsOf: leaf) == Data("synthetic previous output".utf8))
                    } else { #expect(!FileManager.default.fileExists(atPath: leaf.path)) }
                }
                if symlinkParents {
                    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: operatorDir.path) == realDir.path)
                    if layout == "mailbox" {
                        #expect(try FileManager.default.destinationOfSymbolicLink(
                            atPath: realDir.appendingPathComponent("INBOX_export").path)
                            == realDir.appendingPathComponent("real-parent").path)
                    }
                }
            }
        }
    }

    @Test(arguments: ["single", "mailbox", "flat"])
    func exportNoClobberStillRefusesOrdinaryExistingLeaves(layout: String) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let outDir = try homeScratch.directory().resolvingSymlinksInPath()
            let testCase = composedLeafCase(layout)
            let leaf = outDir.appendingPathComponent(testCase.name)
            try FileManager.default.createDirectory(at: leaf.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let previous = Data("synthetic previous output".utf8)
            try previous.write(to: leaf)
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.untimedResults = ["Full synthetic body"]
            let command = try ExportCommand.parse([
                "--account", "Example Account", "--mailbox", "INBOX", "--dir", outDir.path,
                "--test-mode", "--execute", "--no-clobber",
            ] + testCase.arguments)
            let (streams, stdout) = streams()
            var exit: ExitCode?
            try Output.withStreams(streams) {
                do {
                    try command.run(contextFactory: { try context() },
                                    scriptFactory: { MailScript(runner: fake) })
                } catch let code as ExitCode { exit = code }
            }
            #expect(exit?.rawValue == AppleExit.permissionDenied)
            let envelope = try payload(from: stdout)
            #expect(envelope["ok"] as? Bool == false)
            let error = envelope["error"] as? [String: Any]
            #expect(error?["type"] as? String == AppleErrorType.safetyViolation)
            #expect((error?["message"] as? String)?.contains("--no-clobber") == true)
            #expect(try Data(contentsOf: leaf) == previous)
        }
    }
}
