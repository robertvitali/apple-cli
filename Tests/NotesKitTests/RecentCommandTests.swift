import Foundation
import Testing
@testable import NotesKit
@testable import AppleKit

/// `notes recent` — the CLI-only recency surface, driven through the same injected
/// `scriptFactory`/`storeFactory` seam the other read commands use, so no test here reaches
/// Notes.app or `NoteStore.sqlite`.
///
/// Two claims carry this command, and both are asserted on the EMITTED SCRIPTS rather than only
/// on the payload:
///
///   * the ranking sees the whole scope — pass 1 emits no `where` filter and no `exit repeat`,
///     because either would decide the answer in Notes.app's traversal order, which is not
///     modification order;
///   * the ranking is CHEAP — pass 1 reads two bulk properties, and the five-field per-hit reads
///     happen in pass 2 for the survivors only.
@Suite("notes recent")
struct RecentCommandTests {

    /// One synthetic note: its number (which fixes title and id) and the modification-date parts
    /// pass 1 reports for it.
    private struct Fixture {
        let n: Int
        let modified: String
        init(_ n: Int, _ modified: String) { self.n = n; self.modified = modified }
    }

    private func noteID(_ n: Int) -> String { fixtureNoteID(200 + n) }

    /// A search-shaped pass-2 row: title, id, folder, created parts, modified parts.
    private func hitRow(_ n: Int, modified: String, folder: String = "Folder") -> String {
        ["apple-cli-test note \(n)", noteID(n), folder, fixtureDate, modified]
            .joined(separator: US)
    }

    /// A runner that answers BOTH passes from one set of notes.
    ///
    /// Pass 2 deliberately replies in REVERSE argv order and pass 1 in a scrambled order, so a
    /// command that simply forwarded either wire order would fail every ordering assertion here.
    /// `missing` drops ids from the pass-2 reply, standing in for a note deleted between passes.
    private func twoPassRunner(_ notes: [Fixture], missing: Set<Int> = []) -> FakeNotesRunner {
        let runner = FakeNotesRunner()
        let byId = Dictionary(uniqueKeysWithValues: notes.map { (noteID($0.n), $0) })
        runner.handler = { script, args in
            if script.contains("set noteIds to id of every") {
                return notes.map { [self.noteID($0.n), $0.modified].joined(separator: US) }
                    .joined(separator: RS) + RS
            }
            if script.contains("set resolvedNotes to {}") {
                return args.reversed().compactMap { id -> String? in
                    guard let f = byId[id], !missing.contains(f.n) else { return nil }
                    return self.hitRow(f.n, modified: f.modified)
                }.joined(separator: RS) + RS
            }
            return nil
        }
        return runner
    }

    /// Three notes whose wire order is NOT their date order: 2 is newest, then 3, then 1.
    private var scrambled: [Fixture] {
        [Fixture(1, "2026-1-15-9-30-0"), Fixture(2, "2026-3-2-8-0-0"), Fixture(3, "2026-2-10-17-45-30")]
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

    @Test("hits are ordered by modification date, newest first — not by either wire order")
    func ordersByModifiedDescending() throws {
        let runner = twoPassRunner(scrambled)
        let data = try drive(try RecentCmd.parse([]), runner)

        #expect(try ids(data) == [noteID(2), noteID(3), noteID(1)])
        #expect(data["count"] as? Int == 3)
    }

    @Test("equal modification dates break the tie by id, so the order is total and reproducible")
    func tiesAreBrokenDeterministically() throws {
        // One-second granularity makes ties ordinary (a bulk import, a sync landing). Without a
        // tie-break, which note survives --limit would be decided by pass 1's input order, which
        // is Notes.app's own enumeration order — the very thing the ranking exists to replace.
        let same = "2026-2-10-17-45-30"
        let notes = [Fixture(3, same), Fixture(1, same), Fixture(2, same)]
        for _ in 0..<5 {
            let data = try drive(try RecentCmd.parse([]), twoPassRunner(notes))
            #expect(try ids(data) == [noteID(1), noteID(2), noteID(3)])
        }
    }

    @Test("a note whose modification date Notes.app could not report ranks LAST, not first")
    func unreadableModifiedRanksLast() throws {
        // Pass 1's `on error` branch emits an EMPTY date field, and `parseDate` would map that to
        // Date() — "now", the newest value there is. Ranking that hole first would let one
        // unreadable note push every real note out of the default window.
        let data = try drive(try RecentCmd.parse([]),
                             twoPassRunner([Fixture(1, ""), Fixture(2, "2026-1-15-9-30-0")]))
        #expect(try ids(data) == [noteID(2), noteID(1)])

        // Control: the same two notes with a READABLE recent date on note 1 put it first, so the
        // assertion above cannot be passing for some unrelated reason.
        let control = try drive(try RecentCmd.parse([]),
                                twoPassRunner([Fixture(1, "2026-3-2-8-0-0"),
                                               Fixture(2, "2026-1-15-9-30-0")]))
        #expect(try ids(control) == [noteID(1), noteID(2)])
    }

    @Test("a date that is present but unparseable is unreadable too, not a silent now")
    func unparseableModifiedIsAlsoUnreadable() throws {
        // The readability decision comes from the same FALLIBLE parse everywhere, so a garbled
        // value is treated exactly like the empty one rather than falling through to `Date()`.
        #expect(NotesScript.parseDateIfReadable("2026-13-99-x-y-z") == nil)
        #expect(NotesScript.parseDateIfReadable("") == nil)
        #expect(NotesScript.parseDateIfReadable("2026-3-2-8-0-0") != nil)

        let data = try drive(try RecentCmd.parse([]),
                             twoPassRunner([Fixture(1, "not-a-date"),
                                            Fixture(2, "2026-1-15-9-30-0")]))
        #expect(try ids(data) == [noteID(2), noteID(1)])
    }

    @Test("the rank decides the output order, even when pass 2 answers in another order")
    func rankSurvivesTheFetchOrder() throws {
        // `twoPassRunner` replies to pass 2 in REVERSE argv order on every test in this suite;
        // this one says so out loud, because it is the property that makes the re-sort load-bearing.
        let runner = twoPassRunner(scrambled)
        let data = try drive(try RecentCmd.parse([]), runner)
        let pass2Args = try #require(runner.arguments.last)

        #expect(pass2Args == [noteID(2), noteID(3), noteID(1)], "pass 2 is asked in rank order")
        #expect(try ids(data) == pass2Args, "and answers out of order without changing the output")
    }

    @Test("a note deleted between the two passes drops out instead of failing the fetch")
    func aNoteLostBetweenPassesIsDropped() throws {
        let data = try drive(try RecentCmd.parse([]), twoPassRunner(scrambled, missing: [3]))

        #expect(try ids(data) == [noteID(2), noteID(1)])
        #expect(data["count"] as? Int == 2)
    }

    // MARK: truncation disclosure

    /// `count` alone cannot be read as "the scope was exhausted", which is why `limit_reached`
    /// is emitted rather than left to the caller to infer. Pass 2 drops a winner it cannot read
    /// back and nothing backfills from the next-ranked candidate, so a truncated result can
    /// report a `count` BELOW `applied_limit` while more notes are still in scope — the exact
    /// shape an agent paging by raising `--limit` would stop on.
    @Test("limit_reached is true when the cut bit, even though count came back under the limit")
    func limitReachedSurvivesADroppedWinner() throws {
        let notes = [Fixture(1, "2026-3-2-8-0-0"), Fixture(2, "2026-2-10-17-45-30"),
                     Fixture(3, "2026-1-15-9-30-0")]
        // Two winners out of three candidates, and one of those two never comes back.
        let data = try drive(try RecentCmd.parse(["--limit", "2"]),
                             twoPassRunner(notes, missing: [2]))

        #expect(data["limit_reached"] as? Bool == true, "three candidates, limit two: the cut bit")
        #expect(data["count"] as? Int == 1)
        #expect(data["applied_limit"] as? Int == 2)
        // The pairing is the whole point: count < applied_limit while the scope is NOT exhausted.
        #expect((data["count"] as? Int).map { $0 < (data["applied_limit"] as? Int ?? 0) } == true)
    }

    @Test("limit_reached is false when the whole scope fitted inside the limit")
    func limitReachedFalseWhenScopeFits() throws {
        let data = try drive(try RecentCmd.parse(["--limit", "10"]), twoPassRunner(scrambled))

        #expect(data["limit_reached"] as? Bool == false)
        #expect(data["count"] as? Int == 3)
        // Exactly-at-the-limit is the boundary: three candidates, limit three, nothing was cut.
        let exact = try drive(try RecentCmd.parse(["--limit", "3"]), twoPassRunner(scrambled))
        #expect(exact["limit_reached"] as? Bool == false)
    }

    // MARK: Recently Deleted

    /// `id of every note` enumerates the trash, and deleting a note bumps its modification date,
    /// so a note in Recently Deleted can lead the ranking. That is disclosed rather than
    /// filtered (the folder's AppleScript name is localized and Notes exposes no "deleted"
    /// property, so exclusion needs a design pass), and the disclosure says a hit's `folder`
    /// identifies it — so the folder has to survive the pipeline verbatim.
    @Test("a note in Recently Deleted passes through unchanged, identifiable by its folder")
    func trashedNotesPassThroughIdentifiably() throws {
        let trash = "Recently Deleted"
        let runner = FakeNotesRunner()
        runner.handler = { script, args in
            if script.contains("set noteIds to id of every") {
                return [self.noteID(1), "2026-3-2-8-0-0"].joined(separator: US) + RS
                    + [self.noteID(2), "2026-1-15-9-30-0"].joined(separator: US) + RS
            }
            if script.contains("set resolvedNotes to {}") {
                return [self.hitRow(1, modified: "2026-3-2-8-0-0", folder: trash),
                        self.hitRow(2, modified: "2026-1-15-9-30-0")].joined(separator: RS) + RS
            }
            return nil
        }

        let data = try drive(try RecentCmd.parse([]), runner)
        let hits = try #require(data["notes"] as? [[String: Any]])

        // Ranked first, because deleting it bumped its modification date — and NOT filtered.
        #expect(hits.first?["id"] as? String == noteID(1))
        #expect(hits.first?["folder"] as? String == trash, "the folder is what identifies it")
        #expect(hits.count == 2)
        #expect(hits.last?["folder"] as? String == "Folder")
    }

    // MARK: emitted scripts

    @Test("pass 1 reads two bulk properties over the whole scope — no filter, no cut, no per-note event")
    func passOneIsTwoBulkReads() throws {
        let runner = twoPassRunner(scrambled)
        _ = try drive(try RecentCmd.parse(["--limit", "1"]), runner)

        let pass1 = try #require(runner.scripts.first)
        // The whole point of the split: the scope costs two Apple events regardless of its size.
        #expect(pass1.contains("set noteIds to id of every note\n"))
        #expect(pass1.contains("set noteMods to modification date of every note\n"))
        #expect(!pass1.contains(" where "), "a filter would decide the answer in Notes.app")
        #expect(!pass1.contains("exit repeat"), "a script-side cut would drop by traversal order")
        // The expensive per-hit reads must NOT be in pass 1 — that is the regression this split
        // exists to prevent, and `--limit 1` above would not have made the old shape cheaper.
        #expect(!pass1.contains("container of n"))
        #expect(!pass1.contains("creation date of n"))
        // Position-matched lists: a length mismatch must fail, never silently mis-attribute.
        #expect(pass1.contains("if (count of noteMods) is not n then error"))
    }

    @Test("pass 2 reuses the search per-hit mechanism, and resolves each id defensively")
    func passTwoReusesTheSearchBody() throws {
        let runner = twoPassRunner(scrambled)
        _ = try drive(try RecentCmd.parse([]), runner)

        #expect(runner.invocationCount == 2)
        let pass2 = try #require(runner.scripts.last)
        // Reuse of `searchBody` is the -1728 fix: the folder is read off a container bound to
        // its own variable, never `name of container of n`.
        #expect(pass2.contains("set noteContainer to container of n"))
        #expect(pass2.contains("set noteFolder to name of noteContainer"))
        #expect(!pass2.contains("to name of container of n"))
        // Each id resolves inside its own try, so one stale id cannot take the fetch down.
        #expect(pass2.contains("set resolvedNotes to {}"))
        #expect(pass2.contains("set end of resolvedNotes to note id (item k of argv)"))
        #expect(pass2.contains("repeat with k from 1 to 3"))
        // Application scope, like getNoteById — the ids already carry their account.
        #expect(!pass2.contains("tell account"))
    }

    // MARK: failure paths

    /// The mismatch guard exists to make ONE failure loud. Before `mapError` learned to pass an
    /// `apple-cli:`-prefixed message through, it matched no branch and fell to the terminal
    /// "Notes.app returned an error." — the least informative string the domain emits, on the
    /// one error the script goes out of its way to raise.
    @Test("a script's own apple-cli: diagnostic reaches the caller verbatim")
    func ownDiagnosticSurvivesErrorMapping() throws {
        let runner = FakeNotesRunner()
        runner.handler = { _, _ in
            throw AppleScriptRunner.RunError.scriptFailed(
                status: 1,
                stderr: "execution error: apple-cli: Notes.app returned mismatched id and date lists (1)")
        }
        let command = try RecentCmd.parse([])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }

        let message = try #require(failure.error["message"] as? String)
        #expect(message.contains("mismatched id and date lists"))
        #expect(!message.contains("Notes.app returned an error."), "the generic terminal branch")
        #expect(!message.contains("apple-cli:"), "the prefix is routing, not caller-facing text")
        #expect(failure.error["type"] as? String == "upstream_error")
    }

    /// The pass-2 preamble tolerates a vanished note and NOTHING else: a bare `try … end try`
    /// would also swallow a timeout or a lost connection mid-resolution and return `ok: true`
    /// with notes silently missing.
    @Test("pass 2 re-raises anything that is not a not-found, and says so in the script")
    func passTwoFailureSurfaces() throws {
        let runner = FakeNotesRunner()
        runner.handler = { script, _ in

            if script.contains("set noteIds to id of every") {
                return [self.noteID(1), "2026-3-2-8-0-0"].joined(separator: US) + RS
            }
            throw AppleScriptRunner.RunError.scriptFailed(
                status: 1, stderr: "execution error: Notes got an error: AppleEvent timed out. (-1712)")
        }
        let command = try RecentCmd.parse([])

        let failure = try captureNotesFailure {
            try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                            storeFactory: { StubNotesStore.quiet() })
        }

        #expect(failure.code == AppleExit.upstream)
        #expect((failure.error["message"] as? String)?.contains("timed out") == true,
                "a pass-2 failure must surface, not shorten the result to ok:true")

        // And the narrowing is in the emitted script, which is where it actually has to hold:
        // only -1728 is swallowed, everything else re-raised.
        let details = FakeNotesRunner()
        details.handler = { script, _ in
            script.contains("set noteIds to id of every")
                ? [self.noteID(1), "2026-3-2-8-0-0"].joined(separator: US) + RS
                : self.hitRow(1, modified: "2026-3-2-8-0-0") + RS
        }
        _ = try drive(try RecentCmd.parse([]), details)
        let pass2 = try #require(details.scripts.last)
        #expect(pass2.contains("on error errMsg number errNum"))
        #expect(pass2.contains("if errNum is not -1728 then error errMsg number errNum"))
    }

    @Test("pass 2 is skipped entirely when nothing survives the cut")
    func passTwoIsSkippedOnAnEmptyScope() throws {
        let runner = FakeNotesRunner(results: [""])
        let data = try drive(try RecentCmd.parse([]), runner)

        #expect(runner.invocationCount == 1, "no ids means no reason to ask Notes.app again")
        #expect(data["count"] as? Int == 0)
        #expect((data["notes"] as? [Any])?.isEmpty == true)
        #expect(data["applied_limit"] as? Int == 10)
    }

    // MARK: limit

    @Test("--limit truncates AFTER the sort, keeping the newest, and pass 2 fetches only those")
    func limitKeepsTheNewest() throws {
        let runner = twoPassRunner(scrambled)
        let data = try drive(try RecentCmd.parse(["--limit", "2"]), runner)

        #expect(try ids(data) == [noteID(2), noteID(3)])
        #expect(data["count"] as? Int == 2)
        #expect(data["applied_limit"] as? Int == 2)
        // The cost claim: pass 2 is asked for the survivors, not for the scope.
        #expect(runner.arguments.last?.count == 2)
    }

    @Test("the default cut is 10 and is always disclosed as applied_limit")
    func defaultLimitIsDisclosed() throws {
        let data = try drive(try RecentCmd.parse([]), twoPassRunner(scrambled))

        // The literal is what pins it — comparing against the constant the command reads would
        // be tautological.
        #expect(data["applied_limit"] as? Int == 10)
        #expect(NotesLimits.defaultRecentLimit == 10)
        // Fewer hits than the limit: count reports what came back, not the limit.
        #expect(data["count"] as? Int == 3)
    }

    @Test("a limit larger than the result set is honest about both numbers")
    func limitAboveResultCount() throws {
        let data = try drive(try RecentCmd.parse(["--limit", "50"]), twoPassRunner(scrambled))

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

    @Test("--account is bound as argv and drives pass 1's tell-block, like list and search")
    func accountPassThrough() throws {
        let runner = twoPassRunner(scrambled)
        _ = try drive(try RecentCmd.parse(["--account", "Work Account"]), runner)

        #expect(runner.arguments.first == ["Work Account"])
        #expect(try #require(runner.scripts.first).contains("tell account (item 1 of argv)"))
    }

    @Test("--folder scopes pass 1 and travels as argv, nested paths included")
    func folderPassThrough() throws {
        let runner = twoPassRunner(scrambled)
        _ = try drive(try RecentCmd.parse(["--folder", "Parent/Child", "--account", "Work Account"]),
                      runner)

        // Folder components first (deepest-first in the expression, original order in argv),
        // then the account the tell-block binds.
        #expect(runner.arguments.first == ["Parent", "Child", "Work Account"])
        let pass1 = try #require(runner.scripts.first)
        #expect(pass1.contains("id of every note of folder (item 2 of argv) of folder (item 1 of argv)"))
        #expect(pass1.contains("tell account (item 3 of argv)"))
        // Pass 2 addresses by id, so the scope does not travel a second time.
        #expect(runner.arguments.last?.allSatisfy { $0.hasPrefix("x-coredata://") } == true)
    }

    @Test("no --account falls back to the script's default account")
    func defaultAccountFallback() throws {
        let runner = twoPassRunner(scrambled)
        _ = try drive(try RecentCmd.parse([]), runner)

        #expect(runner.arguments.first == ["iCloud"])
    }

    @Test("a folder naming no path component is a validation error — empty and separators alike")
    func refusesAFolderPathWithNoComponents() throws {
        // `splitFolderPath` drops every empty component, so both spellings name NO folder and
        // the emitted dangling `of` would fail to compile, surfacing as upstream/69 "Internal
        // error. Please report this issue." for plain bad input.
        //
        // `""` is the one that matters in practice: the `!folder.isEmpty` shape `search` and
        // `list` still use lets it fall through and enumerate the WHOLE ACCOUNT, so a caller
        // interpolating an unset variable silently widens the read instead of being refused.
        for value in ["", "///"] {
            let runner = ThrowingNotesRunner()
            let command = try RecentCmd.parse(["--folder", value])

            let failure = try captureNotesFailure {
                try command.run(scriptFactory: { NotesScript(runner: runner, store: StubNotesStore.quiet()) },
                                storeFactory: { StubNotesStore.quiet() })
            }

            #expect(failure.code == AppleExit.usage, "exit for --folder \"\(value)\"")
            #expect(failure.error["type"] as? String == "validation_error")
            #expect((failure.error["message"] as? String)?.contains("--folder") == true)
            #expect(runner.neverCalled, "--folder \"\(value)\" must not reach Notes.app")
        }
    }

    @Test("a hostile --folder value never reaches the script source")
    func folderIsArgvOnly() throws {
        let marker = "RECENTFOLDERMARKER"
        let runner = FakeNotesRunner(results: [""]) // empty scope: pass 1 only
        _ = try drive(try RecentCmd.parse(["--folder", hostilePayload(marker)]), runner)

        expectArgvOnly(runner, marker, "notes recent --folder")
    }

    // MARK: envelope

    @Test("the hit shape is search's NoteSummary verbatim, placeholders included")
    func hitShapeMatchesSearch() throws {
        let data = try drive(try RecentCmd.parse([]), twoPassRunner(scrambled))
        let hit = try #require((data["notes"] as? [[String: Any]])?.first)

        #expect(Set(hit.keys) == ["id", "title", "content", "tags", "folder", "account",
                                  "created", "modified"])
        #expect(hit["content"] as? String == "")
        #expect((hit["tags"] as? [Any])?.isEmpty == true)
        #expect(hit["folder"] as? String == "Folder")
        #expect(hit["account"] as? String == "iCloud")
        // `limit_reached` is the truncation signal `search` gives and this surface owes too.
        #expect(data["limit_reached"] as? Bool == false)
        // `limit_was_default` stays absent: `recent` has one default and discloses it as
        // `applied_limit`, so there is nothing a second flag would tell a caller.
        #expect(data["limit_was_default"] == nil)
    }

    @Test("the sync warning from the injected store is surfaced, and omitted when quiet")
    func surfacesTheSyncWarning() throws {
        let store = StubNotesStore.quiet()
        var status = NotesSyncStatus()
        status.sync_detected = true
        status.pending_upload = 3
        store.sync = status

        let data = try drive(try RecentCmd.parse([]), twoPassRunner(scrambled), store: store)
        #expect((data["sync_warning"] as? String)?.contains("iCloud sync") == true)

        let quiet = try drive(try RecentCmd.parse([]), twoPassRunner(scrambled))
        #expect(quiet["sync_warning"] == nil)
    }

    // MARK: --text

    @Test("--text renders `modified  title  (folder)`, newest first")
    func textRendering() throws {
        let runner = twoPassRunner(scrambled)
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
