import Foundation
import Testing
@testable import NotesKit
@testable import AppleKit

/// `get-note-link` (NOTES-H1) and the not-found classification it depends on (NOTES-M3),
/// against apple-notes-mcp 2.6.12.
@Suite("get-note-link parity")
struct NoteLinkParityTests {

    /// Verbatim from the oracle (build/index.js, the `get-note-link` handler). Reproduced here as
    /// a literal so a reword on either side fails loudly rather than drifting silently.
    static let oracleLinkFailure =
        "Failed to get note link for \"MyNote\". The Notes database may not be accessible — grant "
        + "Full Disk Access to the app that launches the server, fully quit and relaunch, then run "
        + "the doctor tool. See: https://github.com/sweetrb/apple-notes-mcp/blob/main/docs/FULL-DISK-ACCESS.md. "
        + "(On macOS 12–15 this also falls back to the AppleScript note link property.)"

    @Test("the link-failure message matches the oracle verbatim, including the macOS 12-15 note")
    func linkFailureMessage() {
        #expect(GetNoteLinkCmd.linkFailure("MyNote") == Self.oracleLinkFailure)
    }

    /// The payload asymmetry is what the CHANGELOG, port spec and queue row all LEAD with, and
    /// until now nothing pinned it: it rests entirely on Swift synthesizing `encodeIfPresent` for
    /// Optionals. A hand-written `encode(to:)` on `NoteLinkResult` would emit `"id": null` and
    /// break parity with every test still green. This round-trips the actual encoder.
    @Test("id path emits an id key; title path omits it entirely, not null")
    func payloadAsymmetryIsEncoded() throws {
        let enc = JSONEncoder()
        let idPath = try String(data: enc.encode(
            NoteLinkResult(id: "x-coredata://A/ICNote/p1", title: "T", url: "notes://u")), encoding: .utf8)!
        let titlePath = try String(data: enc.encode(
            NoteLinkResult(id: nil, title: "T", url: "notes://u")), encoding: .utf8)!
        #expect(idPath.contains("\"id\""), "id path must carry id")
        #expect(!titlePath.contains("\"id\""), "title path must OMIT id — the oracle emits no such key")
        #expect(!titlePath.contains("null"), "omitted, never null")
        // Control: both paths still carry the keys the oracle always emits.
        for p in [idPath, titlePath] {
            #expect(p.contains("\"title\"") && p.contains("\"url\""))
        }
    }

    /// NOTE: `primaryKey` is a PRE-EXISTING shared helper (used by get-metadata), so this is a
    /// regression pin on the query's join key, NOT coverage of NOTES-H1 — it passes with
    /// `noteLink`, `resolveLink` and the whole command deleted. Said plainly so the next reader
    /// does not mistake it for feature coverage.
    @Test("primaryKey extracts the Z_PK the SQLite link query joins on")
    func primaryKeyExtraction() {
        // The oracle's getNoteLinkFromDB matches /\/p(\d+)$/ and bails to AppleScript otherwise.
        #expect(NotesStore.primaryKey(from: "x-coredata://ABC-123/ICNote/p3089") == 3089)
        #expect(NotesStore.primaryKey(from: "x-coredata://ABC/ICNote/p1") == 1)
        #expect(NotesStore.primaryKey(from: "x-coredata://ABC/ICNote/p3089/extra") == nil)
        #expect(NotesStore.primaryKey(from: "not-an-id") == nil)
        #expect(NotesStore.primaryKey(from: "x-coredata://ABC/ICNote/pXYZ") == nil)
    }
}

/// NOTES-M3. AppleScript reports a missing specifier with a CURLY apostrophe, so the mapper's
/// ASCII `can't` test never fired and every AppleScript-backed lookup returned upstream_error/69
/// where the oracle returns not_found. The string below is the LIVE stderr captured from
/// `osascript -e 'tell application "Notes" to return name of note id "…p999999"'` on this machine
/// — U+2019, error -1728 — not a hand-typed approximation.
@Suite("AppleScript not-found classification")
struct NotesErrorClassificationTests {

    static let liveMissingSpecifierStderr =
        "35:39: execution error: Notes got an error: Can\u{2019}t get note id " +
        "\"x-coredata://ABC/ICNote/p999999\". (-1728)"

    @Test("a curly-apostrophe missing-specifier error classifies as not_found, not upstream")
    func curlyApostropheIsNotFound() {
        let mapped = NotesScript.mapError(.scriptFailed(status: 1, stderr: Self.liveMissingSpecifierStderr))
        #expect(mapped.type == AppleErrorType.notFound)
        #expect(mapped.exitCode == AppleExit.notFound)
    }

    /// The two signals (normalised apostrophe, and the -1728 code) are deliberately redundant on
    /// the common input, so neither alone is pinned by `liveMissingSpecifierStderr`. This case
    /// carries the curly apostrophe WITHOUT -1728, so it goes red if the normalisation is dropped
    /// — otherwise "drop the apostrophe fix" is a mutation no test can see.
    @Test("a curly-apostrophe error with no -1728 code still classifies as not_found")
    func curlyApostropheWithoutErrorCode() {
        let stderr = "execution error: Notes got an error: Can\u{2019}t get folder \"Nope\"."
        #expect(NotesScript.mapError(.scriptFailed(status: 1, stderr: stderr)).type
                == AppleErrorType.notFound)
    }

    @Test("the ASCII form still classifies, so the fix is additive not a swap")
    func asciiApostropheStillWorks() {
        let ascii = "execution error: Notes got an error: Can't get note id \"x\". (-1728)"
        #expect(NotesScript.mapError(.scriptFailed(status: 1, stderr: ascii)).type == AppleErrorType.notFound)
    }

    @Test("unrelated failures are NOT swallowed as not_found")
    func unrelatedStaysUpstream() {
        // Control: without this, mapping everything to not_found would pass the two tests above.
        let other = "execution error: Notes got an error: AppleEvent timed out. (-1712)"
        #expect(NotesScript.mapError(.scriptFailed(status: 1, stderr: other)).type != AppleErrorType.notFound)
        let generic = "execution error: something else entirely happened"
        #expect(NotesScript.mapError(.scriptFailed(status: 1, stderr: generic)).type != AppleErrorType.notFound)
    }
}
