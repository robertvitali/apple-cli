import Foundation
import Testing
import ArgumentParser
@testable import MailKit
import AppleKit
import TestSupport

@Suite("Mail normalized final-leaf refusal", .serialized)
struct MailFinalLeafCommandTests {
    private let scratch = ScratchDirs("mail-final-leaf")

    enum Surface: CaseIterable {
        case dashboard, send, richDraft, attachments
    }

    private struct Destination {
        let raw: String
        let leaf: URL
        let target: URL
        let sentinel: URL

        func plantLink() throws {
            try FileManager.default.createSymbolicLink(atPath: leaf.path,
                                                       withDestinationPath: target.path)
        }

        func expectUnchanged(dangling: Bool) throws {
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "synthetic sentinel")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: leaf.path) == target.path)
            if dangling { #expect(!FileManager.default.fileExists(atPath: target.path)) }
        }
    }

    private func destination(dangling: Bool) throws -> Destination {
        let root = try scratch.directory()
        let sentinel = root.appendingPathComponent("sentinel.txt")
        try "synthetic sentinel".write(to: sentinel, atomically: true, encoding: .utf8)
        let leaf = root.appendingPathComponent("output.eml")
        // Preserve argv spelling: constructing/standardizing a URL here can erase the absent
        // component and accidentally exercise only the already-covered literal leaf refusal.
        return Destination(raw: root.path + "/absent/../output.eml", leaf: leaf,
                           target: dangling ? root.appendingPathComponent("missing-target") : sentinel,
                           sentinel: sentinel)
    }

    private func pinnedEnvironment(_ body: () throws -> Void) throws {
        let root = try scratch.directory().appendingPathComponent(".apple-cli")
        try TestEnvironment.withoutWriteModeOverrides {
            try TestEnvironment.with([
                "APPLE_SEND_RATELIMIT_STATE": root.appendingPathComponent("send-rate-limit.json").path,
                "APPLE_REPLY_RATELIMIT_STATE": root.appendingPathComponent("reply-rate-limit.json").path,
            ], body)
        }
    }

    private func expectRefusal(_ body: () throws -> Void) throws {
        let stdout = MemoryOutputSink()
        let streams = CLIStreams(stdout: stdout, stderr: MemoryOutputSink())
        var exit: ExitCode?
        try Output.withStreams(streams) {
            do { try body() } catch let code as ExitCode { exit = code }
        }
        #expect(exit?.rawValue == 77)
        let envelope = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
        #expect(envelope["tool"] as? String == "mail")
        #expect(envelope["ok"] as? Bool == false)
        let error = envelope["error"] as? [String: Any]
        #expect(error?["type"] as? String == AppleErrorType.safetyViolation)
        #expect((error?["message"] as? String)?.contains("symlink") == true)
    }

    @Test(arguments: Surface.allCases, [(false, false), (false, true), (true, false), (true, true)])
    func normalizedLeafRefusesBeforeDependencies(surface: Surface, posture: (Bool, Bool)) throws {
        let (dangling, dryRun) = posture
        try pinnedEnvironment {
            let destination = try destination(dangling: dangling)
            try destination.plantLink()
            let mode = dryRun ? "--dry-run" : "--execute"
            let runner = MailScriptInjectionTests.ThrowingMailRunner()
            let opener = MailScriptInjectionTests.ThrowingMailOpener()
            let accountRunner = MailScriptInjectionTests.ThrowingMailRunner()
            var contextCalls = 0
            var directoryCalls = 0
            var scriptCalls = 0
            let context: () throws -> MailContext = {
                contextCalls += 1
                throw AppleError.upstream("Synthetic context must not be requested")
            }
            let directory: () -> AccountDirectory = {
                directoryCalls += 1
                return AccountDirectory(runner: accountRunner)
            }
            let script: () -> MailScript = {
                scriptCalls += 1
                return MailScript(runner: runner, opener: opener)
            }

            try expectRefusal {
                switch surface {
                case .dashboard:
                    let command = try AnalyticsDashboard.parse(["--out", destination.raw, mode])
                    try command.run(contextFactory: context, scriptFactory: script)
                case .send:
                    let command = try SendCommand.parse([
                        "--to", "recipient@example.com", "--subject", "Synthetic subject",
                        "--body", "Synthetic body", "--mode", "open", "--account", "Example Account",
                        "--out", destination.raw, mode,
                    ])
                    try command.run(scriptFactory: script, directoryFactory: directory)
                case .richDraft:
                    let command = try DraftRichCommand.parse([
                        "--subject", "Synthetic subject", "--account", "Example Account",
                        "--out", destination.raw, mode,
                    ])
                    try command.run(scriptFactory: script, directoryFactory: directory)
                case .attachments:
                    let command = try AttachmentsSave.parse([
                        "10", "--out", destination.raw, "--allow-outside-home", mode,
                    ])
                    try command.run(contextFactory: context, scriptFactory: script)
                }
            }

            #expect(contextCalls == 0)
            #expect(directoryCalls == 0)
            #expect(scriptCalls == 0)
            #expect(accountRunner.neverCalled)
            #expect(runner.neverCalled)
            #expect(opener.neverCalled)
            try destination.expectUnchanged(dangling: dangling)
        }
    }

    // Account lookup is the last existing injection seam before .eml destination selection.
    // A link planted here must be caught again; no live Mail action or send is involved.
    @Test(arguments: [Surface.send, .richDraft], [false, true])
    func generatedEmlRechecksLinkPlantedDuringAccountLookup(surface: Surface, dangling: Bool) throws {
        try pinnedEnvironment {
            let destination = try destination(dangling: dangling)
            let runner = MailScriptInjectionTests.ThrowingMailRunner()
            let opener = MailScriptInjectionTests.ThrowingMailOpener()
            let accountRunner = MailScriptInjectionTests.FakeMailRunner()
            accountRunner.untimedResults = [[
                EnvelopeIndexTests.iCloudUUID, "Example Account", "imap", "true", "sender@example.com",
            ].joined(separator: MailScript.US) + MailScript.RS]
            var directoryCalls = 0
            var scriptCalls = 0
            var plantingError: (any Error)?
            let directory: () -> AccountDirectory = {
                directoryCalls += 1
                do { try destination.plantLink() } catch { plantingError = error }
                return AccountDirectory(runner: accountRunner)
            }
            let script: () -> MailScript = {
                scriptCalls += 1
                return MailScript(runner: runner, opener: opener)
            }

            try expectRefusal {
                if surface == .send {
                    let command = try SendCommand.parse([
                        "--to", "recipient@example.com", "--subject", "Synthetic subject",
                        "--body", "Synthetic body", "--mode", "open", "--account", "Example Account",
                        "--out", destination.raw, "--execute",
                    ])
                    try command.run(scriptFactory: script, directoryFactory: directory)
                } else {
                    let command = try DraftRichCommand.parse([
                        "--subject", "Synthetic subject", "--account", "Example Account", "--no-open",
                        "--out", destination.raw, "--execute",
                    ])
                    try command.run(scriptFactory: script, directoryFactory: directory)
                }
            }

            #expect(plantingError == nil)
            #expect(directoryCalls == 1)
            #expect(accountRunner.untimedArguments.count == 1)
            #expect(scriptCalls == 0)
            #expect(runner.neverCalled)
            #expect(opener.neverCalled)
            try destination.expectUnchanged(dangling: dangling)
        }
    }

    @Test(arguments: [Surface.dashboard, .attachments],
          [(false, false), (false, true), (true, false), (true, true)])
    func exportRechecksRawAndCapturedLeavesAfterContextLookup(surface: Surface,
                                                             posture: (Bool, Bool)) throws {
        let (plantAtCapturedDestination, dangling) = posture
        try pinnedEnvironment {
            let root = try scratch.directory()
            let first = root.appendingPathComponent("first", isDirectory: true)
            let second = root.appendingPathComponent("second", isDirectory: true)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(atPath: alias.path,
                                                       withDestinationPath: first.path)
            let sentinel = root.appendingPathComponent("sentinel.txt")
            try "synthetic sentinel".write(to: sentinel, atomically: true, encoding: .utf8)
            let plantedLeaf = (plantAtCapturedDestination ? first : second)
                .appendingPathComponent("output.dat")
            let untouchedLeaf = (plantAtCapturedDestination ? second : first)
                .appendingPathComponent("output.dat")
            let capturedLeaf = first.appendingPathComponent("output.dat")
            try "synthetic existing output".write(to: capturedLeaf, atomically: true, encoding: .utf8)
            let destination = Destination(
                raw: alias.path + "/output.dat", leaf: plantedLeaf,
                target: dangling ? root.appendingPathComponent("missing-target") : sentinel,
                sentinel: sentinel)

            let fixture = EnvelopeIndexTests.makeFixture(in: try scratch.directory())
            let accountRunner = MailScriptInjectionTests.FakeMailRunner()
            accountRunner.untimedResults = [[
                EnvelopeIndexTests.iCloudUUID, "Example Account", "imap", "true", "sender@example.com",
            ].joined(separator: MailScript.US) + MailScript.RS]
            let context = try MailContext(explicitPath: fixture,
                                          accountDirectory: AccountDirectory(runner: accountRunner))
            let runner = MailScriptInjectionTests.FakeMailRunner()
            let opener = MailScriptInjectionTests.ThrowingMailOpener()
            if surface == .dashboard {
                runner.untimedResults = [
                    ["Example Account", "INBOX", "2"].joined(separator: MailScript.US) + MailScript.RS,
                ]
            } else {
                runner.timedResults = [
                    "ok" + MailScript.RS
                        + ["synthetic.pdf", "application/pdf", "123", "1"].joined(separator: MailScript.US)
                        + MailScript.RS,
                ]
            }
            var contextCalls = 0
            var scriptCalls = 0
            let contextFactory: () throws -> MailContext = {
                contextCalls += 1
                // Existing first/output.dat makes Foundation capture its physical spelling.
                // Retarget only the test-owned alias, then plant one leaf to require both checks.
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(atPath: alias.path,
                                                           withDestinationPath: second.path)
                if plantAtCapturedDestination { try FileManager.default.removeItem(at: capturedLeaf) }
                try destination.plantLink()
                return context
            }
            let scriptFactory: () -> MailScript = {
                scriptCalls += 1
                return MailScript(runner: runner, opener: opener)
            }

            try expectRefusal {
                if surface == .dashboard {
                    let command = try AnalyticsDashboard.parse(["--out", destination.raw, "--execute"])
                    try command.run(contextFactory: contextFactory, scriptFactory: scriptFactory)
                } else {
                    let command = try AttachmentsSave.parse([
                        "10", "--out", destination.raw, "--allow-outside-home", "--execute",
                    ])
                    try command.run(contextFactory: contextFactory, scriptFactory: scriptFactory)
                }
            }

            #expect(contextCalls == 1)
            #expect(scriptCalls == 1)
            #expect(runner.untimedArguments.count == (surface == .dashboard ? 1 : 0))
            #expect(runner.timedCalls.count == (surface == .attachments ? 1 : 0))
            #expect(runner.stdinArguments.isEmpty)
            #expect(opener.neverCalled)
            if plantAtCapturedDestination { #expect(!FileManager.default.fileExists(atPath: untouchedLeaf.path)) }
            else { #expect(try String(contentsOf: untouchedLeaf, encoding: .utf8) == "synthetic existing output") }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == second.path)
            try destination.expectUnchanged(dangling: dangling)
        }
    }
}
