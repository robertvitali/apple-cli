import Foundation
import Testing
@testable import NotesKit
@testable import AppleKit

/// `search-notes` limit semantics against apple-notes-mcp 2.6.12 (NOTES-M7 + NOTES-L2).
///
/// Two oracle layers, and they disagree about non-positive limits — which is the whole of L2.
/// The JSON SCHEMA is the outer gate: `"limit": {"exclusiveMinimum": 0, "type": "integer"}`, read
/// from the live tool definition, so the MCP refuses `limit: 0` before any handler runs. The
/// INNER `resolveSearchLimit` also guards `limit > 0`, but that path is unreachable through MCP.
/// Porting the schema gate is what makes `--limit 0` a validation error here; porting only the
/// inner function would have made it silently mean "50", which is NOT what a caller sees.
@Suite("search limit parity")
struct SearchLimitParityTests {

    @Test("absent limit resolves to the oracle's DEFAULT_SEARCH_LIMIT, not unbounded")
    func defaultLimit() {
        let (effective, wasDefault) = SearchLimit.resolve(nil)
        // Measured before the fix: a bare `notes search e` on one account returned 245 here
        // and 50 from the oracle. The literal 50 is what pins it — comparing against
        // NotesLimits.defaultSearchLimit would be tautological, since resolve() returns exactly
        // that constant and no mutation of it could fail the check.
        #expect(effective == 50)
        #expect(wasDefault == true)
    }

    @Test("an explicit limit is used verbatim and is not flagged as default")
    func explicitLimit() {
        for n in [1, 5, 49, 50, 500] {
            let (effective, wasDefault) = SearchLimit.resolve(n)
            #expect(effective == n)
            #expect(wasDefault == false)
        }
    }

    @Test("non-positive limits are refused, mirroring the schema's exclusiveMinimum: 0")
    func nonPositiveRefused() throws {
        #expect(throws: (any Error).self) { try validateSearchLimit(0) }
        #expect(throws: (any Error).self) { try validateSearchLimit(-1) }
        #expect(throws: (any Error).self) { try validateSearchLimit(Int.min) }
        // Control: valid values must NOT throw, or "reject everything" would pass the above.
        try validateSearchLimit(nil)
        try validateSearchLimit(1)
        try validateSearchLimit(50)
    }

    @Test("the refusal is a validation error with exit 64, not a not-found or an upstream error")
    func refusalShape() {
        do {
            try validateSearchLimit(0)
            Issue.record("expected a throw")
        } catch let e as AppleError {
            #expect(e.type == AppleErrorType.validation)
            #expect(e.exitCode == AppleExit.usage)
        } catch { Issue.record("wrong error type: \(error)") }
    }

    /// `--all` is a CLI-only superset restoring the total query the 50-default would otherwise
    /// retire with no replacement. Without it the caller learns results are incomplete
    /// (limit_reached) and has no operation available to complete them.
    @Test("--all yields an unbounded search and is never flagged as default")
    func allFlagIsUnbounded() {
        let (effective, wasDefault) = SearchLimit.resolve(nil, all: true)
        #expect(effective == nil, "nil means no limitCheck is emitted at all")
        #expect(wasDefault == false)
        // Unbounded can never be 'limit reached' — there is no limit to reach.
        #expect(SearchLimit.truncationNote(count: 9999, effective: nil, wasDefault: false) == nil)
        // `all` wins over an explicit limit. Unreachable via the CLI (the two are mutually
        // exclusive there), so the resolver is the only place this can be pinned.
        #expect(SearchLimit.resolve(5, all: true).effective == nil)
    }

    /// Golden-envelope pin for the three new contract fields, moved here from bats: the CLI-tier
    /// version needed a real `notes search` and so depended on Notes Automation, breaking that
    /// file's no-Automation contract. Encoding the model directly is TCC-free and deterministic —
    /// and it catches the `truncated` → `limit_reached` rename, which docs had missed.
    @Test("the limit disclosure fields encode under their contract names")
    func envelopeFieldNames() throws {
        let json = try String(data: JSONEncoder().encode(
            NoteList(notes: [], count: 0, sync_warning: nil,
                     applied_limit: 50, limit_reached: false, limit_was_default: true)), encoding: .utf8)!
        #expect(json.contains("\"applied_limit\":50"))
        #expect(json.contains("\"limit_reached\":false"))
        #expect(json.contains("\"limit_was_default\":true"))
        #expect(!json.contains("truncated"), "the pre-rename name must never reappear on the wire")
        // Unbounded (--all): the limit keys are OMITTED, not emitted as null.
        let unbounded = try String(data: JSONEncoder().encode(
            NoteList(notes: [], count: 0, sync_warning: nil)), encoding: .utf8)!
        #expect(!unbounded.contains("applied_limit"))
        #expect(!unbounded.contains("null"))
    }

    @Test("the truncation note fires exactly when count >= limit, and marks the default case")
    func truncationNote() {
        // Oracle: `resultCount >= effectiveLimit`. The boundary is >=, not >.
        #expect(SearchLimit.truncationNote(count: 50, effective: 50, wasDefault: true) != nil)
        #expect(SearchLimit.truncationNote(count: 49, effective: 50, wasDefault: true) == nil)
        #expect(SearchLimit.truncationNote(count: 51, effective: 50, wasDefault: false) != nil)
        #expect(SearchLimit.truncationNote(count: 0, effective: 50, wasDefault: true) == nil)
        // "(default limit)" appears only when the limit was defaulted — the oracle's own
        // `wasDefault ? " (default limit)" : ""`.
        #expect(SearchLimit.truncationNote(count: 50, effective: 50, wasDefault: true)!
                    .contains("(default limit)"))
        #expect(!SearchLimit.truncationNote(count: 5, effective: 5, wasDefault: false)!
                    .contains("(default limit)"))
        // And it names the effective limit, so a caller can act on it.
        #expect(SearchLimit.truncationNote(count: 7, effective: 7, wasDefault: false)!
                    .contains("first 7"))
    }
}
