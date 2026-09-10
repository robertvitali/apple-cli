import Foundation
import Testing
import ArgumentParser
@testable import MailKit
import AppleKit
import TestSupport

@Suite("Mail attachment destination input relationship", .serialized)
struct MailAttachmentDestinationInvariantTests {
    private let scratch = ScratchDirs("mail-attachment-destination")

    enum PhysicalLeaf: CaseIterable {
        case ordinary, absent, existingLink, danglingLink
    }

    /// macOS 26 characterization: terminal /. changes absolute alias/.. resolution, so removing
    /// it before confinement is not generally equivalent. Pin each selected path independently.
    @Test(arguments: [false, true], PhysicalLeaf.allCases)
    func trailingSuffixesCanChangeTheConfinedDestination(relative: Bool,
                                                        physicalLeaf: PhysicalLeaf) throws {
        let root = try scratch.directory().resolvingSymlinksInPath()
        let inner = root.appendingPathComponent("physical/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                                   withDestinationURL: inner)
        let lexical = root.appendingPathComponent("leaf.bin")
        try Data("synthetic lexical file".utf8).write(to: lexical)
        let sentinel = root.appendingPathComponent("sentinel.bin")
        let sentinelBytes = Data("synthetic sentinel".utf8)
        try sentinelBytes.write(to: sentinel)
        let physical = root.appendingPathComponent("physical/leaf.bin")
        switch physicalLeaf {
        case .ordinary:
            try Data("synthetic physical file".utf8).write(to: physical)
        case .absent:
            break
        case .existingLink:
            try FileManager.default.createSymbolicLink(at: physical, withDestinationURL: sentinel)
        case .danglingLink:
            try FileManager.default.createSymbolicLink(
                at: physical, withDestinationURL: root.appendingPathComponent("missing-target"))
        }
        let depth = FileManager.default.currentDirectoryPath.split(separator: "/").count
        let spelledRoot = relative
            ? String(repeating: "../", count: depth) + root.path.dropFirst()
            : root.path
        for stem in ["/leaf.bin", "/absent/../leaf.bin", "/alias/../leaf.bin"] {
            for suffix in ["", "/", "/.", "/./"] {
                let original = spelledRoot + stem + suffix
                let trimmed = AttachmentsSave.lexicalDestinationPath(original)
                let selectedFromOriginal = AttachmentsSave.normalizeDestinationPath(
                    try confineWriteDestination(original, action: "characterize attachment output",
                                                allowOutsideHome: true).path)
                let selectedFromTrimmed = AttachmentsSave.normalizeDestinationPath(
                    try confineWriteDestination(trimmed, action: "characterize attachment output",
                                                allowOutsideHome: true).path)
                let physicalSelection: String
                switch physicalLeaf {
                case .ordinary: physicalSelection = physical.path
                case .existingLink: physicalSelection = sentinel.path
                case .absent, .danglingLink: physicalSelection = lexical.path
                }
                let traversesAlias = !relative && stem == "/alias/../leaf.bin"
                let terminalDot = suffix == "/." || suffix == "/./"
                let expectedOriginal = traversesAlias && !terminalDot ? physicalSelection : lexical.path
                let expectedTrimmed = traversesAlias ? physicalSelection : lexical.path
                #expect(selectedFromOriginal == expectedOriginal,
                        "original stem \(stem), suffix \(suffix), relative \(relative), state \(physicalLeaf)")
                #expect(selectedFromTrimmed == expectedTrimmed,
                        "trimmed stem \(stem), suffix \(suffix), relative \(relative), state \(physicalLeaf)")
            }
        }
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(try Data(contentsOf: lexical) == Data("synthetic lexical file".utf8))
    }

    private func context() throws -> MailContext {
        let fixture = EnvelopeIndexTests.makeFixture(in: try scratch.directory())
        let runner = MailScriptInjectionTests.FakeMailRunner()
        runner.untimedResults = [[
            EnvelopeIndexTests.iCloudUUID, "Example Account", "imap", "true", "sender@example.com",
        ].joined(separator: MailScript.US) + MailScript.RS]
        return try MailContext(explicitPath: fixture, accountDirectory: AccountDirectory(runner: runner))
    }

    /// Place the link alternately at the lexical and physical leaves. Terminal /. selects the
    /// lexical leaf; an absolute unsuffixed path selects the physical leaf when that leaf exists.
    /// Refusal must precede dependencies, and safe paths must retain the original save destination.
    @Test(arguments: ["", "/", "/.", "/./"],
          [(false, false), (false, true), (true, false), (true, true)])
    func guardChecksTheOriginalSelectedLeaf(suffix: String, state: (Bool, Bool)) throws {
        let (linkAtLexicalLeaf, dangling) = state
        try TestEnvironment.withoutWriteModeOverrides {
            for execute in [false, true] {
                let root = try scratch.directory().resolvingSymlinksInPath()
                let inner = root.appendingPathComponent("physical/inner")
                try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
                let alias = root.appendingPathComponent("alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inner)
                let lexical = root.appendingPathComponent("leaf.bin")
                let physical = root.appendingPathComponent("physical/leaf.bin")
                let link = linkAtLexicalLeaf ? lexical : physical
                let ordinary = linkAtLexicalLeaf ? physical : lexical
                let ordinaryBytes = Data("synthetic ordinary leaf".utf8)
                try ordinaryBytes.write(to: ordinary)
                let sentinel = root.appendingPathComponent("sentinel.bin")
                let sentinelBytes = Data("synthetic sentinel".utf8)
                try sentinelBytes.write(to: sentinel)
                let target = dangling ? root.appendingPathComponent("missing-target") : sentinel
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

                let fake = MailScriptInjectionTests.FakeMailRunner()
                fake.timedResults = ["ok" + MailScript.RS
                    + ["synthetic.pdf", "application/pdf", "123", "1"].joined(separator: MailScript.US)
                    + MailScript.RS]
                fake.untimedResults = ["0" + MailScript.RS]
                let command = try AttachmentsSave.parse([
                    "10", "--out", alias.path + "/../leaf.bin" + suffix,
                    "--allow-outside-home", "--test-mode", execute ? "--execute" : "--dry-run",
                ])
                let stdout = MemoryOutputSink()
                let stderr = MemoryOutputSink()
                var contextCalls = 0
                var scriptCalls = 0
                var exit: ExitCode?
                try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                    do {
                        try command.run(contextFactory: {
                            contextCalls += 1
                            return try context()
                        }, scriptFactory: {
                            scriptCalls += 1
                            return MailScript(runner: fake)
                        })
                    } catch let code as ExitCode { exit = code }
                }
                let envelope = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
                #expect(envelope["tool"] as? String == "mail")
                let terminalDot = suffix == "/." || suffix == "/./"
                let mustRefuse = linkAtLexicalLeaf ? terminalDot : (!terminalDot && !dangling)
                if mustRefuse {
                    #expect(exit?.rawValue == 77)
                    #expect(envelope["ok"] as? Bool == false)
                    #expect(envelope["data"] == nil)
                    let error = envelope["error"] as? [String: Any]
                    #expect(error?["type"] as? String == AppleErrorType.safetyViolation)
                    #expect((error?["message"] as? String)?.contains("symlink") == true)
                    #expect(contextCalls == 0)
                    #expect(scriptCalls == 0)
                    #expect(fake.neverCalled)
                } else {
                    #expect(exit == nil)
                    #expect(envelope["ok"] as? Bool == true)
                    let data = envelope["data"] as? [String: Any]
                    #expect(data?["out_path"] as? String == ordinary.path)
                    #expect(data?["dry_run"] as? Bool == !execute)
                    #expect(contextCalls == 1)
                    #expect(fake.timedCalls.count == 1)
                    #expect(scriptCalls == (execute ? 2 : 1))
                    if execute {
                        #expect(fake.untimedArguments == [["<msg10@host>", "Example Account",
                                                          "0" + MailScript.US + ordinary.path]])
                        #expect(data?["saved_paths"] as? [String] == [ordinary.path])
                    } else {
                        #expect(fake.untimedArguments.isEmpty)
                    }
                }
                #expect(fake.stdinArguments.isEmpty)
                #expect(stderr.data.isEmpty)
                #expect(try Data(contentsOf: sentinel) == sentinelBytes)
                #expect(try Data(contentsOf: ordinary) == ordinaryBytes)
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
                if dangling { #expect(!FileManager.default.fileExists(atPath: target.path)) }
            }
        }
    }

    /// A terminal /. captures the lexical alias spelling. Its resolved parent differs from that
    /// lexical snapshot, so the existing final parent check refuses even a stable alias. Other
    /// suffixes capture the physical path and survive retargeting of the unrelated operator alias.
    @Test(arguments: ["", "/", "/.", "/./"],
          [(false, false), (false, true), (true, false), (true, true)])
    func originalSpellingDeterminesCaptureAndParentValidation(suffix: String,
                                                              posture: (Bool, Bool)) throws {
        let (execute, retarget) = posture
        try TestEnvironment.withoutWriteModeOverrides {
            let root = try scratch.directory().resolvingSymlinksInPath()
            let first = root.appendingPathComponent("first")
            let second = root.appendingPathComponent("second")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
            let captured = first.appendingPathComponent("output.bin")
            let replacement = second.appendingPathComponent("output.bin")
            let originalBytes = Data("synthetic captured output".utf8)
            let replacementBytes = Data("synthetic unrelated output".utf8)
            try originalBytes.write(to: captured)
            try replacementBytes.write(to: replacement)
            let fake = MailScriptInjectionTests.FakeMailRunner()
            fake.timedResults = ["ok" + MailScript.RS
                + ["synthetic.pdf", "application/pdf", "123", "1"].joined(separator: MailScript.US)
                + MailScript.RS]
            fake.untimedResults = ["0" + MailScript.RS]
            let command = try AttachmentsSave.parse([
                "10", "--out", alias.path + "/output.bin" + suffix, "--allow-outside-home",
                "--test-mode", execute ? "--execute" : "--dry-run",
            ])
            let stdout = MemoryOutputSink()
            let stderr = MemoryOutputSink()
            var contextCalls = 0
            var exit: ExitCode?
            try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                do {
                    try command.run(contextFactory: {
                        contextCalls += 1
                        if retarget {
                            try FileManager.default.removeItem(at: alias)
                            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
                        }
                        return try context()
                    }, scriptFactory: { MailScript(runner: fake) })
                } catch let code as ExitCode { exit = code }
            }
            let envelope = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
            #expect(envelope["tool"] as? String == "mail")
            #expect(contextCalls == 1)
            #expect(fake.timedCalls.count == 1)
            let terminalDot = suffix == "/." || suffix == "/./"
            if execute && terminalDot {
                #expect(exit?.rawValue == 77)
                #expect(envelope["ok"] as? Bool == false)
                #expect(envelope["data"] == nil)
                let error = try #require(envelope["error"] as? [String: Any])
                #expect(error["type"] as? String == AppleErrorType.safetyViolation)
                #expect((error["message"] as? String)?.contains("destination parent changed after validation") == true)
                #expect(fake.untimedArguments.isEmpty)
            } else {
                #expect(exit == nil)
                #expect(envelope["ok"] as? Bool == true)
                let data = try #require(envelope["data"] as? [String: Any])
                let selected = terminalDot ? alias.appendingPathComponent("output.bin").path : captured.path
                #expect(data["out_path"] as? String == selected)
                #expect(data["dry_run"] as? Bool == !execute)
                if execute {
                    #expect(fake.untimedArguments == [["<msg10@host>", "Example Account",
                                                      "0" + MailScript.US + captured.path]])
                    #expect(data["saved_paths"] as? [String] == [captured.path])
                    #expect(data["saved"] as? Int == 1)
                } else {
                    #expect(fake.untimedArguments.isEmpty)
                    #expect(data["saved_paths"] == nil)
                }
            }
            #expect(fake.stdinArguments.isEmpty)
            #expect(stderr.data.isEmpty)
            #expect(try Data(contentsOf: captured) == originalBytes)
            #expect(try Data(contentsOf: replacement) == replacementBytes)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path)
                    == (retarget ? second.path : first.path))
        }
    }
}
