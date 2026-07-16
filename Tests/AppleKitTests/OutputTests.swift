import Testing
import Foundation
@testable import AppleKit

// Logic-tier tests — no Apple permissions / TCC required; runnable in CI.
//
// Uses swift-testing (`import Testing`), NOT XCTest: on macOS the open-source /
// swiftly toolchain bundles swift-testing but NOT XCTest (XCTest ships only with
// full Xcode). Run locally with the swiftly toolchain:
//     PATH="$HOME/.swiftly/bin:$PATH" swift test

@Suite("Output envelope")
struct OutputTests {
    struct Payload: Encodable { let hello: String }

    @Test("success envelope carries schema_version, ok=true, tool, and data")
    func successShape() throws {
        let data = try Output.encodeSuccess(tool: "messages", data: Payload(hello: "world"))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["schema_version"] as? Int == 1)
        #expect(obj["ok"] as? Bool == true)
        #expect(obj["tool"] as? String == "messages")
        #expect((obj["data"] as? [String: Any])?["hello"] as? String == "world")
    }

    @Test("error envelope carries ok=false and a typed error")
    func errorShape() throws {
        let data = try Output.encodeError(tool: "mail", type: AppleErrorType.notFound, message: "nope")
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["ok"] as? Bool == false)
        #expect(obj["tool"] as? String == "mail")
        let err = obj["error"] as? [String: Any]
        #expect(err?["type"] as? String == "not_found")
        #expect(err?["message"] as? String == "nope")
    }

    @Test("output is deterministic (sorted keys) for snapshot stability")
    func deterministic() throws {
        let a = try Output.encodeSuccess(tool: "notes", data: Payload(hello: "x"))
        let b = try Output.encodeSuccess(tool: "notes", data: Payload(hello: "x"))
        #expect(a == b)
    }
}

/// Locks the `emitError` last-ditch fallback escaper (`Output.jsonString`). That path only
/// fires when `JSONEncoder` itself fails, so it MUST hand-roll RFC-8259-valid JSON without
/// depending on the encoder — a raw quote/backslash/newline/control char in the message
/// must not break the very parse the fallback exists to guarantee.
@Suite("emitError fallback JSON escaping")
struct JSONStringEscapingTests {
    /// Wrap the escaped output as a JSON value and confirm a STRICT parser both accepts it
    /// AND recovers the exact original string. This is the property the fallback depends on.
    private func roundTrip(_ s: String) throws {
        let json = "{\"m\":\(Output.jsonString(s))}"
        let obj = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["m"] as? String == s)
    }

    @Test("escapes quotes/backslashes/newlines/tabs/control chars — round-trips exactly")
    func nasties() throws {
        try roundTrip("plain")
        try roundTrip("with \"double quotes\"")
        try roundTrip(#"back\slash and \" mixed"#)
        try roundTrip("line1\nline2\r\nline3")
        try roundTrip("tab\tseparated")
        try roundTrip("bell\u{07} null-ish \u{01}\u{1f} end")
        try roundTrip("unicode π 🚀 café")
        try roundTrip("")
    }

    @Test("produces a quoted JSON string literal with the expected short escapes")
    func shapes() {
        #expect(Output.jsonString("x").hasPrefix("\""))
        #expect(Output.jsonString("x").hasSuffix("\""))
        #expect(Output.jsonString("a\"b") == "\"a\\\"b\"")
        #expect(Output.jsonString("a\\b") == "\"a\\\\b\"")
        #expect(Output.jsonString("a\nb") == "\"a\\nb\"")
        #expect(Output.jsonString("\u{01}") == "\"\\u0001\"")
    }
}
