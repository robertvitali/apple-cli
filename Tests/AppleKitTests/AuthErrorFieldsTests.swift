import Testing
import Foundation
@testable import AppleKit

/// `error.status` / `error.remediation` on the JSON error envelope (CONTACTS-M2).
///
/// THE GAP. Every Apple MCP this CLI replaces returns an authorization failure as FOUR keys —
/// `error_type`, `error`, `status`, `remediation` (`apple_contacts_mcp/server.py:113-126`) — and
/// documents that a client should branch on `status`: `notDetermined` means prompt, `denied` means
/// send the user to System Settings, `restricted` means MDM forbids it and retrying is pointless.
/// Our envelope carried only `type` + `message`, and the domains concatenated the other two into
/// the message prose. The information was visible to a human and unavailable to a machine, which
/// inverts the point of a JSON contract.
///
/// WHY IT WAS DEFERRED, AND WHY THAT WAS WRONG. The recorded reason was envelope uniformity: a
/// Contacts-only shape would make error payloads inconsistent across six domains. That is a real
/// concern and it argues for adding the fields ONCE CENTRALLY — which is what this does, in
/// `AppleKit` — not for leaving a capability dropped.
///
/// BUMP: adding the two optional fields is MINOR (docs/versioning-policy.md §3.1 "add optional
/// output field"), but this change ALSO altered the denial `message` — it no longer has the
/// remediation appended. §3 counts an output-value correction as breaking "if any agent might
/// parse the old value", and parsing that message was the only way to recover the remediation
/// before, so the change is called out as BREAKING. I first labelled the whole thing MINOR on the
/// strength of the additive half; review caught it.
@Suite("error envelope — authorization status/remediation")
struct AuthErrorFieldsTests {

    private func decode(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    private func errorObject(_ data: Data) throws -> [String: Any] {
        try decode(data)["error"] as? [String: Any] ?? [:]
    }

    @Test("a denial carries status and remediation as their own keys")
    func denialCarriesBothFields() throws {
        let data = try Output.encodeError(
            tool: "contacts", type: AppleErrorType.permissionDenied,
            message: "Contacts access not granted (status=denied).",
            status: "denied",
            remediation: "Contacts access was denied. Open System Settings → Privacy & Security → Contacts.")
        let err = try errorObject(data)
        #expect(err["type"] as? String == "authorization_denied")
        #expect(err["status"] as? String == "denied")
        #expect((err["remediation"] as? String)?.hasPrefix("Contacts access was denied.") == true)
        // The message must NOT have the remediation concatenated onto it — matching the oracle,
        // whose `error` string is exactly "Contacts access not granted (status=denied)." That
        // concatenation is what this change removes, so assert its absence rather than trusting it.
        #expect(err["message"] as? String == "Contacts access not granted (status=denied).")
    }

    /// The keys must be ABSENT, not `null`. A consumer doing `if "status" in error` is the natural
    /// way to test for an authorization dimension, and `null` would satisfy it wrongly. This is the
    /// `encodeIfPresent` behaviour of the synthesized `Encodable`, so it is a property of the
    /// declaration being `Optional` — worth pinning, because switching to a non-optional with a
    /// sentinel default would silently break it.
    @Test("errors with no authorization dimension omit the keys entirely")
    func nonAuthErrorsOmitBothKeys() throws {
        let data = try Output.encodeError(tool: "notes", type: AppleErrorType.validation,
                                          message: "limit must be >= 1")
        let err = try errorObject(data)
        #expect(err["message"] as? String == "limit must be >= 1")
        #expect(err.keys.contains("status") == false, "status must be omitted, not null")
        #expect(err.keys.contains("remediation") == false, "remediation must be omitted, not null")

        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("null") == false, "envelope should carry no null values: \(raw)")
    }

    @Test("AppleError.permissionDenied threads both fields through to the envelope")
    func factoryThreadsFields() throws {
        let e = AppleError.permissionDenied("m", status: "restricted", remediation: "ask your admin")
        #expect(e.type == "authorization_denied")
        #expect(e.exitCode == AppleExit.permissionDenied)
        #expect(e.status == "restricted")
        #expect(e.remediation == "ask your admin")

        // …and the pre-existing one-argument spelling still compiles and leaves them nil, which is
        // what keeps the ~30 non-TCC call sites unchanged.
        let plain = AppleError.permissionDenied("m")
        #expect(plain.status == nil)
        #expect(plain.remediation == nil)
    }

    /// The oracle's request-timeout branch (`server.py:99-109`) returns `status` but deliberately
    /// NO `remediation` — the system prompt is already on screen, so "open System Settings" is the
    /// wrong instruction. Pinning the asymmetry so a later "tidy-up" does not add one.
    @Test("status without remediation is representable")
    func statusWithoutRemediation() throws {
        let data = try Output.encodeError(tool: "contacts", type: AppleErrorType.permissionDenied,
                                          message: "Contacts permission prompt is awaiting your response. "
                                                 + "Grant access in the system dialog and retry.",
                                          status: "notDetermined")
        let err = try errorObject(data)
        #expect(err["status"] as? String == "notDetermined")
        #expect(err.keys.contains("remediation") == false)
    }

    /// Envelope invariants that must survive the two added keys.
    @Test("the envelope is still well-formed and ok:false")
    func envelopeShapeUnchanged() throws {
        let data = try Output.encodeError(tool: "contacts", type: AppleErrorType.permissionDenied,
                                          message: "m", status: "denied", remediation: "r")
        let top = try decode(data)
        #expect(top["ok"] as? Bool == false)
        #expect(top["tool"] as? String == "contacts")
        #expect(top["schema_version"] as? Int == Output.schemaVersion)
        #expect(top["data"] == nil, "an error envelope must not carry a data key")
    }

    /// Closes a gap review flagged: the `AppleError` → envelope FORWARDING in `runGuarded` was
    /// untested. The tests above prove `encodeError` renders the fields when handed them; they say
    /// nothing about whether the catch site actually passes them, which is the part most likely to
    /// be wrong (and was silently absent before this change). `runGuarded` itself writes to stdout
    /// and throws `ExitCode`, so it is not directly observable from a test — hence the mapping now
    /// lives in `encodeError(tool:from:)`, which `runGuarded` calls and this exercises.
    @Test("the AppleError → envelope mapping copies every field")
    func errorToEnvelopeMappingIsComplete() throws {
        let e = AppleError.permissionDenied("Contacts access not granted (status=denied).",
                                            status: "denied", remediation: "open settings")
        let err = try errorObject(try Output.encodeError(tool: "contacts", from: e))
        #expect(err["type"] as? String == e.type)
        #expect(err["message"] as? String == e.message)
        #expect(err["status"] as? String == e.status)
        #expect(err["remediation"] as? String == e.remediation)

        // A non-authorization error routed through the SAME path must still omit both keys — this
        // is the direction that would break if the overload hard-coded a default status.
        let v = try errorObject(try Output.encodeError(tool: "notes", from: .validation("bad")))
        #expect(v["type"] as? String == "validation_error")
        #expect(v.keys.contains("status") == false)
        #expect(v.keys.contains("remediation") == false)
    }
}
