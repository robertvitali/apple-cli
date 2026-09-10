import Foundation
import Testing
@testable import NotesKit
@testable import AppleKit

/// `notes recent` — the CLI-only recency surface, driven through the same injected
/// `scriptFactory`/`storeFactory` seam the other read commands use, so no test here reaches
/// Notes.app or `NoteStore.sqlite`.
///
/// The load-bearing claim is that the RANKING is done in Swift over a fully-enumerated scope:
/// the emitted script carries no `where` filter and no `exit repeat` cut, because either one
/// would decide the answer in Notes.app's traversal order, which is not modification order.
@Suite("notes recent")
struct RecentCommandTests {

    /// A search-shaped hit row: title, id, folder, created parts, modified parts.
    /// `modified` is the field under test, so it is the only one that varies per row.
    private func hitRow(_ n: Int, modified: String, folder: String = "Folder") -> String {
        ["apple-cli-test note \(n)", fixtureNoteID(200 + n), folder, fixtureDate, modified]
            .joined(separator: US)
    }

    private func rows(_ pairs: [(Int, String)]) -> String {
        pairs.map { hitRow($0.0, modified: $0.1) }.joined(separator: RS) + RS
    }

    /// Deliberately NOT in date order on the wire — Notes.app enumerates in its own order, and
    /// a passing assertion has to be able to fail if the command simply forwarded that order.
    private var scrambled: String {
        rows([(1, "2026-1-15-9-30-0"),   // oldest
              (2, "2026-3-2-8-0-0"),     // newest
              (3, "2026-2-10-17-45-30")])
    }

    private func ids(_ data: [String: Any]) throws -> [String] {
        let notes = try #require(data["notes"] as? [[String: Any]])
        return notes.map { $0["id"] as? String ?? "" }
    }

    private func drive(_ command: RecentCmd, _ runner: AppleScriptRunning,
                       store: StubNotesStore = .quiet()) throws -> [String: Any] {
        try notesData(try captureNotesEnvelope {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: store) },
                            storeFactory: { store })
        })
    }

    // MARK: registration

    /// The `bats/hosted/notes.bats` "every leaf subcommand --help exits 0" guard — which is what
    /// normally catches a subcommand that is dead because a local `@Option` collides with
    /// `GlobalOptions` — cannot be extended on a branch: `bats_inventory.py` pins every hosted
    /// and local Bats file's sha256 against the BASE manifest, so any edit under `bats/` fails
    /// as "candidate changes trusted hosted file". This stands in for both halves of it here:
    /// `RecentCmd.parse` throughout this suite proves the flags do not collide (a duplicate long
    /// name throws at PARSE time), and this pins that the command is actually reachable.
    @Test("recent is registered on the notes command tree")
    func isRegistered() {
        #expect(NotesCommand.configuration.subcommands.contains { $0 == RecentCmd.self })
        #expect(RecentCmd.configuration.commandName == "recent")
    }

    // MARK: ordering

    @Test("hits are ordered by modification date, newest first — not by the wire order")
    func ordersByModifiedDescending() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        let data = try drive(try RecentCmd.parse([]), runner)

        #expect(try ids(data) == [fixtureNoteID(202), fixtureNoteID(203), fixtureNoteID(201)])
        #expect(data["count"] as? Int == 3)
    }

    @Test("equal modification dates break the tie by id, so the order is total and reproducible")
    func tiesAreBrokenDeterministically() throws {
        // One-second granularity makes ties ordinary (a bulk import, a sync landing). `sorted` is
        // NOT stable, so without a tie-break which note survives --limit would be arbitrary.
        let same = "2026-2-10-17-45-30"
        let wire = rows([(3, same), (1, same), (2, same)])   // ids 203, 201, 202 on the wire
        for _ in 0..<5 {
            let data = try drive(try RecentCmd.parse([]), FakeNotesRunner(results: [wire]))
            #expect(try ids(data) == [fixtureNoteID(201), fixtureNoteID(202), fixtureNoteID(203)])
        }
    }

    @Test("a note whose modification date Notes.app could not report ranks LAST, not first")
    func unreadableModifiedRanksLast() throws {
        // The script's on-error branch emits an EMPTY date field, and parseDate maps that to
        // Date() — "now", the newest value there is. Ranking that hole first would let one
        // unreadable note push every real note out of the default window.
        let wire = [hitRow(1, modified: ""),                    // unreadable
                    hitRow(2, modified: "2026-1-15-9-30-0")]    // real, older than "now"
            .joined(separator: RS) + RS
        let data = try drive(try RecentCmd.parse([]), FakeNotesRunner(results: [wire]))

        #expect(try ids(data) == [fixtureNoteID(202), fixtureNoteID(201)])
        // Control: the same two rows with a READABLE recent date on note 1 put it first, so the
        // assertion above cannot be passing for some unrelated reason.
        let control = [hitRow(1, modified: "2026-3-2-8-0-0"), hitRow(2, modified: "2026-1-15-9-30-0")]
            .joined(separator: RS) + RS
        let controlData = try drive(try RecentCmd.parse([]), FakeNotesRunner(results: [control]))
        #expect(try ids(controlData) == [fixtureNoteID(201), fixtureNoteID(202)])
    }

    @Test("the emitted script enumerates the whole scope: no where-filter, no exit repeat")
    func scriptEnumeratesWholeScope() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        _ = try drive(try RecentCmd.parse(["--limit", "1"]), runner)

        let script = try #require(runner.scripts.first)
        #expect(script.contains("set matchingNotes to notes\n"))
        #expect(!script.contains(" where "), "a filter would decide the answer in Notes.app")
        #expect(!script.contains("exit repeat"), "a script-side cut would drop by traversal order")
        // Reuse of the search mechanism is the -1728 fix: the folder is read off a container
        // bound to its own variable, never `name of container of n`.
        #expect(script.contains("set noteContainer to container of n"))
        #expect(script.contains("set noteFolder to name of noteContainer"))
        #expect(!script.contains("to name of container of n"))
    }

    // MARK: limit

    @Test("--limit truncates AFTER the sort, keeping the newest")
    func limitKeepsTheNewest() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        let data = try drive(try RecentCmd.parse(["--limit", "2"]), runner)

        #expect(try ids(data) == [fixtureNoteID(202), fixtureNoteID(203)])
        #expect(data["count"] as? Int == 2)
        #expect(data["applied_limit"] as? Int == 2)
    }

    @Test("the default cut is 10 and is always disclosed as applied_limit")
    func defaultLimitIsDisclosed() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        let data = try drive(try RecentCmd.parse([]), runner)

        // The literal is what pins it — comparing against the constant the command reads would
        // be tautological.
        #expect(data["applied_limit"] as? Int == 10)
        #expect(NotesLimits.defaultRecentLimit == 10)
        // Fewer hits than the limit: count reports what came back, not the limit.
        #expect(data["count"] as? Int == 3)
    }

    @Test("a limit larger than the result set is honest about both numbers")
    func limitAboveResultCount() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        let data = try drive(try RecentCmd.parse(["--limit", "50"]), runner)

        #expect(data["count"] as? Int == 3)
        #expect(data["applied_limit"] as? Int == 50)
    }

    @Test("a non-positive limit is refused before Notes.app is reached")
    func refusesNonPositiveLimit() throws {
        // `--limit=-1` uses the joined form: ArgumentParser reads a separate `-1` as an option
        // name, so the split form would fail at PARSE time and never reach the guard under test.
        for arg in [["--limit", "0"], ["--limit=-1"]] {
            let runner = ThrowingNotesRunner()
            let command = try RecentCmd.parse(arg)

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                storeFactory: { StubNotesStore.quiet() })
            }

            #expect(failure.code == AppleExit.usage, "exit for \(arg)")
            #expect(failure.error["type"] as? String == "validation_error")
            #expect((failure.error["message"] as? String)?.contains("greater than 0") == true)
            #expect(runner.neverCalled, "validation must precede AppleScript")
        }
    }

    // MARK: scoping

    @Test("--account is bound as argv and drives the tell-block, like list and search")
    func accountPassThrough() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        _ = try drive(try RecentCmd.parse(["--account", "Work Account"]), runner)

        #expect(runner.arguments == [["Work Account"]])
        #expect(try #require(runner.scripts.first).contains("tell account (item 1 of argv)"))
    }

    @Test("--folder scopes the enumeration and travels as argv, nested paths included")
    func folderPassThrough() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        _ = try drive(try RecentCmd.parse(["--folder", "Parent/Child", "--account", "Work Account"]), runner)

        // Folder components first (deepest-first in the expression, original order in argv),
        // then the account the tell-block binds.
        #expect(runner.arguments == [["Parent", "Child", "Work Account"]])
        let script = try #require(runner.scripts.first)
        #expect(script.contains("set matchingNotes to notes of folder (item 2 of argv) of folder (item 1 of argv)"))
        #expect(script.contains("tell account (item 3 of argv)"))
    }

    @Test("no --account falls back to the script's default account")
    func defaultAccountFallback() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        _ = try drive(try RecentCmd.parse([]), runner)

        #expect(runner.arguments == [["iCloud"]])
    }

    @Test("a folder path with no components is a validation error, not a script syntax failure")
    func refusesAFolderPathWithNoComponents() throws {
        // `splitFolderPath("///")` drops every empty component, leaving an EMPTY folder
        // expression — the emitted `notes of ` fails to compile, and the syntax error surfaces
        // as upstream/69 "Internal error. Please report this issue." for plain bad input.
        let runner = ThrowingNotesRunner()
        let command = try RecentCmd.parse(["--folder", "///"])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }

        #expect(failure.code == AppleExit.usage)
        #expect(failure.error["type"] as? String == "validation_error")
        #expect(runner.neverCalled)
    }

    @Test("a hostile --folder value never reaches the script source")
    func folderIsArgvOnly() throws {
        let marker = "RECENTFOLDERMARKER"
        let runner = FakeNotesRunner(results: [scrambled])
        _ = try drive(try RecentCmd.parse(["--folder", hostilePayload(marker)]), runner)

        expectArgvOnly(runner, marker, "notes recent --folder")
    }

    // MARK: envelope

    @Test("the hit shape is search's NoteSummary verbatim, placeholders included")
    func hitShapeMatchesSearch() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        let data = try drive(try RecentCmd.parse([]), runner)
        let hit = try #require((data["notes"] as? [[String: Any]])?.first)

        #expect(Set(hit.keys) == ["id", "title", "content", "tags", "folder", "account",
                                  "created", "modified"])
        #expect(hit["content"] as? String == "")
        #expect((hit["tags"] as? [Any])?.isEmpty == true)
        #expect(hit["folder"] as? String == "Folder")
        #expect(hit["account"] as? String == "iCloud")
        // The oracle's search disclosure fields have no meaning on a fully-enumerated ranking.
        #expect(data["limit_reached"] == nil)
        #expect(data["limit_was_default"] == nil)
    }

    @Test("the sync warning from the injected store is surfaced, and omitted when quiet")
    func surfacesTheSyncWarning() throws {
        let store = StubNotesStore.quiet()
        var status = NotesSyncStatus()
        status.sync_detected = true
        status.pending_upload = 3
        store.sync = status

        let data = try drive(try RecentCmd.parse([]), FakeNotesRunner(results: [scrambled]), store: store)
        #expect((data["sync_warning"] as? String)?.contains("iCloud sync") == true)

        let quiet = try drive(try RecentCmd.parse([]), FakeNotesRunner(results: [scrambled]))
        #expect(quiet["sync_warning"] == nil)
    }

    @Test("an empty scope emits an empty list, not an error")
    func emptyScope() throws {
        let data = try drive(try RecentCmd.parse([]), FakeNotesRunner(results: [""]))

        #expect(data["count"] as? Int == 0)
        #expect((data["notes"] as? [Any])?.isEmpty == true)
        #expect(data["applied_limit"] as? Int == 10)
    }

    // MARK: --text

    @Test("--text renders `modified  title  (folder)`, newest first")
    func textRendering() throws {
        let runner = FakeNotesRunner(results: [scrambled])
        let command = try RecentCmd.parse(["--limit", "2", "--text"])

        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }
        let lines = String(decoding: stdout.data, as: UTF8.self)
            .split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        for line in lines {
            #expect(line.contains("  apple-cli-test note "))
            #expect(line.hasSuffix("  (Folder)"))
        }
        #expect(lines[0].contains("note 2"), "newest first")

        // The stamp, pinned INDEPENDENTLY of parseDate/ISO8601DateFormatter — computing the
        // expectation with the same two calls the production path makes would still match a
        // wrong calendar or time zone. Note 2's wire date is 2026-3-2-8-0-0 local.
        let stamp = try #require(lines[0].split(separator: " ").first).description
        let parsed = try #require(ISO8601DateFormatter().date(from: stamp))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
        #expect((c.year, c.month, c.day, c.hour, c.minute, c.second) == (2026, 3, 2, 8, 0, 0))
    }

    @Test("--text on an empty scope says so")
    func textRenderingEmpty() throws {
        let command = try RecentCmd.parse(["--text"])
        let (streams, stdout) = notesStreams()
        try Output.withStreams(streams) {
            try command.run(scriptFactory: { NotesScript(runner: FakeNotesRunner(results: [""]),
                                                         store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }
        #expect(String(decoding: stdout.data, as: UTF8.self).contains("No notes found."))
    }
}
