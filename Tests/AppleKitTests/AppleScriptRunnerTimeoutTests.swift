import Foundation
import Testing
@testable import AppleKit

@Suite("AppleScript runner deadlines")
struct AppleScriptRunnerTimeoutTests {
    @Test func fastScriptCompletesThroughTimedAPI() throws {
        let out = try AppleScriptRunner().run("return \"ok\"", timeout: 10)
        #expect(out == "ok")
    }

    @Test func deadlineTerminatesStalledOsaScript() throws {
        let started = Date()
        let error = #expect(throws: AppleScriptRunner.TimeoutError.self) {
            _ = try AppleScriptRunner().run("delay 5\nreturn \"late\"", timeout: 0.05)
        }
        let timeout = try #require(error)
        #expect(timeout.seconds == 0.05)
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(timeout.description == "osascript timed out after 0.05s")
    }

    @Test func invalidDeadlineFailsBeforeLaunchWithoutDescriptionTrap() throws {
        let error = #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) {
            _ = try AppleScriptRunner().run("return \"never\"", timeout: .infinity)
        }
        let invalid = try #require(error)
        #expect(invalid.description == "invalid osascript timeout: inf")
    }

    @Test func overRangeFiniteDeadlineFailsBeforeLaunch() throws {
        let error = #expect(throws: AppleScriptRunner.InvalidTimeoutError.self) {
            _ = try AppleScriptRunner().run("return \"never\"", timeout: 10_000_000_000)
        }
        #expect(try #require(error).seconds == 10_000_000_000)
    }
}
