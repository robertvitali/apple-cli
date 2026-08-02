import Testing
import Foundation
@testable import MailKit
import AppleKit

/// Oracle A's two input caps, ported as BUCKET 1 (oracle-mirrored ⇒ unconditional, sandbox or not).
/// Write-model v2 lifts CLI-ONLY restrictions; it does not lift limits the oracle itself enforces.
///
/// The scoping is the fragile part of both ports, in BOTH directions:
///   - too narrow ⇒ a gate the oracle has goes missing;
///   - too WIDE  ⇒ the CLI refuses input the oracle accepts, i.e. drops capability, which
///     `AGENTS.md` calls a failure just as loudly.
/// The first cut of this change failed the second way (it capped recipients on reply, forward and
/// draft-rich, none of which either oracle caps), so the negative tests below — the ones asserting
/// that an over-cap input is ACCEPTED — are the load-bearing ones here, not the refusals.
@Suite("Oracle A safety caps")
struct OracleSafetyCapTests {
    // MARK: - Recipient cap (security.py:89-91 `max_recipients`, reached only via
    // `validate_send_operation` at server.py:898 `send_email` and :1085 `send_email_with_attachments`)

    @Test("the recipient cap is the oracle's 100, verbatim")
    func capConstant() { #expect(outboundRecipientCap == 100) }

    func addrs(_ n: Int) -> [String] { (0..<n).map { "u\($0)@example.com" } }

    @Test("100 recipients pass; 101 are refused — the boundary is inclusive as in the oracle")
    func boundaryIsInclusive() {
        // Oracle: `if len(all_recipients) > max_recipients` → 100 allowed, 101 not.
        #expect(throws: Never.self) {
            try guardOutbound(recipients: addrs(100), sandboxActive: false, applyRecipientCap: true)
        }
        #expect(throws: AppleError.self) {
            try guardOutbound(recipients: addrs(101), sandboxActive: false, applyRecipientCap: true)
        }
    }

    /// THE bucket-1 property: unconditional. A CLI-only gate would vanish outside the sandbox;
    /// this one must not, because the oracle applies it on every send regardless of any mode.
    @Test("UNCONDITIONAL PIN: on a capped surface the cap applies with the sandbox OFF as well as on")
    func appliesUnsandboxed() {
        for sandbox in [false, true] {
            #expect(throws: AppleError.self) {
                try guardOutbound(recipients: addrs(101), sandboxActive: sandbox, applyRecipientCap: true)
            }
        }
    }

    /// STRICT-SUPERSET PIN — the regression this change was corrected for.
    ///
    /// `forward_message` checks only `if not to:` and `reply_to_message` validates nothing
    /// (oracle A), and oracle B has no recipient cap anywhere. A 101-recipient forward or reply is
    /// therefore ACCEPTED by both oracles, so the CLI must accept it too. If someone later defaults
    /// `applyRecipientCap` to true "for safety", this test is what fails.
    @Test("SUPERSET PIN: an uncapped surface accepts 101 recipients, as both oracles do")
    func uncappedSurfacesAcceptOverCap() {
        #expect(throws: Never.self) {
            try guardOutbound(recipients: addrs(101), sandboxActive: false, applyRecipientCap: false)
        }
        #expect(throws: Never.self) {
            try guardOutbound(recipients: addrs(5_000), sandboxActive: false, applyRecipientCap: false)
        }
    }

    @Test("the cap is checked BEFORE the sandbox allowlist, so its message is the one surfaced")
    func capPrecedesAllowlist() {
        // 101 non-allowlisted recipients WITH the sandbox on: both checks would refuse, but the
        // count check runs first, so the operator is told the actionable thing (too many), not
        // "recipient #1 is not allowlisted".
        do {
            try guardOutbound(recipients: addrs(101), sandboxActive: true, applyRecipientCap: true)
            Issue.record("expected a refusal")
        } catch {
            #expect(String(describing: error).contains("Too many recipients"))
        }
    }

    @Test("an empty recipient list is refused on every surface, capped or not")
    func emptyStillRefused() {
        for cap in [false, true] {
            #expect(throws: AppleError.self) {
                try guardOutbound(recipients: [], sandboxActive: false, applyRecipientCap: cap)
            }
        }
    }

    // MARK: - Bulk cap (mark_as_read via validate_bulk_operation server.py:995;
    //                  delete_messages inline server.py:1719-1725)

    @Test("the bulk cap is the oracle's 100, verbatim")
    func bulkCapConstant() { #expect(bulkOperationCap == 100) }

    func ids(_ n: Int) -> [String] { (0..<n).map(String.init) }

    @Test("bulk boundary is inclusive: 100 passes, 101 refuses, for both capped verbs")
    func bulkBoundary() {
        for verb in ["mark", "delete"] {
            #expect(throws: Never.self) { try enforceBulkCap(ids(100), verb: verb) }
            #expect(throws: AppleError.self) { try enforceBulkCap(ids(101), verb: verb) }
        }
    }

    /// The two oracle ops refuse with DIFFERENT text — `mark_as_read` goes through
    /// `validate_bulk_operation` ("Too many items (N), maximum is M", security.py:111) while
    /// `delete_messages` uses its own inline string (server.py:1722). AGENTS.md prescribes
    /// MCP-diff parity, which compares the error payload, so collapsing them into one message
    /// would be a silent wire divergence.
    @Test("each capped verb reports the oracle's own refusal text, not a shared one")
    func perVerbRefusalText() {
        func message(_ verb: String) -> String {
            do { try enforceBulkCap(ids(101), verb: verb); return "<no throw>" }
            catch { return String(describing: error) }
        }
        #expect(message("delete").contains("Cannot delete 101 messages at once (max: 100)"))
        #expect(message("mark").contains("Too many items (101), maximum is 100"))
        #expect(message("mark") != message("delete"))
    }
}
