import Foundation
import Testing
@testable import AppleKit

/// One test, and deliberately only one. The four that ran the REAL `/usr/bin/osascript` here are
/// covered hermetically in `ScriptLauncherTests.swift`: `timedFormBuildsTheSameArgv` +
/// `deadlineFormSuccess`, `deadlineTerminatesAStalledChild` +
/// `deadlineEscalatesPastAnIgnoredTerminate`, `invalidDeadlineNeverReachesTheLauncher`,
/// `deadlineBoundary`, and `AppleScriptOutcomeTests.timeoutDescription` for the fractional
/// "osascript timed out after 0.5s" rendering.
///
/// What a fake cannot show is that the PUBLIC `AppleScriptRunner()` — which binds
/// `OsascriptLauncher`, unlike the `init(launcher:)` every hermetic test uses — validates a
/// deadline before it can launch. The refusal is observable; that nothing spawned is not directly
/// assertable, but a validation moved after the launch would hang here rather than pass, since
/// `.infinity` never expires.
@Suite("AppleScript runner deadlines")
struct AppleScriptRunnerTimeoutTests {

    @Test("the production initializer refuses an invalid deadline without launching anything")
    func productionRunnerRefusesAnInvalidDeadline() throws {
        let error = #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) {
            _ = try AppleScriptRunner().run("return \"never\"", timeout: .infinity)
        }
        #expect(try #require(error).seconds == .infinity)
        #expect(try #require(error).description == "invalid osascript timeout: inf")
    }
}
