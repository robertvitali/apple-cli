import Foundation
import Testing
import ArgumentParser
@testable import AppleKit

/// The error-shaped edges of the output contract: the hand-rolled envelope that exists for when
/// `JSONEncoder` itself fails, and `runGuarded`'s two non-`AppleError` catch arms.
///
/// All of it is stdout-contract code — what an agent parses — and all of it was unreachable from
/// a test before now. The fallback is unreachable BY CONSTRUCTION from `emitError` (the envelope
/// is Strings and Bools, so the encoder cannot fail on it), which left the one path that must
/// never be wrong as the one path nothing checked; it is now a named function so it can be
/// called directly.
@Suite("Output error paths")
struct OutputErrorPathTests {

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the fallback envelope has the same top-level shape as the encoded one")
    func fallbackTopLevelShape() throws {
        let data = Output.fallbackErrorJSON(tool: "mail", type: "upstream_error",
                                            message: "Mail is not running",
                                            status: nil, remediation: nil,
                                            applied: nil, sandbox: nil)
        let obj = try object(data)
        #expect(obj["schema_version"] as? Int == Output.schemaVersion)
        #expect(obj["tool"] as? String == "mail")
        #expect(obj["ok"] as? Bool == false)
        let error = try #require(obj["error"] as? [String: Any])
        #expect(error["type"] as? String == "upstream_error")
        #expect(error["message"] as? String == "Mail is not running")
        // The optional keys are OMITTED, not emitted as null — matching `encodeIfPresent`.
        #expect(error["status"] == nil)
        #expect(error["remediation"] == nil)
        #expect(error["applied"] == nil)
        #expect(error["sandbox"] == nil)
    }

    @Test("the fallback carries status, remediation, applied and sandbox when present")
    func fallbackCarriesEveryField() throws {
        let data = Output.fallbackErrorJSON(
            tool: "contacts", type: "authorization_denied", message: "denied",
            status: "restricted", remediation: "Grant access in System Settings.",
            applied: ["id-1", "id-2"], sandbox: true)
        let error = try #require(try object(data)["error"] as? [String: Any])
        #expect(error["status"] as? String == "restricted")
        #expect(error["remediation"] as? String == "Grant access in System Settings.")
        #expect(error["applied"] as? [String] == ["id-1", "id-2"])
        #expect(error["sandbox"] as? Bool == true)
    }

    @Test("an empty applied list still serializes as an empty array, not a dropped key")
    func fallbackEmptyAppliedArray() throws {
        let data = Output.fallbackErrorJSON(tool: "mail", type: "upstream_error", message: "m",
                                            status: nil, remediation: nil,
                                            applied: [], sandbox: nil)
        let error = try #require(try object(data)["error"] as? [String: Any])
        #expect(error["applied"] as? [String] == [])
    }

    @Test("`sandbox: false` is omitted, never emitted — the never-false invariant")
    func fallbackNeverEmitsSandboxFalse() throws {
        let data = Output.fallbackErrorJSON(tool: "mail", type: "t", message: "m",
                                            status: nil, remediation: nil,
                                            applied: nil, sandbox: false)
        let error = try #require(try object(data)["error"] as? [String: Any])
        #expect(error["sandbox"] == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("sandbox"))
    }

    @Test("every interpolated string is JSON-escaped, so the fallback always parses")
    func fallbackEscapesHostileText() throws {
        let nasty = "quote \" backslash \\ newline \n tab \t control \u{01} slash /"
        let data = Output.fallbackErrorJSON(tool: nasty, type: nasty, message: nasty,
                                            status: nasty, remediation: nasty,
                                            applied: [nasty], sandbox: true)
        let obj = try object(data)   // the parse IS the assertion the fallback exists to make
        #expect(obj["tool"] as? String == nasty)
        let error = try #require(obj["error"] as? [String: Any])
        #expect(error["type"] as? String == nasty)
        #expect(error["message"] as? String == nasty)
        #expect(error["status"] as? String == nasty)
        #expect(error["remediation"] as? String == nasty)
        #expect(error["applied"] as? [String] == [nasty])
    }

    @Test("the encoded and fallback envelopes agree field for field")
    func fallbackMatchesTheEncodedEnvelope() throws {
        let encoded = try Output.encodeError(tool: "reminders", type: "not_found",
                                             message: "no such list", status: "denied",
                                             remediation: "grant it", applied: ["a"],
                                             sandbox: true)
        let fallback = Output.fallbackErrorJSON(tool: "reminders", type: "not_found",
                                                message: "no such list", status: "denied",
                                                remediation: "grant it", applied: ["a"],
                                                sandbox: true)
        let lhs = try object(encoded), rhs = try object(fallback)
        #expect(lhs["schema_version"] as? Int == rhs["schema_version"] as? Int)
        #expect(lhs["tool"] as? String == rhs["tool"] as? String)
        #expect(lhs["ok"] as? Bool == rhs["ok"] as? Bool)
        let le = try #require(lhs["error"] as? [String: Any])
        let re = try #require(rhs["error"] as? [String: Any])
        #expect(Set(le.keys) == Set(re.keys))
        for key in le.keys {
            #expect(String(describing: le[key]!) == String(describing: re[key]!), "key \(key)")
        }
    }

    @Test("a payload that is not a JSON object renders as neutralized text, not `key: value`")
    func humanTextFallsBackForNonObjectPayloads() throws {
        #expect(try Output.humanText([1, 2, 3]) == "[1,2,3]")
        // The fallback still neutralizes: an array payload's strings can carry a driving escape.
        let rendered = try Output.humanText(["\u{1B}[31mred"])
        #expect(!rendered.contains("\u{1B}"))
        #expect(rendered.contains("red"))
    }
}

/// `runGuarded` — the boundary that turns any thrown error into a JSON envelope plus the bound
/// exit code. Its `AppleError` arm is exercised everywhere; the other two were not.
@Suite("runGuarded non-AppleError arms")
struct RunGuardedTests {

    private struct Boom: Error, CustomStringConvertible {
        var description: String { "something went sideways" }
    }

    @Test("an already-intended ExitCode passes through with no envelope written")
    func exitCodePassesThroughSilently() throws {
        let stdout = MemoryOutputSink()
        Output.withStreams(CLIStreams(stdout: stdout, stderr: MemoryOutputSink())) {
            let thrown = #expect(throws: ExitCode.self) {
                try runGuarded(tool: "mail") { throw ExitCode(0) }
            }
            #expect(thrown == ExitCode(0))
        }
        #expect(stdout.data.isEmpty, "a deliberate exit must not emit a second envelope")
    }

    @Test("an unexpected error becomes an `unknown` envelope at exit 70")
    func unexpectedErrorBecomesUnknownEnvelope() throws {
        let stdout = MemoryOutputSink()
        try Output.withStreams(CLIStreams(stdout: stdout, stderr: MemoryOutputSink())) {
            let thrown = #expect(throws: ExitCode.self) {
                try runGuarded(tool: "notes") { throw Boom() }
            }
            #expect(thrown == ExitCode(AppleExit.unknown))

            let obj = try #require(try JSONSerialization.jsonObject(with: stdout.data)
                                   as? [String: Any])
            #expect(obj["ok"] as? Bool == false)
            #expect(obj["tool"] as? String == "notes")
            let error = try #require(obj["error"] as? [String: Any])
            #expect(error["type"] as? String == AppleErrorType.unknown)
            #expect(error["message"] as? String == "something went sideways")
        }
    }

    @Test("a body that returns cleanly writes nothing and throws nothing")
    func cleanBodyIsATransparentPassthrough() throws {
        let stdout = MemoryOutputSink()
        try Output.withStreams(CLIStreams(stdout: stdout, stderr: MemoryOutputSink())) {
            var ran = false
            try runGuarded(tool: "calendar") { ran = true }
            #expect(ran)
        }
        #expect(stdout.data.isEmpty)
    }
}

/// `--text` is the human opt-out, NOT part of the versioned contract — so what is pinned here is
/// that choosing it leaves the JSON path byte-identical, and that everything it prints goes
/// through the terminal neutralizer.
@Suite("Text-aware emit")
struct OutputTextEmitTests {

    private struct Payload: Encodable {
        let name: String
        let count: Int
    }

    private func rendered(_ body: () throws -> Void) rethrows -> String {
        let stdout = MemoryOutputSink()
        try Output.withStreams(CLIStreams(stdout: stdout, stderr: MemoryOutputSink()), operation: body)
        return String(decoding: stdout.data, as: UTF8.self)
    }

    @Test("`--text` renders one flat key-sorted pass instead of the envelope")
    func textRendering() throws {
        let text = try rendered {
            try Output.emit(tool: "notes", data: Payload(name: "note", count: 2), text: true)
        }
        // `write` frames every envelope with a trailing newline, so the text render
        // carries its own plus that framing byte — unchanged from the JSON path.
        #expect(text == "count: 2\nname: note\n\n")
    }

    @Test("`--text: false` is byte-identical to the plain JSON emit")
    func jsonPathUnchangedByTheTextParameter() throws {
        let payload = Payload(name: "note", count: 2)
        let viaFlag = try rendered { try Output.emit(tool: "notes", data: payload, text: false) }
        let viaPlain = try rendered { try Output.emit(tool: "notes", data: payload) }
        #expect(viaFlag == viaPlain)
        #expect(viaFlag.hasPrefix("{\n  \"data\""))
    }

    @Test("a sandboxed text render is prefixed with the sandbox marker")
    func sandboxedTextRender() throws {
        let text = try rendered {
            try Output.emit(tool: "mail", data: Payload(name: "draft", count: 1),
                            text: true, sandboxActive: true)
        }
        #expect(text == "sandbox: true\ncount: 1\nname: draft\n\n")
    }

    @Test("store-derived strings are neutralized on the text path, not passed through")
    func textPathNeutralizesControlSequences() throws {
        let text = try rendered {
            try Output.emit(tool: "notes",
                            data: Payload(name: "\u{1B}[2Jwiped", count: 0), text: true)
        }
        #expect(!text.contains("\u{1B}"))
        #expect(text.contains("wiped"))
    }

    @Test("printText neutralizes and terminates each line; writeOutput passes bytes through")
    func printTextAndWriteOutput() {
        #expect(rendered { Output.printText("\u{1B}[31mred") }.hasSuffix("red\n"))
        #expect(!rendered { Output.printText("\u{1B}[31mred") }.contains("\u{1B}"))
        // Parser-owned help/version text must reach stdout exactly as ArgumentParser rendered it.
        #expect(rendered { Output.writeOutput(Data("USAGE: apple\n".utf8)) } == "USAGE: apple\n")
    }
}

/// Two small surfaces whose only uncovered lines were their least-used constructor and the
/// trailing-slash reduction in the raw-leaf helper.
@Suite("AppleError and path-leaf edges")
struct AppleErrorEdgeTests {

    @Test("notImplemented is an `not_implemented` envelope at the software-error exit code")
    func notImplementedShape() {
        let error = AppleError.notImplemented("attachment editing is not supported")
        #expect(error.type == AppleErrorType.notImplemented)
        #expect(error.message == "attachment editing is not supported")
        #expect(error.exitCode == AppleExit.unknown)
        #expect(error.status == nil)
        #expect(error.remediation == nil)
        #expect(error.applied == nil)
        #expect(error.sandbox == nil)
    }

    @Test("trailing slashes and `/.` spellings reduce to the same final leaf")
    func rawFinalLeafReduction() {
        #expect(rawFinalLeafPath("/private/example/out/") == "/private/example/out")
        #expect(rawFinalLeafPath("/private/example/out///") == "/private/example/out")
        #expect(rawFinalLeafPath("/private/example/out/.") == "/private/example/out")
        #expect(rawFinalLeafPath("/private/example/out/./") == "/private/example/out")
        // Interior dots and `..` are deliberately NOT reduced — the guard checks the operator's
        // own spelling of the final leaf.
        #expect(rawFinalLeafPath("/private/example/../out") == "/private/example/../out")
        #expect(rawFinalLeafPath("/") == "/")
        #expect(rawFinalLeafPath("//") == "/")
        // NOTE for whoever reads the coverage report: the trailing-slash reduction inside this
        // helper is unreachable, because `expandingTildeInPath` has already stripped every
        // trailing slash by the time the loop sees the path (measured: "/a/b/" and "/a/b//" both
        // arrive as "/a/b"; only "/" survives with a trailing slash, and its length excludes it
        // from the loop). It is left in place as defence against that Foundation behaviour
        // changing — an assertion here cannot cover it, and should not be contorted to try.
    }
}
