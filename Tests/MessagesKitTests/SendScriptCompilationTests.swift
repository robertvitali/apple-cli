import Foundation
import Testing
@testable import MessagesKit
import TestSupport

/// Compile-check every AppleScript `Send.perform` can emit.
///
/// WHY THIS EXISTS: the script bodies are assembled from Swift strings, so `swift build` and the
/// rest of the logic tier never parse them as AppleScript — a syntax error surfaces only at
/// runtime, on a LIVE send to a real person, which is the one path this repo may not exercise.
/// `osacompile` parses and resolves terminology WITHOUT running anything, so it gives real
/// coverage of the tier that otherwise has none. This is the Messages counterpart of the Mail
/// domain's `bats/helpers/applescript_syntax_check.py`; it lives in the Swift tier rather than in
/// bats because `bats/` files are frozen against branch work by the trusted-catalog gate in
/// `scripts/ci/bats_inventory.py`.
///
/// NOTHING IS EXECUTED HERE, and nothing may be added that does. `osacompile` only writes a
/// compiled `.scpt`; the same script under `osascript` would drive Messages.app and send to a real
/// human. The distinction is the whole reason this test is allowed to exist.
@Suite("Send AppleScript compilation")
struct SendScriptCompilationTests {
    private let scratch = ScratchDirs("messages-send-osacompile")

    private static let compiler = "/usr/bin/osacompile"

    /// `tell application "Messages"` makes the compiler resolve that app's scripting terminology,
    /// so the app bundle has to be on the machine. Both are true of every macOS install and of the
    /// hosted runners; the condition exists so a stripped image reports SKIPPED rather than a
    /// misleading red.
    static let toolchainAvailable: Bool = {
        let messages = ["/System/Applications/Messages.app", "/Applications/Messages.app"]
        return FileManager.default.isExecutableFile(atPath: compiler)
            && messages.contains { FileManager.default.fileExists(atPath: $0) }
    }()

    /// Every shape `perform` can build: 3 services x with/without a body, plus group x
    /// with/without a body.
    static var everyShape: [(name: String, source: String)] {
        var shapes: [(String, String)] = []
        for service in Send.Service.allCases {
            for includeMessage in [true, false] {
                shapes.append(("direct-\(service.rawValue)-body-\(includeMessage)",
                               Send.directScript(service: service, includeMessage: includeMessage)))
            }
        }
        for includeMessage in [true, false] {
            shapes.append(("group-body-\(includeMessage)",
                           Send.groupScript(includeMessage: includeMessage)))
        }
        return shapes
    }

    /// The count is asserted separately from the compile loop so that a builder which stopped
    /// emitting a shape — or a loop that quietly stopped covering one — fails here instead of
    /// passing with less coverage than the name of this suite claims.
    @Test func everyEmittedShapeIsEnumerated() {
        #expect(Self.everyShape.count == 8)
        #expect(Set(Self.everyShape.map(\.name)).count == 8)
    }

    @Test(.enabled(if: SendScriptCompilationTests.toolchainAvailable))
    func everyEmittedShapeCompilesAsAppleScript() throws {
        let dir = try scratch.directory()
        for (name, source) in Self.everyShape {
            let sourceURL = dir.appendingPathComponent("\(name).applescript")
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.compiler)
            process.arguments = ["-o", dir.appendingPathComponent("\(name).scpt").path, sourceURL.path]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            try process.run()
            // Drained BEFORE the wait: a compiler diagnostic is small, but reading after the wait
            // is the shape that deadlocks once a child fills its pipe.
            let stderr = String(decoding: try errors.fileHandleForReading.readToEnd() ?? Data(),
                                as: UTF8.self)
            process.waitUntilExit()

            #expect(process.terminationStatus == 0,
                    "\(name) is not valid AppleScript: \(stderr)")
        }
    }
}
