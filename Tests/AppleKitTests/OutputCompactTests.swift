import Foundation
import Testing
@testable import AppleKit

/// Literal compatibility fixtures established before adding compact encoding.
@Suite("Pretty envelope byte compatibility")
struct OutputPrettyCompatibilityTests {
    struct Payload: Encodable { let hello = "sample/path" }

    @Test func successWithoutSandbox() throws {
        let expected = """
        {
          "data" : {
            "hello" : "sample/path"
          },
          "ok" : true,
          "schema_version" : 1,
          "tool" : "messages"
        }
        """
        #expect(try Output.encodeSuccess(tool: "messages", data: Payload()) == Data(expected.utf8))
    }

    @Test func successWithSandbox() throws {
        let expected = """
        {
          "data" : {
            "hello" : "sample/path"
          },
          "ok" : true,
          "sandbox" : true,
          "schema_version" : 1,
          "tool" : "messages"
        }
        """
        #expect(try Output.encodeSuccess(tool: "messages", data: Payload(), sandboxActive: true)
                == Data(expected.utf8))
    }

    @Test func fullErrorWithSandbox() throws {
        let expected = """
        {
          "error" : {
            "applied" : [
              "sample-one",
              "sample-two"
            ],
            "message" : "sample/path",
            "remediation" : "check/settings",
            "sandbox" : true,
            "status" : "denied",
            "type" : "synthetic"
          },
          "ok" : false,
          "schema_version" : 1,
          "tool" : "messages"
        }
        """
        try checkError(sandbox: true, expected: expected)
    }

    @Test(arguments: [false, nil] as [Bool?])
    func fullErrorWithoutSandbox(sandbox: Bool?) throws {
        let expected = """
        {
          "error" : {
            "applied" : [
              "sample-one",
              "sample-two"
            ],
            "message" : "sample/path",
            "remediation" : "check/settings",
            "status" : "denied",
            "type" : "synthetic"
          },
          "ok" : false,
          "schema_version" : 1,
          "tool" : "messages"
        }
        """
        try checkError(sandbox: sandbox, expected: expected)
    }

    private func checkError(sandbox: Bool?, expected: String) throws {
        let error = AppleError(type: "synthetic", message: "sample/path", exitCode: 69,
                               status: "denied", remediation: "check/settings",
                               applied: ["sample-one", "sample-two"], sandbox: sandbox)
        #expect(try Output.encodeError(tool: "messages", from: error) == Data(expected.utf8))
        #expect(try Output.encodeError(tool: "messages", type: error.type, message: error.message,
                                      status: error.status, remediation: error.remediation,
                                      applied: error.applied, sandbox: sandbox) == Data(expected.utf8))
    }
}

@Suite("Compact output envelopes")
struct OutputCompactTests {
    struct Payload: Encodable {
        let date = Date(timeIntervalSince1970: 0)
        let nested = ["path": "sample/path"]
        let values = [1, 2]
    }

    @Test func successBytes() throws {
        let plain = try Output.encodeCompactSuccess(tool: "messages", data: Payload())
        let sandbox = try Output.encodeCompactSuccess(tool: "messages", data: Payload(), sandboxActive: true)
        #expect(plain == Data(#"{"data":{"date":"1970-01-01T00:00:00Z","nested":{"path":"sample/path"},"values":[1,2]},"ok":true,"schema_version":1,"tool":"messages"}"#.utf8))
        #expect(sandbox == Data(#"{"data":{"date":"1970-01-01T00:00:00Z","nested":{"path":"sample/path"},"values":[1,2]},"ok":true,"sandbox":true,"schema_version":1,"tool":"messages"}"#.utf8))
        try checkEquivalent(plain, Output.encodeSuccess(tool: "messages", data: Payload()))
        try checkEquivalent(sandbox, Output.encodeSuccess(tool: "messages", data: Payload(), sandboxActive: true))
        checkUnframed(plain)
        checkUnframed(sandbox)
    }

    @Test(arguments: [true, false, nil] as [Bool?])
    func errorBytes(sandbox: Bool?) throws {
        let error = AppleError(type: "synthetic", message: "sample/path", exitCode: 69,
                               status: "denied", remediation: "check/settings",
                               applied: ["sample-one", "sample-two"], sandbox: sandbox)
        let data = try Output.encodeCompactError(tool: "messages", from: error)
        let expected = sandbox == true
            ? #"{"error":{"applied":["sample-one","sample-two"],"message":"sample/path","remediation":"check/settings","sandbox":true,"status":"denied","type":"synthetic"},"ok":false,"schema_version":1,"tool":"messages"}"#
            : #"{"error":{"applied":["sample-one","sample-two"],"message":"sample/path","remediation":"check/settings","status":"denied","type":"synthetic"},"ok":false,"schema_version":1,"tool":"messages"}"#
        #expect(data == Data(expected.utf8))
        try checkEquivalent(data, Output.encodeError(tool: "messages", from: error))
        try checkEquivalent(data, Output.fallbackErrorJSON(
            tool: "messages", type: error.type, message: error.message, status: error.status,
            remediation: error.remediation, applied: error.applied, sandbox: sandbox))
        checkUnframed(data)
    }

    @Test func omittedFieldsAndEmptyApplied() throws {
        let minimal = AppleError(type: "synthetic", message: "sample/path", exitCode: 69)
        #expect(try Output.encodeCompactError(tool: "messages", from: minimal)
                == Data(#"{"error":{"message":"sample/path","type":"synthetic"},"ok":false,"schema_version":1,"tool":"messages"}"#.utf8))
        let empty = AppleError(type: "synthetic", message: "sample/path", exitCode: 69, applied: [])
        #expect(try Output.encodeCompactError(tool: "messages", from: empty)
                == Data(#"{"error":{"applied":[],"message":"sample/path","type":"synthetic"},"ok":false,"schema_version":1,"tool":"messages"}"#.utf8))
        let internalError = AppleError.outputLimitExplicitInvalid()
        #expect(internalError.outputLimitOrigin != nil)
        let data = try Output.encodeCompactError(tool: "messages", from: internalError)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try #require(object["error"] as? [String: Any])
        #expect(Set(fields.keys) == ["type", "message"])
    }

    @Test func escapingAndUnicodeSeparators() throws {
        let text = "quote \" slash / backslash \\ nul \u{0} cr\r lf\n π 🧪 \u{85}\u{2028}\u{2029}"
        let success = try Output.encodeCompactSuccess(tool: "messages", data: ["text": text])
        let expectedSuccess = #"{"data":{"text":"quote \" slash / backslash \\ nul \u0000 cr\r lf\n π 🧪 \#u{85}\#u{2028}\#u{2029}"},"ok":true,"schema_version":1,"tool":"messages"}"#
        #expect(success == Data(expectedSuccess.utf8))
        let error = AppleError(type: "synthetic", message: text, exitCode: 69)
        let failure = try Output.encodeCompactError(tool: "messages", from: error)
        let expectedFailure = #"{"error":{"message":"quote \" slash / backslash \\ nul \u0000 cr\r lf\n π 🧪 \#u{85}\#u{2028}\#u{2029}","type":"synthetic"},"ok":false,"schema_version":1,"tool":"messages"}"#
        #expect(failure == Data(expectedFailure.utf8))
        for data in [success, failure] {
            checkUnframed(data)
            #expect(!data.contains(0))
            // These valid JSON scalars are not NDJSON record boundaries; only byte 0x0A is.
            for scalar in ["\u{85}", "\u{2028}", "\u{2029}"] {
                #expect(data.range(of: Data(scalar.utf8)) != nil)
            }
        }
        try checkEquivalent(success, Output.encodeSuccess(tool: "messages", data: ["text": text]))
        try checkEquivalent(failure, Output.encodeError(tool: "messages", from: error))
    }

    struct Sentinel: Error, Equatable { let marker: Int }
    struct ThrowingPayload: Encodable {
        func encode(to encoder: Encoder) throws { throw Sentinel(marker: 731) }
    }

    @Test func thrownErrorsPropagateWithoutOutput() throws {
        let stdout = MemoryOutputSink()
        let stderr = MemoryOutputSink()
        try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
            _ = try Output.encodeCompactSuccess(tool: "messages", data: Payload())
            _ = try Output.encodeCompactError(tool: "messages", from: .validation("sample/path"))
            do {
                _ = try Output.encodeCompactSuccess(tool: "messages", data: ThrowingPayload())
                Issue.record("Expected the payload's sentinel error")
            } catch {
                #expect(error as? Sentinel == Sentinel(marker: 731))
            }
            for number in [Double.infinity, -Double.infinity, Double.nan] {
                do {
                    _ = try Output.encodeCompactSuccess(tool: "messages", data: number)
                    Issue.record("Expected EncodingError.invalidValue")
                } catch EncodingError.invalidValue(let value, _) {
                    let actual = try #require(value as? Double)
                    #expect(number.isNaN ? actual.isNaN : actual == number)
                } catch {
                    Issue.record("Unexpected encoding error type")
                }
            }
        }
        #expect(stdout.data.isEmpty)
        #expect(stderr.data.isEmpty)
    }

    @Test func existingFunctionValuesAndPrettyEncodeRemainCompatible() throws {
        let success: (String, Payload, Bool) throws -> Data = Output.encodeSuccess
        let error: (String, AppleError) throws -> Data = Output.encodeError
        let fields: (String, String, String, String?, String?, [String]?, Bool?) throws -> Data = Output.encodeError
        #expect(try success("messages", Payload(), false).contains(0x0A))
        #expect(try error("messages", .validation("sample/path")).contains(0x0A))
        #expect(try fields("messages", "synthetic", "sample/path", nil, nil, nil, nil).contains(0x0A))
        #expect(try Output.encode(["sample": "path"]) == Data("{\n  \"sample\" : \"path\"\n}".utf8))
    }

    private func checkUnframed(_ data: Data) {
        #expect(data.first == 0x7B)
        #expect(data.last == 0x7D)
        #expect(!data.contains(0x0A))
        #expect(!data.contains(0x0D))
    }

    // Supplementary only: the literal byte fixtures above distinguish JSON booleans/numbers.
    private func checkEquivalent(_ first: Data, _ second: Data) throws {
        let lhs = try #require(JSONSerialization.jsonObject(with: first) as? NSDictionary)
        let rhs = try #require(JSONSerialization.jsonObject(with: second) as? NSDictionary)
        #expect(lhs == rhs)
    }
}
