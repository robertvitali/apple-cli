import Testing
import Foundation
@testable import NotesKit

/// Regression guards on GENERATED AppleScript text. The bugs below passed osacompile (the
/// broken forms are syntactically valid) and produced ok:true envelopes with silently wrong
/// data, so the only cheap tier that can hold them is an assertion on the emitted script.
/// All were verified live against the apple-notes-mcp oracle before these tests were written.
@Suite("NotesScript generation — data-correctness regressions")
struct ScriptGenTests {

    private func makeBody() -> String {
        NotesScript.searchBody(preamble: "", notesSource: "notes",
                               whereClause: "name contains (item 1 of argv)",
                               limitCheck: "")
    }

    // MARK: golden — the WHOLE script searchNotes hands osascript

    /// Every other assertion in this file is `contains`-based, which is the right shape for a
    /// single regression but cannot see a change it was not written to look for: `searchBody`
    /// gained a `preamble` parameter and made `whereClause` optional while every one of them
    /// stayed green. This pins the complete text, wrapper included, so ANY change to the emitted
    /// script — a new parameter that reorders a line, a lost `tell account`, a changed timeout —
    /// fails loudly and has to be re-approved here rather than shipping unnoticed.
    ///
    /// Update it only after confirming the new text is what you meant to emit.
    @Test("the full search script is byte-for-byte what it was")
    func searchScriptGolden() throws {
        let runner = FakeNotesRunner(results: [""])
        _ = try NotesScript(runner: runner, store: StubNotesStore.quiet())
            .searchNotes(query: "milk", searchContent: false, account: "iCloud",
                         folder: nil, modifiedSince: nil, limit: 50)
        let us = NotesScript.asUS
        let rs = NotesScript.asRS
        let expected = """
        on run argv
          with timeout of 45 seconds
            tell application "Notes"
              tell account (item 2 of argv)
        set matchingNotes to notes where name contains (item 1 of argv)
        set resultList to {}
        set seenIds to {}
        repeat with n in matchingNotes
          try
            set noteName to name of n
            set noteId to id of n
            if seenIds does not contain noteId then
              set end of seenIds to noteId
              try
                set noteCreated to creation date of n
                set createdParts to ((year of noteCreated) as text) & "-" & ((month of noteCreated) as integer as text) & "-" & ((day of noteCreated) as text) & "-" & ((hours of noteCreated) as text) & "-" & ((minutes of noteCreated) as text) & "-" & ((seconds of noteCreated) as text)
              on error
                set createdParts to ""
              end try
              try
                set noteModified to modification date of n
                set modifiedParts to ((year of noteModified) as text) & "-" & ((month of noteModified) as integer as text) & "-" & ((day of noteModified) as text) & "-" & ((hours of noteModified) as text) & "-" & ((minutes of noteModified) as text) & "-" & ((seconds of noteModified) as text)
              on error
                set modifiedParts to ""
              end try
              try
                set noteContainer to container of n
                set noteFolder to name of noteContainer
              on error
                set noteFolder to "Notes"
              end try
              set end of resultList to noteName & \(us) & noteId & \(us) & noteFolder & \(us) & createdParts & \(us) & modifiedParts
                  if (count of resultList) >= 50 then exit repeat
            end if
          end try
        end repeat
        set AppleScript's text item delimiters to \(rs)
        return resultList as text
              end tell
        end tell
          end timeout
        end run
        """
        #expect(try #require(runner.scripts.first) == expected)
        // The user's query is the control on the golden itself: it must be argv, not source.
        #expect(runner.arguments == [["milk", "iCloud"]])
    }

    // MARK: emitted limit guard (NOTES-M7/L2)

    /// The generated `exit repeat` guard had NO test at any N — the only call site above passes
    /// `limitCheck: ""`. That matters because the guard sits AFTER the append (a faithful clone of
    /// the oracle's own placement, index.js:39599), so it yields exactly N for N>=1 and would have
    /// yielded 1 for N=0. N=0 is now refused in `NotesScript.searchNotes` itself, but the emitted
    /// line is what actually bounds the loop, so it gets pinned here.
    @Test("the emitted limit guard appears after the append and reads >= N")
    func emittedLimitGuard() {
        for n in [1, 50] {
            let body = NotesScript.searchBody(preamble: "", notesSource: "notes",
                                              whereClause: "name contains (item 1 of argv)",
                                              limitCheck: "\n          if (count of resultList) >= \(n) then exit repeat")
            #expect(body.contains("if (count of resultList) >= \(n) then exit repeat"))
            let append = body.range(of: "set end of resultList")
            let guardPos = body.range(of: "if (count of resultList) >= \(n)")
            #expect(append != nil && guardPos != nil)
            // Order is the parity claim: append THEN check, matching the oracle.
            #expect(append!.lowerBound < guardPos!.lowerBound,
                    "guard must follow the append, as the oracle emits it")
        }
        // Control: with no limit the guard is absent entirely, so the assertions above
        // cannot pass vacuously on a body that always contains the string.
        #expect(!makeBody().contains("exit repeat"))
    }

    // MARK: search folder attribution (two-step container binding)

    @Test("search body binds the container to its own variable before reading its name")
    func searchBodyTwoStepContainer() {
        let body = makeBody()
        // The chained `set noteFolder to name of container of n` ALWAYS errors at runtime
        // ("Can't make name of «class cntr» of «class note» … into type Unicode text"), so the
        // on-error fallback reported EVERY hit as folder "Notes" — including notes in Recently
        // Deleted, which the oracle explicitly flags. The two-step binding is what the oracle
        // does. (Match the statement form `to name of container of n`, not the bare phrase, so
        // a future doc line quoting the phrase cannot false-positive this assertion.)
        #expect(!body.contains("to name of container of n"))
        #expect(body.contains("set noteContainer to container of n"))
        #expect(body.contains("set noteFolder to name of noteContainer"))
        // The fallback must survive the fix: a note whose container genuinely cannot be read
        // still reports the default folder rather than aborting the whole row.
        #expect(body.contains("set noteFolder to \"Notes\""))
    }

    // MARK: search row shape — 5 fields, mirroring the oracle

    @Test("search body reads real created/modified per hit and emits the 5-field oracle row")
    func searchBodyEmitsOracleRow() {
        let body = makeBody()
        // The oracle's search loop reads BOTH dates per hit (independent try-blocks, "" on a
        // failed read) and appends them to the row; a 3-field row drops two real fields the
        // MCP returns, which the strict-superset rule forbids.
        #expect(body.contains("set noteCreated to creation date of n"))
        #expect(body.contains("set noteModified to modification date of n"))
        #expect(body.contains("set createdParts to \"\""))
        #expect(body.contains("set modifiedParts to \"\""))
        let sep = " & \(NotesScript.asUS) & "
        #expect(body.contains("noteName\(sep)noteId\(sep)noteFolder\(sep)createdParts\(sep)modifiedParts"))
    }

    @Test("parseSummaries carries the real dates from a 5-field row into NoteSummary")
    func parseSummariesRealDates() throws {
        let us = NotesScript.US
        let row = ["My note", "x-coredata://ABC/p42", "Work", "2024-3-9-14-30-5", "2025-12-31-23-59-59"]
            .joined(separator: us)
        let notes = NotesScript.parseSummaries(row, account: "iCloud")
        let n = try #require(notes.first)
        #expect(n.title == "My note")
        #expect(n.folder == "Work")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: n.created)
        #expect((c.year, c.month, c.day, c.hour, c.minute, c.second) == (2024, 3, 9, 14, 30, 5))
        let m = cal.dateComponents([.year, .month, .day], from: n.modified)
        #expect((m.year, m.month, m.day) == (2025, 12, 31))
    }

    // MARK: search hit content/tags placeholders (NOTES-M1 — operator-ruled strict parity)

    /// The oracle's `searchNotes()` hardcodes `content: ""` / `tags: []` on EVERY hit
    /// (build/index.js ~39810: `content: "", // Not fetched in search`) — never a real fetch, so
    /// mirroring it byte-for-byte means literal empty values, not populated ones.
    @Test("parseSummaries emits the oracle's literal content/tags placeholders on every hit")
    func parseSummariesContentTagsPlaceholders() throws {
        let us = NotesScript.US
        let row = ["My note", "x-coredata://ABC/p42", "Work", "2024-3-9-14-30-5", "2025-12-31-23-59-59"]
            .joined(separator: us)
        let notes = NotesScript.parseSummaries(row, account: "iCloud")
        let n = try #require(notes.first)
        #expect(n.content == "")
        #expect(n.tags == [])
    }

    /// Golden-envelope pin: guards the wire key NAMES/VALUES against a future accidental
    /// Optional-ification of `content`/`tags` (which would let `JSONEncoder` silently omit them
    /// again — the exact regression NOTES-M1 restores). Mirrors
    /// `SearchLimitParityTests.envelopeFieldNames`'s style.
    @Test("the search-hit envelope encodes the oracle's content/tags keys verbatim")
    func searchHitEnvelopeContentTagsKeys() throws {
        let hit = NoteSummary(id: "x-coredata://ABC/p42", title: "My note", content: "", tags: [],
                              folder: "Work", account: "iCloud", created: Date(), modified: Date())
        let json = try String(data: JSONEncoder().encode(hit), encoding: .utf8)!
        #expect(json.contains("\"content\":\"\""))
        #expect(json.contains("\"tags\":[]"))
    }

    // MARK: dateVarSetup month-rollover guard (oracle issue #86)

    @Test("dateVarSetup clamps day to 1 BEFORE setting the month, and restores it after")
    func dateVarSetupClampsDayFirst() throws {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 15; c.hour = 10; c.minute = 30; c.second = 5
        let d = try #require(NotesScript.gregorian.date(from: c))
        let lines = NotesScript.dateVarSetup(d, name: "thresholdDate")
            .split(separator: "\n").map { String($0) }

        // `current date` carries TODAY's day-of-month. Without the clamp, `set month of X to 6`
        // on the 31st rolls the date into July (June has 30 days), and the later real `set day`
        // cannot undo the month that already advanced — silently shrinking every
        // --modified-since result set. Verified live: unguarded returns "July 1, 2026" for a
        // June target; guarded returns "June 1, 2026".
        //
        // lastIndex for the real-day lookup: with a day-1 fixture both day lines are identical,
        // and firstIndex would resolve the "real" assignment to the clamp line and fail
        // spuriously. The fixture uses day 15, but the lookup must not depend on that.
        let clampIdx = try #require(lines.firstIndex(of: "set day of thresholdDate to 1"))
        let monthIdx = try #require(lines.firstIndex(of: "set month of thresholdDate to 6"))
        let realDayIdx = try #require(lines.lastIndex { $0.hasPrefix("set day of thresholdDate to") })
        #expect(clampIdx < monthIdx)
        #expect(monthIdx < realDayIdx)
        #expect(lines[realDayIdx] == "set day of thresholdDate to 15")
    }

    @Test("dateVarSetup emits the exact guarded sequence")
    func dateVarSetupExactText() throws {
        var c = DateComponents()
        c.year = 2026; c.month = 2; c.day = 28; c.hour = 0; c.minute = 0; c.second = 0
        let d = try #require(NotesScript.gregorian.date(from: c))
        let expected = """
        set t to current date
        set day of t to 1
        set year of t to 2026
        set month of t to 2
        set day of t to 28
        set time of t to 0

        """
        #expect(NotesScript.dateVarSetup(d, name: "t") == expected)
    }
}
