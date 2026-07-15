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
