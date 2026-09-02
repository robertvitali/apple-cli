import Foundation
import Testing
import AppleKit
import ArgumentParser
@testable import apple

@Suite("Apple root driver")
struct AppleDriverTests {
    private struct ProbeError: Error, CustomStringConvertible {
        let description = "synthetic driver failure"
    }

    private func streams() -> (CLIStreams, MemoryOutputSink, MemoryOutputSink) {
        let stdout = MemoryOutputSink()
        let stderr = MemoryOutputSink()
        return (CLIStreams(stdout: stdout, stderr: stderr), stdout, stderr)
    }

    @Test("help writes to stdout and returns success without terminating")
    func help() {
        let (streams, stdout, stderr) = streams()

        let status = Apple.execute(arguments: ["apple", "--help"], streams: streams)

        #expect(status == 0)
        #expect(String(decoding: stdout.data, as: UTF8.self).contains("USAGE: apple"))
        #expect(stderr.data.isEmpty)
    }

    @Test("built-in version writes its exact line to stdout")
    func builtInVersion() {
        let (streams, stdout, stderr) = streams()

        let status = Apple.execute(arguments: ["apple", "--version"], streams: streams)

        #expect(status == 0)
        #expect(stdout.data == Data((AppleVersion.current + "\n").utf8))
        #expect(stderr.data.isEmpty)
    }

    @Test("version subcommand dispatches successfully through the real root")
    func versionCommand() throws {
        let (streams, stdout, stderr) = streams()

        let status = Apple.execute(arguments: ["apple", "version"], streams: streams)

        #expect(status == 0)
        let object = try #require(
            JSONSerialization.jsonObject(with: stdout.data) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == true)
        #expect(object["tool"] as? String == "version")
        #expect((object["data"] as? [String: Any])?["version"] as? String == AppleVersion.current)
        #expect(stderr.data.isEmpty)
    }

    @Test("parse failures keep details on stderr and a domain envelope on stdout")
    func parseFailure() throws {
        let (streams, stdout, stderr) = streams()

        let status = Apple.execute(
            arguments: ["apple", "notes", "--definitely-invalid"],
            streams: streams
        )

        #expect(status == AppleExit.usage)
        let object = try #require(
            JSONSerialization.jsonObject(with: stdout.data) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == false)
        #expect(object["tool"] as? String == "notes")
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["type"] as? String == AppleErrorType.validation)
        #expect(error["message"] as? String == "invalid arguments (see stderr for details)")
        let detail = String(decoding: stderr.data, as: UTF8.self)
        #expect(detail.contains("--definitely-invalid"))
        #expect(detail.contains("Usage: apple notes"))
    }

    @Test("unexpected command errors become internal envelopes and software exits")
    func unexpectedError() throws {
        let (streams, stdout, stderr) = streams()

        let status = Apple.execute(
            arguments: ["apple", "version"],
            streams: streams,
            runner: { _ in throw ProbeError() }
        )

        #expect(status == AppleExit.unknown)
        let object = try #require(
            JSONSerialization.jsonObject(with: stdout.data) as? [String: Any]
        )
        #expect(object["tool"] as? String == "version")
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["type"] as? String == AppleErrorType.unknown)
        #expect(error["message"] as? String == "internal error (see stderr for details)")
        #expect(String(decoding: stderr.data, as: UTF8.self) == "Error: synthetic driver failure\n")
    }

    @Test("command ExitCode is returned without a duplicate root envelope")
    func commandExitCode() throws {
        let (streams, stdout, stderr) = streams()

        let status = Apple.execute(
            arguments: ["apple", "version"],
            streams: streams,
            runner: { _ in
                Output.emitError(tool: "version", type: AppleErrorType.notFound, message: "missing")
                throw ExitCode(AppleExit.notFound)
            }
        )

        #expect(status == AppleExit.notFound)
        let object = try #require(
            JSONSerialization.jsonObject(with: stdout.data) as? [String: Any]
        )
        #expect(object["tool"] as? String == "version")
        #expect((object["error"] as? [String: Any])?["type"] as? String == AppleErrorType.notFound)
        #expect(stderr.data.isEmpty)
        let text = String(decoding: stdout.data, as: UTF8.self)
        #expect(text.components(separatedBy: "\"schema_version\"").count == 2)
    }

    @Test("negative option values are preprocessed before real root parsing")
    func negativeValuePreprocessing() {
        let (streams, stdout, stderr) = streams()
        var dispatched = false

        let status = Apple.execute(
            arguments: ["apple", "messages", "recent", "--hours", "-1"],
            streams: streams,
            runner: { _ in dispatched = true }
        )

        #expect(status == 0)
        #expect(dispatched)
        #expect(stdout.data.isEmpty)
        #expect(stderr.data.isEmpty)
    }
}
