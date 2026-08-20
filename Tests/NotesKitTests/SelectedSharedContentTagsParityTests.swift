import Foundation
import Testing
@testable import NotesKit
@testable import AppleKit

/// NOTES-M1 follow-up: `search`'s content/tags fix (`ScriptGenTests.swift`) extended to the two
/// sibling endpoints with the identical oracle characteristic — `get-selected-notes` and
/// `list-shared-notes` also hardcode `content: ""` / `tags: []` on every item, never fetched (see
/// the `SelectedNote`/`SharedNote` doc comments in `NotesModels.swift` for the exact
/// `build/index.js` line citations). Same two-tier pin style as search: a parse-level test proving
/// the placeholders survive the AppleScript-row round trip, and a JSON-envelope pin guarding the
/// wire key names/values against a future accidental `Optional`-ification.
@Suite("selected/shared notes — content/tags placeholders (NOTES-M1 follow-up)")
struct SelectedSharedContentTagsParityTests {

    // MARK: get-selected-notes (single AppleScript call — one FakeRunner value suffices)

    @Test("getSelectedNotes emits the oracle's literal content/tags placeholders, real fields intact")
    func selectedNotesContentTagsPlaceholders() throws {
        let us = NotesScript.US
        let row = ["x-coredata://ABC/p42", "Selected note", "2024-3-9-14-30-5", "2025-12-31-23-59-59",
                   "false", "false", "Work", "iCloud"].joined(separator: us)
        let fake = FakeRunner(failCount: 0, failureStderr: "", successValue: row)
        let notes = try NotesScript(runner: fake).getSelectedNotes()
        let n = try #require(notes.first)
        #expect(n.content == "")
        #expect(n.tags == [])
        // Control: the real fields the endpoint already carried are untouched by this change.
        #expect(n.id == "x-coredata://ABC/p42")
        #expect(n.title == "Selected note")
        #expect(n.folder == "Work")
        #expect(n.account == "iCloud")
        #expect(n.shared == false)
        #expect(n.password_protected == false)
    }

    @Test("the selected-note envelope encodes the oracle's content/tags keys verbatim")
    func selectedNoteEnvelopeContentTagsKeys() throws {
        let hit = SelectedNote(id: "x-coredata://ABC/p42", title: "Selected note", content: "", tags: [],
                               created: Date(), modified: Date(), shared: false, password_protected: false,
                               folder: "Work", account: "iCloud")
        let json = try String(data: JSONEncoder().encode(hit), encoding: .utf8)!
        #expect(json.contains("\"content\":\"\""))
        #expect(json.contains("\"tags\":[]"))
    }

    // MARK: list-shared-notes (TWO AppleScript calls: listAccounts() then a per-account scan —
    // QueuedRunner returns a different canned row for each, in call order)

    @Test("listSharedNotes emits the oracle's literal content/tags placeholders, real fields intact")
    func sharedNotesContentTagsPlaceholders() throws {
        let us = NotesScript.US
        // Call 1: listAccounts() — {id, name, upgraded, defaultFolderId, defaultFolderName}.
        let accountRow = ["account-1", "iCloud", "true", "folder-1", "Notes"].joined(separator: us)
        // Call 2: the per-account shared-notes scan — {title, id, created, modified, shared, passwordProtected}.
        let sharedRow = ["Shared note", "x-coredata://ABC/p99", "2024-3-9-14-30-5", "2025-12-31-23-59-59",
                         "true", "false"].joined(separator: us)
        let fake = QueuedRunner(values: [accountRow, sharedRow])
        let notes = try NotesScript(runner: fake).listSharedNotes()
        let n = try #require(notes.first)
        #expect(n.content == "")
        #expect(n.tags == [])
        // Control: the real fields the endpoint already carried are untouched by this change.
        #expect(n.id == "x-coredata://ABC/p99")
        #expect(n.title == "Shared note")
        #expect(n.account == "iCloud")
        #expect(n.shared == true)
        #expect(n.password_protected == false)
    }

    @Test("the shared-note envelope encodes the oracle's content/tags keys verbatim, and omits folder")
    func sharedNoteEnvelopeContentTagsKeys() throws {
        let hit = SharedNote(id: "x-coredata://ABC/p99", title: "Shared note", content: "", tags: [],
                             account: "iCloud", created: Date(), modified: Date(), shared: true,
                             password_protected: false)
        let json = try String(data: JSONEncoder().encode(hit), encoding: .utf8)!
        #expect(json.contains("\"content\":\"\""))
        #expect(json.contains("\"tags\":[]"))
        // The oracle's shared-notes loop never reads a note's container, so `folder` genuinely
        // does not exist on this endpoint's wire shape (see the SharedNote doc comment) — this is
        // NOT a gap NOTES-M1 introduced or should fix.
        #expect(!json.contains("\"folder\""))
    }
}

/// Returns a QUEUE of canned outputs, one per call, in order — needed because `listSharedNotes()`
/// makes two DIFFERENT AppleScript calls through the same runner (an account-list call, then a
/// per-account shared-notes scan), unlike every other fixture in this test target which needs only
/// one canned value. Throws if exhausted, so a call-count regression fails loudly rather than
/// silently reusing a stale value.
final class QueuedRunner: AppleScriptRunning {
    private var values: [String]
    private(set) var invocationCount = 0
    init(values: [String]) { self.values = values }
    func run(_ script: String, arguments: [String]) throws -> String {
        invocationCount += 1
        guard !values.isEmpty else {
            throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "QueuedRunner exhausted")
        }
        return values.removeFirst()
    }
}
