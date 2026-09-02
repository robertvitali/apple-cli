import Testing
import Foundation
import ArgumentParser
@testable import RemindersKit
import EventKitCore
import AppleKit
import EventKit

// Logic-tier tests for the Reminders domain. These are TCC-free, not EventKit-free: an
// `EKEventStore` is constructed ONLY as an inert object factory for `EKReminder` / `EKCalendar`
// (there is no in-memory substitute for `EKReminder(eventStore:)`), and access/fetch/save/
// remove/commit is NEVER issued against it — every such call routes through `FakeReminderStore`.
// Construction alone neither prompts nor reads TCC. Covers priority parsing, dueWithin windows,
// the notes-field tag + subtask model (parity with the apple-events MCP tagUtils.ts /
// subtaskUtils.ts), the update notes-rebuild, alarm/recurrence spec parsing, the write-preview
// envelope shapes, and the commands driven through the injected store.

// MARK: - Priority

@Suite("ReminderPriority")
struct PriorityTests {
    @Test func parsesIntsAndWords() throws {
        #expect(try ReminderPriority.parse("0") == 0)
        #expect(try ReminderPriority.parse("1") == 1)
        #expect(try ReminderPriority.parse("5") == 5)
        #expect(try ReminderPriority.parse("9") == 9)
        #expect(try ReminderPriority.parse("none") == 0)
        #expect(try ReminderPriority.parse("high") == 1)
        #expect(try ReminderPriority.parse("medium") == 5)
        #expect(try ReminderPriority.parse("low") == 9)
        #expect(try ReminderPriority.parse("HIGH") == 1) // case-insensitive
    }

    @Test func acceptsFullRangeAsSuperset() throws {
        #expect(try ReminderPriority.parse("3") == 3)
        #expect(try ReminderPriority.parse("7") == 7)
    }

    @Test func rejectsOutOfRangeAndGarbage() {
        #expect(throws: AppleError.self) { _ = try ReminderPriority.parse("10") }
        #expect(throws: AppleError.self) { _ = try ReminderPriority.parse("-1") }
        #expect(throws: AppleError.self) { _ = try ReminderPriority.parse("urgent") }
    }

    @Test func filterValueMapsMcpWords() throws {
        #expect(try ReminderPriority.filterValue("none") == 0)
        #expect(try ReminderPriority.filterValue("high") == 1)
        #expect(try ReminderPriority.filterValue("medium") == 5)
        #expect(try ReminderPriority.filterValue("low") == 9)
        #expect(throws: AppleError.self) { _ = try ReminderPriority.filterValue("3") }
    }
}

// MARK: - dueWithin

@Suite("DueWithin")
struct DueWithinTests {
    // Fixed clock: Wed 2026-07-15 12:00 local, gregorian calendar with a fixed reference.
    let cal = Calendar(identifier: .gregorian)
    func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }
    var now: Date { date("2026-07-15T12:00:00Z") }

    @Test func validateRejectsBadWindow() {
        #expect(throws: AppleError.self) { try DueWithin.validate("someday") }
        #expect(throws: Never.self) { try DueWithin.validate("this-week") }
    }

    @Test func noDateMatchesOnlyNilDue() {
        var c = cal; c.timeZone = TimeZone(identifier: "UTC")!
        #expect(DueWithin.matches(due: nil, filter: "no-date", now: now, calendar: c) == true)
        #expect(DueWithin.matches(due: now, filter: "no-date", now: now, calendar: c) == false)
    }

    @Test func overdueIsBeforeStartOfToday() {
        var c = cal; c.timeZone = TimeZone(identifier: "UTC")!
        #expect(DueWithin.matches(due: date("2026-07-14T23:00:00Z"), filter: "overdue", now: now, calendar: c) == true)
        #expect(DueWithin.matches(due: date("2026-07-15T09:00:00Z"), filter: "overdue", now: now, calendar: c) == false)
        #expect(DueWithin.matches(due: nil, filter: "overdue", now: now, calendar: c) == false)
    }

    @Test func todayAndTomorrowWindows() {
        var c = cal; c.timeZone = TimeZone(identifier: "UTC")!
        #expect(DueWithin.matches(due: date("2026-07-15T08:00:00Z"), filter: "today", now: now, calendar: c) == true)
        #expect(DueWithin.matches(due: date("2026-07-16T08:00:00Z"), filter: "today", now: now, calendar: c) == false)
        #expect(DueWithin.matches(due: date("2026-07-16T08:00:00Z"), filter: "tomorrow", now: now, calendar: c) == true)
        #expect(DueWithin.matches(due: date("2026-07-17T08:00:00Z"), filter: "tomorrow", now: now, calendar: c) == false)
    }

    @Test func thisWeekWindow() {
        var c = cal; c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 1
        // now = Wed 2026-07-15; the week (Sun 07-12 … Sun 07-19) contains Thu 07-16 but not
        // next Saturday 07-25 — deterministic regardless of Sunday-vs-Monday week start.
        #expect(DueWithin.matches(due: date("2026-07-16T10:00:00Z"), filter: "this-week", now: now, calendar: c) == true)
        #expect(DueWithin.matches(due: date("2026-07-25T10:00:00Z"), filter: "this-week", now: now, calendar: c) == false)
    }
}

// MARK: - Tags (notes-field parity)

@Suite("ReminderTags")
struct TagTests {
    @Test func extractDedupesAndLowercases() {
        #expect(ReminderTags.extract("[#Work] [#urgent] [#work] body") == ["work", "urgent"])
        #expect(ReminderTags.extract("no tags here") == [])
        #expect(ReminderTags.extract(nil) == [])
    }

    @Test func stripRemovesMarkers() {
        #expect(ReminderTags.strip("[#work] [#urgent] Buy milk") == "Buy milk")
        #expect(ReminderTags.strip("[#a]") == "")
    }

    @Test func combinePrependsFormattedTags() {
        #expect(ReminderTags.combine(tags: ["work"], notes: "Buy milk") == "[#work]\nBuy milk")
        #expect(ReminderTags.combine(tags: ["Work", "work"], notes: nil) == "[#work]")
        // existing tags in notes are preserved + merged
        #expect(ReminderTags.combine(tags: ["new"], notes: "[#old] body") == "[#new] [#old]\nbody")
    }

    @Test func addAndRemove() {
        #expect(ReminderTags.add(["b"], to: "[#a] x") == "[#a] [#b]\nx")
        #expect(ReminderTags.remove(["a"], from: "[#a] [#b] x") == "[#b]\nx")
    }

    @Test func hasAllRequiresEvery() {
        #expect(ReminderTags.hasAll(reminderTags: ["work", "urgent"], filterTags: ["work"]) == true)
        #expect(ReminderTags.hasAll(reminderTags: ["work"], filterTags: ["work", "urgent"]) == false)
        #expect(ReminderTags.hasAll(reminderTags: nil, filterTags: ["work"]) == false)
        #expect(ReminderTags.hasAll(reminderTags: nil, filterTags: []) == true)
    }

    @Test func validateEnforcesCharset() {
        #expect(throws: Never.self) { try ReminderTags.validate("work_item-1") }
        #expect(throws: Never.self) { try ReminderTags.validate("#hashprefixed") }
        #expect(throws: AppleError.self) { try ReminderTags.validate("bad tag") }
        #expect(throws: AppleError.self) { try ReminderTags.validate("") }
    }
}

// MARK: - Subtasks (notes-field parity)

@Suite("ReminderSubtasks")
struct SubtaskTests {
    let sample = "---SUBTASKS---\n[ ] {aaaa1111} Buy milk\n[x] {bbbb2222} Get eggs\n---END SUBTASKS---"

    @Test func parseReadsLinesInOrder() {
        let subs = ReminderSubtasks.parse(sample)
        #expect(subs.count == 2)
        #expect(subs[0].id == "aaaa1111")
        #expect(subs[0].title == "Buy milk")
        #expect(subs[0].completed == false)
        #expect(subs[1].completed == true)
    }

    @Test func serializeRoundTrips() {
        let subs = ReminderSubtasks.parse(sample)
        #expect(ReminderSubtasks.serialize(subs) == sample)
    }

    @Test func combineAppendsAfterCleanNotes() {
        let subs = [Subtask(id: "aaaa1111", title: "X", completed: false)]
        let combined = ReminderSubtasks.combine(subtasks: subs, notes: "user note")
        #expect(combined == "user note\n\n---SUBTASKS---\n[ ] {aaaa1111} X\n---END SUBTASKS---")
    }

    @Test func stripRemovesSection() {
        #expect(ReminderSubtasks.strip("hello\n\n" + sample) == "hello")
    }

    @Test func addUsesInjectedId() throws {
        let (notes, sub) = try ReminderSubtasks.add(title: "New", notes: nil, idGen: { "deadbeef" })
        #expect(sub.id == "deadbeef")
        #expect(sub.title == "New")
        #expect(ReminderSubtasks.parse(notes).map { $0.id } == ["deadbeef"])
    }

    @Test func emptySubtaskTitleIsRejected() {
        // An empty title would serialize to `[ ] {id} ` and vanish on re-parse → must throw.
        #expect(throws: AppleError.self) { _ = try ReminderSubtasks.add(title: "   ", notes: nil) }
        #expect(throws: AppleError.self) { _ = try ReminderSubtasks.fromTitles(["ok", ""]) }
        #expect(throws: AppleError.self) { _ = try ReminderSubtasks.update(id: "aaaa1111", title: "  ", completed: nil, notes: sample) }
    }

    @Test func notesFormatIsByteCompatibleWithMcp() {
        // The serialized block must match the apple-events MCP subtaskUtils.ts format verbatim so
        // read output diffs cleanly against the oracle.
        let subs = [Subtask(id: "abcd1234", title: "Task one", completed: false),
                    Subtask(id: "ef567890", title: "Task two", completed: true)]
        #expect(ReminderSubtasks.serialize(subs) ==
            "---SUBTASKS---\n[ ] {abcd1234} Task one\n[x] {ef567890} Task two\n---END SUBTASKS---")
    }

    @Test func updateChangesTitleAndCompletion() throws {
        let (notes, updated) = try ReminderSubtasks.update(id: "aaaa1111", title: "Renamed", completed: true, notes: sample)
        #expect(updated.title == "Renamed")
        #expect(updated.completed == true)
        #expect(ReminderSubtasks.parse(notes)[0].title == "Renamed")
    }

    @Test func updateMissingThrowsNotFound() {
        #expect(throws: AppleError.self) { _ = try ReminderSubtasks.update(id: "ffff9999", title: "x", completed: nil, notes: sample) }
    }

    @Test func removeDropsTheSubtask() throws {
        let notes = try ReminderSubtasks.remove(id: "aaaa1111", notes: sample)
        #expect(ReminderSubtasks.parse(notes).map { $0.id } == ["bbbb2222"])
    }

    @Test func toggleFlipsCompletion() throws {
        let (notes, toggled) = try ReminderSubtasks.toggle(id: "aaaa1111", notes: sample)
        #expect(toggled.completed == true)
        #expect(ReminderSubtasks.parse(notes)[0].completed == true)
    }

    @Test func reorderRequiresAllIds() throws {
        let (notes, reordered) = try ReminderSubtasks.reorder(order: ["bbbb2222", "aaaa1111"], notes: sample)
        #expect(reordered.map { $0.id } == ["bbbb2222", "aaaa1111"])
        #expect(ReminderSubtasks.parse(notes)[0].id == "bbbb2222")
    }

    @Test func reorderMissingIdThrowsValidation() {
        #expect(throws: AppleError.self) { _ = try ReminderSubtasks.reorder(order: ["aaaa1111"], notes: sample) }
    }

    @Test func reorderUnknownIdThrowsNotFound() {
        #expect(throws: AppleError.self) { _ = try ReminderSubtasks.reorder(order: ["aaaa1111", "bbbb2222", "cccc3333"], notes: sample) }
    }

    @Test func progressComputesPercentage() {
        let subs = ReminderSubtasks.parse(sample) // 1 of 2 done
        let p = ReminderSubtasks.progress(subs)
        #expect(p.completed == 1)
        #expect(p.total == 2)
        #expect(p.percentage == 50)
        // empty → 100% per the MCP convention
        #expect(ReminderSubtasks.progress([]).percentage == 100)
    }

    @Test func generateIdIsEightHex() {
        let id = ReminderSubtasks.generateId()
        #expect(id.count == 8)
        #expect(id.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }

    @Test func validateIdRejectsNonHex() {
        #expect(throws: Never.self) { try ReminderSubtasks.validateId("abc123") }
        #expect(throws: AppleError.self) { try ReminderSubtasks.validateId("XYZ") }
        #expect(throws: AppleError.self) { try ReminderSubtasks.validateId("") }
    }
}

// MARK: - Notes rebuild on update (parity with rebuildNotesForUpdate)

@Suite("ReminderNotes.rebuildForUpdate")
struct NotesRebuildTests {
    @Test func preservesSubtasksWhenReplacingNote() {
        let current = "[#work] old body\n\n---SUBTASKS---\n[ ] {aaaa1111} Sub\n---END SUBTASKS---"
        let rebuilt = ReminderNotes.rebuildForUpdate(current: current, newNote: "new body", tags: nil, addTags: nil, removeTags: nil)
        // tags preserved, note replaced, subtasks preserved
        #expect(rebuilt.contains("[#work]"))
        #expect(rebuilt.contains("new body"))
        #expect(rebuilt.contains("---SUBTASKS---"))
        #expect(rebuilt.contains("{aaaa1111}"))
        #expect(!rebuilt.contains("old body"))
    }

    @Test func replaceAllTags() {
        let current = "[#a] body"
        let rebuilt = ReminderNotes.rebuildForUpdate(current: current, newNote: nil, tags: ["b"], addTags: nil, removeTags: nil)
        #expect(rebuilt.contains("[#b]"))
        #expect(!rebuilt.contains("[#a]"))
    }

    @Test func addAndRemoveTags() {
        let current = "[#a] [#b] body"
        let rebuilt = ReminderNotes.rebuildForUpdate(current: current, newNote: nil, tags: nil, addTags: ["c"], removeTags: ["a"])
        #expect(rebuilt.contains("[#b]"))
        #expect(rebuilt.contains("[#c]"))
        #expect(!rebuilt.contains("[#a]"))
    }

    @Test func newNoteCarryingMarkersIsSanitized() {
        // A newNote that itself contains tag/subtask markers must have them stripped (the MCP does
        // stripSubtasks(stripTags(newNote))); existing tags + subtasks win, injected ones dropped.
        let current = "[#keep] old\n\n---SUBTASKS---\n[ ] {aaaa1111} Sub\n---END SUBTASKS---"
        let injected = "[#injected] fresh\n---SUBTASKS---\n[ ] {ffff9999} X\n---END SUBTASKS---"
        let rebuilt = ReminderNotes.rebuildForUpdate(current: current, newNote: injected, tags: nil, addTags: nil, removeTags: nil)
        #expect(rebuilt.contains("fresh"))
        #expect(rebuilt.contains("[#keep]"))
        #expect(!rebuilt.contains("[#injected]"))
        #expect(rebuilt.contains("{aaaa1111}"))
        #expect(!rebuilt.contains("{ffff9999}"))
    }

    @Test func clearTagsViaEmptyArray() {
        // --clear-tags passes an empty-but-present tags array → all tags removed, note preserved.
        let rebuilt = ReminderNotes.rebuildForUpdate(current: "[#a] [#b] body", newNote: nil, tags: [], addTags: nil, removeTags: nil)
        #expect(!rebuilt.contains("[#a]"))
        #expect(!rebuilt.contains("[#b]"))
        #expect(rebuilt.contains("body"))
    }
}

// MARK: - Alarm + recurrence spec parsing

@Suite("ReminderAlarmSpec")
struct AlarmSpecTests {
    @Test func relativeOffsets() throws {
        #expect(try ReminderAlarmSpec.parse("-15m").relative_offset == -900)
        #expect(try ReminderAlarmSpec.parse("-2h").relative_offset == -7200)
        #expect(try ReminderAlarmSpec.parse("-1d").relative_offset == -86_400)
        #expect(try ReminderAlarmSpec.parse("-900").relative_offset == -900)
    }

    @Test func geofence() throws {
        let a = try ReminderAlarmSpec.parse("geo:37.33,-122.03,150,leave,Home")
        #expect(a.location_trigger?.latitude == 37.33)
        #expect(a.location_trigger?.longitude == -122.03)
        #expect(a.location_trigger?.radius == 150)
        #expect(a.location_trigger?.proximity == "leave")
        #expect(a.location_trigger?.title == "Home")
    }

    @Test func absoluteDate() throws {
        let a = try ReminderAlarmSpec.parse("2026-07-15T09:00:00")
        #expect(a.absolute_date != nil)
    }

    /// REM-05: the Reminders wrapper now delegates to the shared `EventKitCore.GeofenceSpec`,
    /// closing the per-domain copy's three defects — pinned HERE (not only in EventKitCore)
    /// so the delegation itself cannot silently regress.
    @Test func geofenceCommaTitleAndNumericTitle() throws {
        let a = try ReminderAlarmSpec.parse("geo:37.7,-122.4,100,enter,742 Evergreen Terrace, Springfield, OR 97475")
        #expect(a.location_trigger?.title == "742 Evergreen Terrace, Springfield, OR 97475")
        // a numeric title after an explicit radius no longer overwrites the radius
        let b = try ReminderAlarmSpec.parse("geo:37.7,-122.4,100,enter,2024")
        #expect(b.location_trigger?.radius == 100)
        #expect(b.location_trigger?.title == "2024")
        // the shared parser brings Calendar's lat/lon range validation to Reminders
        #expect(throws: AppleError.self) { _ = try ReminderAlarmSpec.parse("geo:91,0") }
    }

    /// REM-07: `until=` routes through the shared `DateParsing`, whose bare dates now anchor
    /// at MIDNIGHT local (CAL-02) — the recurrence end no longer sits at noon.
    @Test func recurrenceUntilAnchorsAtMidnight() throws {
        let rule = try ReminderRecurrenceSpec.parse("freq=daily;until=2026-12-31")
        let end = try #require(rule.end_date)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.hour, .minute, .day], from: end)
        #expect(comps.hour == 0 && comps.minute == 0 && comps.day == 31,
                "until= must anchor at local midnight, got \(end)")
    }

    @Test func geofenceProximityKeywordIsPositionIndependent() throws {
        // Regression: `geo:lat,lon,leave` (keyword in the radius slot) must set proximity=leave,
        // not silently keep enter.
        let a = try ReminderAlarmSpec.parse("geo:37.3,-122.0,leave")
        #expect(a.location_trigger?.proximity == "leave")
        #expect(a.location_trigger?.radius == 100)
        let b = try ReminderAlarmSpec.parse("geo:37.3,-122.0,enter,250,Home")
        #expect(b.location_trigger?.proximity == "enter")
        #expect(b.location_trigger?.radius == 250)
        #expect(b.location_trigger?.title == "Home")
    }

    @Test func rejectsGarbage() {
        #expect(throws: AppleError.self) { _ = try ReminderAlarmSpec.parse("") }
        #expect(throws: AppleError.self) { _ = try ReminderAlarmSpec.parse("geo:notanumber") }
    }
}

@Suite("ReminderRecurrenceSpec")
struct RecurrenceSpecTests {
    @Test func parsesWeeklyByDay() throws {
        let r = try ReminderRecurrenceSpec.parse("freq=weekly;interval=2;byday=2,4;count=10")
        #expect(r.frequency == "weekly")
        #expect(r.interval == 2)
        #expect(r.days_of_week == [2, 4])
        #expect(r.occurrence_count == 10)
    }

    @Test func requiresFreq() {
        #expect(throws: AppleError.self) { _ = try ReminderRecurrenceSpec.parse("interval=2") }
    }

    @Test func builtEkRuleValidatesRange() {
        // day_of_week 9 is out of range → the shared mapper rejects it (strict superset).
        #expect(throws: AppleError.self) {
            let r = try ReminderRecurrenceSpec.parse("freq=weekly;byday=9")
            _ = try RecurrenceMapping.ekRule(from: r)
        }
    }
}

// MARK: - Output envelope shapes (contract)

@Suite("Output envelopes")
struct EnvelopeTests {
    func json<T: Encodable>(_ data: T) throws -> String {
        String(data: try Output.encodeSuccess(tool: "reminders", data: data), encoding: .utf8)!
    }

    @Test func writePreviewIsDryRun() throws {
        let s = try json(ReminderWritePreview(action: "create", title: "apple-cli-test x", priority: 1))
        #expect(s.contains("\"schema_version\" : 1"))
        #expect(s.contains("\"tool\" : \"reminders\""))
        #expect(s.contains("\"ok\" : true"))
        #expect(s.contains("\"dry_run\" : true"))
        #expect(s.contains("\"action\" : \"create\""))
    }

    @Test func subtasksDataShape() throws {
        let subs = [Subtask(id: "aaaa1111", title: "X", completed: false)]
        let s = try json(SubtasksData(reminder_id: "R1", reminder_title: "T",
                                      progress: ReminderSubtasks.progress(subs), subtasks: subs))
        #expect(s.contains("\"reminder_id\" : \"R1\""))
        #expect(s.contains("\"percentage\" : 0"))
        #expect(s.contains("\"completed\" : false"))
    }

    @Test func deleteEnvelope() throws {
        let s = try json(ReminderDeleteData(id: "R1", deleted: true))
        #expect(s.contains("\"deleted\" : true"))
        #expect(s.contains("\"id\" : \"R1\""))
    }
}

// MARK: - Write guard
//
// The v1 `ReminderWriteGuard.shouldExecute` suite that lived here asserted `dryRunByDefault` and
// `executeWithoutTestModeThrows` — both of which write-model v2 deliberately INVERTS (writes now
// execute on call, and `--execute` needs no test-mode companion). It is replaced, not deleted:
// see "Reminders write-model v2 posture" in WriteSafetyTests.swift, which pins the new decision
// (default-execute, --dry-run precedence, sandbox-only label gate) plus the destination-label
// coverage the v1 suite never had.

// MARK: - Reminder timezone resolution (REM-04)

@Suite("ReminderTZ")
struct ReminderTZTests {
    func parsed(_ s: String) throws -> DateParsing.Parsed { try DateParsing.parse(s) }

    @Test("startTz ?? dueTz — offset pins its fixed zone, local pins the current one")
    func precedence() throws {
        let offsetOnly = try ReminderTZ.resolve(startParsed: nil,
                                                dueParsed: parsed("2026-09-01T10:00:00+02:00"))
        #expect(offsetOnly?.identifier == "GMT+0200")
        let startWins = try ReminderTZ.resolve(startParsed: parsed("2026-09-01T09:00:00-04:00"),
                                               dueParsed: parsed("2026-09-01T10:00:00-04:00"))
        #expect(startWins?.identifier == "GMT-0400")
        #expect(try ReminderTZ.resolve(startParsed: parsed("2026-09-01"), dueParsed: nil)
                == TimeZone.current)
        #expect(try ReminderTZ.resolve(startParsed: nil, dueParsed: nil) == nil)
    }

    @Test("a same-call start/due zone mismatch is a validation rejection (oracle 400)")
    func conflict() throws {
        #expect(throws: AppleError.self) {
            _ = try ReminderTZ.resolve(startParsed: parsed("2026-09-01T09:00:00+02:00"),
                                       dueParsed: parsed("2026-09-01T10:00:00-05:00"))
        }
        // local start + offset due also mismatches (named zone vs fixed GMT zone, same
        // identifier quirk the oracle has)
        #expect(throws: AppleError.self) {
            _ = try ReminderTZ.resolve(startParsed: parsed("2026-09-01 09:00:00"),
                                       dueParsed: parsed("2026-09-01T10:00:00+02:00"))
        }
    }

    // `apply` itself is a two-line thin writer over `resolve` and is NOT pinned here: an
    // in-memory `EKReminder` from a storeless `EKEventStore` silently drops `timeZone`
    // assignments (measured — the setter is a no-op without a backing calendar), so the wiring
    // is only observable in the live tier. `resolve`, which carries all the logic, is pinned
    // above.
}

// MARK: - Reminder read mapping renders REM-02 date strings

@Suite("ReminderMapping date rendering")
struct ReminderMappingDateTests {
    /// REM-02 end-to-end at the mapping layer (review: the golden corpus pinned the FORMATTER,
    /// but `ReminderMapping.reminder(from:)` — the production wiring — was untested; EKReminder
    /// is in-memory constructible, so it is NOT behind the live store).
    @Test("date-only due renders date-only; timed due renders timed; both in the pinned zone")
    func dueRendering() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ny

        let r = EKReminder(eventStore: EKEventStore())
        r.timeZone = ny
        var dateOnly = DateComponents(year: 2026, month: 9, day: 1)
        dateOnly.calendar = cal
        dateOnly.timeZone = ny
        r.dueDateComponents = dateOnly
        #expect(ReminderMapping.reminder(from: r).due_date == "2026-09-01-04:00")

        var timed = DateComponents(year: 2026, month: 9, day: 1, hour: 10, minute: 0, second: 0)
        timed.calendar = cal
        timed.timeZone = ny
        r.dueDateComponents = timed
        // Storeless EKReminder normalizes TIMED dueDateComponents into the HOST zone on some
        // OS builds (observed: hosted macos-15 CI renders this instant as 2026-09-01T14:00:00Z;
        // a New York host renders 2026-09-01T10:00:00-04:00 — same moment). The wiring
        // contract here is the INSTANT + timed rendering; exact zone pinning is covered by the
        // formatter golden corpus, which feeds components directly and skips EKReminder.
        let rendered = try #require(ReminderMapping.reminder(from: r).due_date)
        let iso = ISO8601DateFormatter()
        #expect(iso.date(from: rendered) == iso.date(from: "2026-09-01T10:00:00-04:00"))
        #expect(rendered.contains("T"), "timed due must render with a time component")
    }
}

// MARK: - URL update guard (REM-12)

@Suite("ReminderURLUpdate")
struct ReminderURLUpdateTests {
    @Test("invalid is a NO-OP, empty clears, valid replaces")
    func resolveRules() {
        let current = URL(string: "https://example.com/keep")
        // Modern Foundation's URL(string:) is LENIENT (percent-encodes "not a url" instead of
        // returning nil) — measured, and the oracle gets the same leniency from the same API,
        // so parity holds automatically for those. The no-op guard matters for the shapes that
        // still return nil, e.g. a space inside an authority:
        #expect(ReminderURLUpdate.resolve(current: current, arg: "http://exa mple.com") == current)
        #expect(ReminderURLUpdate.resolve(current: current, arg: "") == nil)
        #expect(ReminderURLUpdate.resolve(current: current, arg: "https://new.example.com")
                == URL(string: "https://new.example.com"))
    }
}

// MARK: - Native list order (REM-09)

@Suite("reminder list ordering")
struct ReminderListOrderTests {
    /// REM-09's fix is a sort DELETION in live-store-only paths, so behavior cannot be pinned at
    /// this tier — this source-text guard keeps the alphabetical re-sort from silently returning
    /// (same tier-limitation pattern as the Notes wiring test); Q17's live re-audit diffs the
    /// real order against the oracle.
    @Test("no title re-sort in the list-emitting command paths")
    func noResort() throws {
        for rel in ["Sources/RemindersKit/ListsCommand.swift", "Sources/RemindersKit/TasksCommand.swift"] {
            let src = try String(contentsOfFile: #filePath
                .replacingOccurrences(of: "Tests/RemindersKitTests/RemindersSupportTests.swift",
                                      with: rel), encoding: .utf8)
            #expect(!src.contains("localizedCaseInsensitiveCompare"),
                    "\(rel): the alphabetical re-sort is back — EventKit native order IS the user's manual ordering")
        }
    }
}

// MARK: - Command execution with injected EventStore

final class FakeReminderStore: ReminderStore {
    /// INERT OBJECT FACTORY ONLY — see the file header. No access/fetch/save/remove/commit is
    /// ever issued against this instance.
    let ekStore = EKEventStore()
    var requestedAccess: [(EventStore.Entity, EventStore.AccessMode)] = []
    var lists: [EKCalendar]
    var defaultList: EKCalendar?
    /// Mirrors the real `EventStore.newCalendar(for:)`, which returns nil when
    /// `preferredSource` finds no writable source. The fake used to ALWAYS return a calendar,
    /// so `ListsCreate`'s "no writable reminders source" branch was unreachable from any test.
    var hasWritableSource = true
    var remindersById: [String: EKReminder] = [:]
    var reminderRows: [EKReminder] = []
    var savedReminders: [(EKReminder, Bool)] = []
    var removedReminders: [(EKReminder, Bool)] = []
    var savedLists: [(EKCalendar, Bool)] = []
    var removedLists: [(EKCalendar, Bool)] = []

    init() {
        let list = EKCalendar(for: .reminder, eventStore: ekStore)
        list.title = "apple-cli-test list"
        self.lists = [list]
        self.defaultList = list
    }

    func requestAccess(to entity: EventStore.Entity, mode: EventStore.AccessMode) throws {
        requestedAccess.append((entity, mode))
    }

    func calendars(for entity: EventStore.Entity) -> [EKCalendar] {
        entity == .reminder ? lists : []
    }

    func calendar(matching nameOrId: String, entity: EventStore.Entity) -> EKCalendar? {
        guard entity == .reminder else { return nil }
        return lists.first {
            $0.calendarIdentifier == nameOrId || $0.title.lowercased() == nameOrId.lowercased()
        }
    }

    var defaultCalendarForReminders: EKCalendar? { defaultList }

    func reminder(withIdentifier id: String) -> EKReminder? {
        remindersById[id]
    }

    /// Rows VERBATIM: EventKit's predicate semantics are not re-implemented here, so every
    /// `tasks read` filter under test is production's own in-process filtering.
    func reminders(matching predicate: NSPredicate) throws -> [EKReminder] {
        reminderRows
    }

    func predicateForReminders(in lists: [EKCalendar]?) -> NSPredicate {
        NSPredicate(value: true)
    }

    func newReminder(in list: EKCalendar) -> EKReminder {
        let reminder = EKReminder(eventStore: ekStore)
        reminder.calendar = list
        return reminder
    }

    func newCalendar(for entity: EventStore.Entity) -> EKCalendar? {
        guard entity == .reminder, hasWritableSource else { return nil }
        let list = EKCalendar(for: .reminder, eventStore: ekStore)
        return list
    }

    func save(_ reminder: EKReminder, commit: Bool) throws {
        savedReminders.append((reminder, commit))
    }

    func remove(_ reminder: EKReminder, commit: Bool) throws {
        removedReminders.append((reminder, commit))
    }

    func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        savedLists.append((calendar, commit))
        if !lists.contains(where: { $0 === calendar }) {
            lists.append(calendar)
        }
    }

    func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws {
        removedLists.append((calendar, commit))
    }
}

@Suite("Reminders command execution with injected store")
struct RemindersCommandExecutionTests {
    func streams() -> (CLIStreams, MemoryOutputSink) {
        let stdout = MemoryOutputSink()
        return (CLIStreams(stdout: stdout, stderr: MemoryOutputSink()), stdout)
    }

    func payload(from stdout: MemoryOutputSink) throws -> [String: Any] {
        let root = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
        return try #require(root["data"] as? [String: Any])
    }

    func errorPayload(from stdout: MemoryOutputSink) throws -> [String: Any] {
        let root = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
        return try #require(root["error"] as? [String: Any])
    }

    /// Run a command that must FAIL, and pin BOTH halves of the contract `runGuarded` binds
    /// atomically: the exact process exit value AND the emitted `error.type`. `#expect(throws:
    /// ExitCode.self)` on its own passes for any failure at all, so a branch that started
    /// throwing `.notFound` where it owes `.validation` (65 vs 64 — a discriminator agents
    /// branch on) would stay green. Asserting the pair is the exit-code matrix.
    func expectFailure(exit: Int32, type: String,
                       sourceLocation: SourceLocation = SourceLocation(
                        fileID: #fileID, filePath: #filePath, line: #line, column: #column),
                       _ body: () throws -> Void) throws {
        let (cliStreams, stdout) = streams()
        var thrown: Error?
        do { try Output.withStreams(cliStreams) { try body() } } catch { thrown = error }
        #expect((thrown as? ExitCode)?.rawValue == exit,
                "expected exit \(exit), got \(String(describing: thrown))",
                sourceLocation: sourceLocation)
        #expect((try errorPayload(from: stdout))["type"] as? String == type,
                sourceLocation: sourceLocation)
    }

    func reminder(title: String = "apple-cli-test task", list: EKCalendar, store: EKEventStore) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        reminder.notes = "[#work] synthetic\n\n---SUBTASKS---\n[ ] {aaaa1111} Draft\n---END SUBTASKS---"
        reminder.priority = 1
        return reminder
    }

    @Test("lists read emits injected lists")
    func listsRead() throws {
        let fake = FakeReminderStore()
        let command = try ListsRead.parse([])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(storeFactory: { fake })
        }

        let lists = try #require(try payload(from: stdout)["lists"] as? [[String: Any]])
        #expect(lists.map { $0["title"] as? String } == ["apple-cli-test list"])
        #expect(fake.requestedAccess.first?.1 == .read)
    }

    @Test("lists create executes through the injected store")
    func listsCreateExecute() throws {
        let fake = FakeReminderStore()
        let command = try ListsCreate.parse(["--name", "apple-cli-test new", "--color", "#336699"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(storeFactory: { fake })
        }

        #expect(fake.savedLists.count == 1)
        #expect(fake.savedLists[0].0.title == "apple-cli-test new")
        #expect(fake.savedLists[0].1 == true)   // a list that is not committed is not created
        let data = try payload(from: stdout)
        #expect(data["dry_run"] as? Bool == false)
        // The `--color` argument must reach `list.cgColor`; the emitted hex is the round-trip.
        #expect(data["color"] as? String == "#336699")
    }

    @Test("lists create surfaces the no-writable-source branch as upstream, not a crash")
    func listsCreateWithoutWritableSource() throws {
        // The real `EventStore.newCalendar(for:)` returns nil when `preferredSource` finds no
        // writable EKSource; the fake now mirrors that, so this error branch is reachable.
        let fake = FakeReminderStore()
        fake.hasWritableSource = false
        let command = try ListsCreate.parse(["--name", "apple-cli-test unsourced"])
        try expectFailure(exit: AppleExit.upstream, type: AppleErrorType.upstream) {
            try command.run(storeFactory: { fake })
        }
        #expect(fake.savedLists.isEmpty)
        // It failed AFTER opening the store — the distinction from a dry-run/no-op.
        #expect(fake.requestedAccess.first?.1 == .write)
    }

    @Test("lists update and delete execute through the injected store")
    func listsUpdateDeleteExecute() throws {
        let fake = FakeReminderStore()
        let update = try ListsUpdate.parse([
            "--name", "apple-cli-test list",
            "--new-name", "apple-cli-test renamed",
            "--color", "#663399",
        ])
        let (updateStreams, updateOut) = streams()

        try Output.withStreams(updateStreams) {
            try update.run(storeFactory: { fake })
        }

        #expect(fake.lists[0].title == "apple-cli-test renamed")
        #expect(fake.savedLists.count == 1)
        #expect(fake.savedLists[0].1 == true)
        #expect((try payload(from: updateOut))["dry_run"] as? Bool == false)

        let delete = try ListsDelete.parse(["--name", "apple-cli-test renamed"])
        let (deleteStreams, deleteOut) = streams()
        try Output.withStreams(deleteStreams) {
            try delete.run(storeFactory: { fake })
        }

        #expect(fake.removedLists.count == 1)
        // `removeCalendar` destroys the list AND every reminder in it — an uncommitted delete
        // would leave the store inconsistent with what the envelope just claimed.
        #expect(fake.removedLists[0].1 == true)
        #expect((try payload(from: deleteOut))["deleted"] as? Bool == true)
    }

    @Test("tasks read by id enriches the mapped reminder")
    func tasksReadById() throws {
        let fake = FakeReminderStore()
        let row = reminder(list: fake.lists[0], store: fake.ekStore)
        fake.remindersById["task-1"] = row
        let command = try TasksRead.parse(["--id", "task-1"])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(storeFactory: { fake })
        }

        let data = try payload(from: stdout)
        #expect(data["title"] as? String == "apple-cli-test task")
        #expect((data["tags"] as? [String]) == ["work"])
        #expect((data["subtasks"] as? [[String: Any]])?.count == 1)
    }

    /// Run `tasks read` with `args` against `rows` and return the emitted titles, in order.
    func readTitles(_ args: [String], rows: [EKReminder], store fake: FakeReminderStore) throws -> [String] {
        fake.reminderRows = rows
        let command = try TasksRead.parse(args)
        let (readStreams, out) = streams()
        try Output.withStreams(readStreams) {
            try command.run(storeFactory: { fake })
        }
        let emitted = try #require(try payload(from: out)["reminders"] as? [[String: Any]])
        return emitted.compactMap { $0["title"] as? String }
    }

    /// Each filter gets its OWN case, with a `drop` row that fails ONLY that filter. The
    /// previous single test applied all six at once against a `drop` row that independently
    /// failed four of them — so any one filter could have stopped filtering entirely and the
    /// other three would still have excluded `drop`, keeping the test green. Two of the six
    /// never discriminated at all there: `--filter-list` (both rows shared one list) and
    /// `--filter-tag` (both rows carried `[#work]` from the shared helper). Both now do.
    @Test("tasks read: each filter discriminates on its own dimension", arguments: [
        "list", "search", "priority", "recurring", "location", "tag", "completed",
    ])
    func tasksReadSingleFilter(dimension: String) throws {
        let fake = FakeReminderStore()
        let other = EKCalendar(for: .reminder, eventStore: fake.ekStore)
        other.title = "apple-cli-test other list"
        fake.lists.append(other)

        // `keep` satisfies every filter below; each case builds a `drop` that differs from it
        // in exactly ONE dimension and passes exactly ONE flag.
        func makeKeep() throws -> EKReminder {
            let keep = reminder(title: "apple-cli-test search hit", list: fake.lists[0], store: fake.ekStore)
            keep.addRecurrenceRule(try RecurrenceMapping.ekRule(
                from: RecurrenceRule(frequency: "daily", interval: 1)))
            keep.addAlarm(try AlarmMapping.ekAlarm(from: Alarm(location_trigger: LocationTrigger(
                title: "Office", latitude: 1, longitude: 2, radius: 100, proximity: "enter"))))
            return keep
        }

        let keep = try makeKeep()
        let drop = try makeKeep()
        drop.title = "apple-cli-test search hit"   // identical until the dimension is applied
        let args: [String]
        switch dimension {
        case "list":
            drop.calendar = other                       // only the list differs
            args = ["--filter-list", "apple-cli-test list"]
        case "search":
            drop.title = "apple-cli-test miss"
            drop.notes = "[#work] nothing to find"      // the search term is absent from both fields
            args = ["--search", "hit"]
        case "priority":
            drop.priority = 5                           // keep is 1 (high)
            args = ["--filter-priority", "high"]
        case "recurring":
            drop.recurrenceRules?.forEach { drop.removeRecurrenceRule($0) }
            args = ["--filter-recurring"]
        case "location":
            drop.alarms?.forEach { drop.removeAlarm($0) }
            args = ["--filter-location-based"]
        case "tag":
            drop.notes = "[#personal] synthetic"        // keep carries [#work]
            args = ["--filter-tag", "work"]
        default:                                        // "completed" — the default-on hide filter
            drop.isCompleted = true
            args = []
        }

        let kept = try readTitles(args, rows: [drop, keep], store: fake)
        #expect(kept.count == 1, "\(dimension): expected the drop row to be excluded, got \(kept)")
        // Control: WITHOUT the flag (and with completion shown), both rows survive — proving the
        // exclusion came from the filter and not from the fixture being malformed.
        let control = try readTitles(dimension == "completed" ? ["--show-completed"] : [],
                                     rows: [drop, keep], store: fake)
        #expect(control.count == 2, "\(dimension): unfiltered control should keep both rows")
    }

    @Test("tasks read: the six explicit filters still compose")
    func tasksReadFiltersCompose() throws {
        // The kitchen-sink case is still worth ONE test — it is how the flags are used together
        // — but it is no longer the only coverage any individual filter has.
        let fake = FakeReminderStore()
        let keep = reminder(title: "apple-cli-test search hit", list: fake.lists[0], store: fake.ekStore)
        keep.addRecurrenceRule(try RecurrenceMapping.ekRule(from: RecurrenceRule(frequency: "daily", interval: 1)))
        keep.addAlarm(try AlarmMapping.ekAlarm(from: Alarm(location_trigger: LocationTrigger(
            title: "Office", latitude: 1, longitude: 2, radius: 100, proximity: "enter"))))
        let drop = reminder(title: "apple-cli-test miss", list: fake.lists[0], store: fake.ekStore)
        drop.priority = 5

        let kept = try readTitles([
            "--filter-list", "apple-cli-test list",
            "--search", "hit",
            "--filter-priority", "high",
            "--filter-recurring",
            "--filter-location-based",
            "--filter-tag", "work",
        ], rows: [drop, keep], store: fake)
        #expect(kept == ["apple-cli-test search hit"])
    }

    @Test("tasks create executes through the injected store")
    func tasksCreateExecute() throws {
        let fake = FakeReminderStore()
        let command = try TasksCreate.parse([
            "--title", "apple-cli-test task",
            "--target-list", "apple-cli-test list",
            "--start", "2026-07-15T08:00:00Z",
            "--due", "2026-07-16T09:00:00Z",
            "--priority", "high",
            "--tag", "work",
            "--subtask", "Draft",
            "--alarm=-15m",
            "--recurrence", "freq=daily;count=2",
            "--geo-lat", "1",
            "--geo-lon", "2",
            "--geo-title", "Office",
        ])
        let (streams, stdout) = streams()

        try Output.withStreams(streams) {
            try command.run(storeFactory: { fake })
        }

        let saved = try #require(fake.savedReminders.first?.0)
        #expect(fake.savedReminders.first?.1 == true)   // an uncommitted create does not persist
        #expect(saved.title == "apple-cli-test task")
        #expect(saved.priority == 1)
        #expect(saved.notes?.contains("[#work]") == true)
        #expect(saved.notes?.contains("---SUBTASKS---") == true)
        #expect(saved.alarms?.count == 1)
        #expect(saved.recurrenceRules?.count == 1)
        #expect((try payload(from: stdout))["dry_run"] as? Bool == false)
    }

    @Test("tasks update and delete execute through the injected store")
    func tasksUpdateDeleteExecute() throws {
        let fake = FakeReminderStore()
        let row = reminder(list: fake.lists[0], store: fake.ekStore)
        fake.remindersById["task-1"] = row
        let update = try TasksUpdate.parse([
            "--id", "task-1",
            "--title", "apple-cli-test updated",
            "--note", "updated synthetic note",
            "--completed",
            "--priority", "low",
            "--clear-alarms",
            "--clear-recurrence",
        ])
        let (updateStreams, updateOut) = streams()

        try Output.withStreams(updateStreams) {
            try update.run(storeFactory: { fake })
        }

        #expect(row.title == "apple-cli-test updated")
        #expect(row.isCompleted == true)
        #expect(row.priority == 9)
        #expect(fake.savedReminders.count == 1)
        #expect(fake.savedReminders[0].1 == true)
        #expect((try payload(from: updateOut))["dry_run"] as? Bool == false)

        let delete = try TasksDelete.parse(["--id", "task-1"])
        let (deleteStreams, deleteOut) = streams()
        try Output.withStreams(deleteStreams) {
            try delete.run(storeFactory: { fake })
        }

        #expect(fake.removedReminders.count == 1)
        #expect(fake.removedReminders[0].1 == true)
        #expect((try payload(from: deleteOut))["deleted"] as? Bool == true)
    }

    @Test("subtasks read and mutating operations execute through the injected store")
    func subtasksExecute() throws {
        let fake = FakeReminderStore()
        let row = reminder(list: fake.lists[0], store: fake.ekStore)
        fake.remindersById["task-1"] = row

        let read = try SubtasksRead.parse(["--reminder-id", "task-1"])
        let (readStreams, readOut) = streams()
        try Output.withStreams(readStreams) {
            try read.run(storeFactory: { fake })
        }
        #expect((try payload(from: readOut))["reminder_title"] as? String == "apple-cli-test task")

        let create = try SubtasksCreate.parse(["--reminder-id", "task-1", "--title", "Review"])
        try Output.withStreams(streams().0) { try create.run(storeFactory: { fake }) }
        #expect(row.notes?.contains("Review") == true)

        let createdId = try #require(ReminderSubtasks.parse(row.notes).last?.id)
        let update = try SubtasksUpdate.parse([
            "--reminder-id", "task-1",
            "--subtask-id", createdId,
            "--title", "Review updated",
            "--completed",
        ])
        try Output.withStreams(streams().0) { try update.run(storeFactory: { fake }) }
        #expect(row.notes?.contains("Review updated") == true)

        let toggle = try SubtasksToggle.parse(["--reminder-id", "task-1", "--subtask-id", createdId])
        try Output.withStreams(streams().0) { try toggle.run(storeFactory: { fake }) }

        let ids = ReminderSubtasks.parse(row.notes).map(\.id)
        let reversedOrder = Array(ids.reversed()).flatMap { ["--order", $0] }
        let reorder = try SubtasksReorder.parse(["--reminder-id", "task-1"] + reversedOrder)
        try Output.withStreams(streams().0) { try reorder.run(storeFactory: { fake }) }

        let delete = try SubtasksDelete.parse(["--reminder-id", "task-1", "--subtask-id", createdId])
        try Output.withStreams(streams().0) { try delete.run(storeFactory: { fake }) }

        #expect(fake.savedReminders.count == 5)
        // Subtasks are persisted by REWRITING the parent reminder's notes, so every one of the
        // five mutations must commit or the checklist silently reverts.
        #expect(fake.savedReminders.allSatisfy { $0.1 == true })
        #expect(!ReminderSubtasks.parse(row.notes).contains { $0.id == createdId })
    }

    @Test("list write dry-runs emit previews without opening the store")
    func listDryRuns() throws {
        let fake = FakeReminderStore()
        // The factory is what OPENS the store (in production it is `{ EventStore() }`), so
        // "the dry run never touched the store" is only actually proved by the factory never
        // being CALLED — inspecting the fake's arrays cannot show it, since the fake exists
        // before the run either way.
        var factoryCalls = 0
        let create = try ListsCreate.parse(["--dry-run", "--name", "apple-cli-test preview", "--color", "#336699"])
        let (createStreams, createOut) = streams()
        try Output.withStreams(createStreams) {
            try create.run(storeFactory: { factoryCalls += 1; return fake })
        }
        #expect((try payload(from: createOut))["action"] as? String == "create")

        let update = try ListsUpdate.parse([
            "--dry-run",
            "--name", "apple-cli-test list",
            "--new-name", "apple-cli-test renamed",
            "--color", "#663399",
        ])
        let (updateStreams, updateOut) = streams()
        try Output.withStreams(updateStreams) {
            try update.run(storeFactory: { factoryCalls += 1; return fake })
        }
        let updateData = try payload(from: updateOut)
        #expect(updateData["action"] as? String == "update")
        #expect(updateData["dry_run"] as? Bool == true)

        let delete = try ListsDelete.parse(["--dry-run", "--test-mode", "--name", "list-id"])
        let (deleteStreams, deleteOut) = streams()
        try Output.withStreams(deleteStreams) {
            try delete.run(storeFactory: { factoryCalls += 1; return fake })
        }
        let deleteData = try payload(from: deleteOut)
        #expect(deleteData["action"] as? String == "delete")
        #expect(deleteData["sandbox_target_unchecked"] as? Bool == true)
        #expect(factoryCalls == 0)
        #expect(fake.requestedAccess.isEmpty)
        #expect(fake.savedLists.isEmpty)
        #expect(fake.removedLists.isEmpty)
    }

    @Test("task write dry-runs emit previews without opening the store")
    func taskDryRuns() throws {
        let fake = FakeReminderStore()
        // See `listDryRuns`: only a factory that is never CALLED proves the store was never
        // opened; the fake's empty arrays cannot.
        var factoryCalls = 0
        let create = try TasksCreate.parse([
            "--dry-run",
            "--title", "apple-cli-test preview",
            "--target-list", "apple-cli-test list",
            "--due", "2026-07-16T09:00:00Z",
            "--priority", "medium",
            "--tag", "work",
            "--subtask", "Draft",
        ])
        let (createStreams, createOut) = streams()
        try Output.withStreams(createStreams) {
            try create.run(storeFactory: { factoryCalls += 1; return fake })
        }
        let createData = try payload(from: createOut)
        #expect(createData["action"] as? String == "create")
        #expect(createData["dry_run"] as? Bool == true)

        let update = try TasksUpdate.parse([
            "--dry-run",
            "--test-mode",
            "--id", "task-1",
            "--title", "apple-cli-test updated",
            "--clear-alarms",
            "--clear-recurrence",
            "--clear-tags",
        ])
        let (updateStreams, updateOut) = streams()
        try Output.withStreams(updateStreams) {
            try update.run(storeFactory: { factoryCalls += 1; return fake })
        }
        let updateData = try payload(from: updateOut)
        #expect(updateData["action"] as? String == "update")
        #expect(updateData["sandbox_target_unchecked"] as? Bool == true)

        let delete = try TasksDelete.parse(["--dry-run", "--test-mode", "--id", "task-1"])
        let (deleteStreams, deleteOut) = streams()
        try Output.withStreams(deleteStreams) {
            try delete.run(storeFactory: { factoryCalls += 1; return fake })
        }
        let deleteData = try payload(from: deleteOut)
        #expect(deleteData["action"] as? String == "delete")
        #expect(deleteData["sandbox_target_unchecked"] as? Bool == true)
        #expect(factoryCalls == 0)
        #expect(fake.requestedAccess.isEmpty)
        #expect(fake.savedReminders.isEmpty)
        #expect(fake.removedReminders.isEmpty)
    }

    @Test("subtask write dry-runs emit previews without saving")
    func subtaskDryRuns() throws {
        let fake = FakeReminderStore()
        let row = reminder(list: fake.lists[0], store: fake.ekStore)
        fake.remindersById["task-1"] = row
        let existingId = try #require(ReminderSubtasks.parse(row.notes).first?.id)
        let notesBefore = row.notes
        // See `listDryRuns`: only an uncalled factory proves the store was never opened.
        var factoryCalls = 0

        let create = try SubtasksCreate.parse(["--dry-run", "--reminder-id", "task-1", "--title", "Review"])
        let (createStreams, createOut) = streams()
        try Output.withStreams(createStreams) {
            try create.run(storeFactory: { factoryCalls += 1; return fake })
        }
        #expect((try payload(from: createOut))["action"] as? String == "create")

        let update = try SubtasksUpdate.parse([
            "--dry-run",
            "--reminder-id", "task-1",
            "--subtask-id", existingId,
            "--title", "Review updated",
            "--completed",
        ])
        let (updateStreams, updateOut) = streams()
        try Output.withStreams(updateStreams) {
            try update.run(storeFactory: { factoryCalls += 1; return fake })
        }
        #expect((try payload(from: updateOut))["action"] as? String == "update")

        let toggle = try SubtasksToggle.parse(["--dry-run", "--reminder-id", "task-1", "--subtask-id", existingId])
        let (toggleStreams, toggleOut) = streams()
        try Output.withStreams(toggleStreams) {
            try toggle.run(storeFactory: { factoryCalls += 1; return fake })
        }
        #expect((try payload(from: toggleOut))["action"] as? String == "toggle")

        let delete = try SubtasksDelete.parse(["--dry-run", "--reminder-id", "task-1", "--subtask-id", existingId])
        let (deleteStreams, deleteOut) = streams()
        try Output.withStreams(deleteStreams) {
            try delete.run(storeFactory: { factoryCalls += 1; return fake })
        }
        #expect((try payload(from: deleteOut))["action"] as? String == "delete")
        #expect(factoryCalls == 0)
        #expect(fake.requestedAccess.isEmpty)
        #expect(fake.savedReminders.isEmpty)
        // Subtasks live in the parent's notes, so an in-memory mutation without a save would
        // still be a real edit to the fetched object — the notes must be byte-identical.
        #expect(row.notes == notesBefore)
    }

    @Test("reminders doctor health builder reports ready and blocked states")
    func remindersDoctorHealthBuilder() {
        let ready = RemindersDoctor.Health.build(
            remStatus: .authorized,
            calStatus: .denied,
            fullDiskAccess: true,
            notes: ["synthetic preflight note"])
        #expect(ready.reminders_ready)
        #expect(ready.notes == ["synthetic preflight note"])

        let blocked = RemindersDoctor.Health.build(
            remStatus: .denied,
            calStatus: .fullAccess,
            fullDiskAccess: false,
            notes: [])
        #expect(!blocked.reminders_ready)
        #expect(blocked.notes.count == 1)
    }

    @Test("reminders doctor run emits the injected authorization and preflight states")
    func remindersDoctorRun() throws {
        // Injected stand-ins only — the real `run()` would read host TCC status and open a
        // TCC-protected path via `Permissions.preflight()`, neither of which belongs in the
        // logic tier.
        let command = try RemindersDoctor.parse([])

        let (blockedStreams, blockedOut) = streams()
        var probed: [EventStore.Entity] = []
        try Output.withStreams(blockedStreams) {
            try command.run(
                authorizationStatus: { entity in
                    probed.append(entity)
                    return entity == .reminder ? .notDetermined : .denied
                },
                preflight: { Permissions.Preflight(full_disk_access: false,
                                                   notes: ["synthetic preflight note"]) })
        }
        let blocked = try payload(from: blockedOut)
        #expect(blocked["reminders_authorization"] as? String == "not_determined")
        #expect(blocked["calendar_authorization"] as? String == "denied")
        #expect(blocked["reminders_ready"] as? Bool == false)
        #expect(blocked["full_disk_access"] as? Bool == false)
        let blockedNotes = try #require(blocked["notes"] as? [String])
        #expect(blockedNotes.first == "synthetic preflight note")
        #expect(blockedNotes.count == 2)   // preflight note + the not-ready note
        #expect(probed == [.reminder, .event])

        let (readyStreams, readyOut) = streams()
        try Output.withStreams(readyStreams) {
            try command.run(authorizationStatus: { _ in .fullAccess },
                            preflight: { Permissions.Preflight(full_disk_access: true) })
        }
        let ready = try payload(from: readyOut)
        #expect(ready["reminders_authorization"] as? String == "full_access")
        #expect(ready["reminders_ready"] as? Bool == true)
        #expect(ready["full_disk_access"] as? Bool == true)
        #expect((ready["notes"] as? [String])?.isEmpty == true)
    }

    @Test("reminder list commands report validation and not-found branches with exact codes/types")
    func listErrorBranches() throws {
        let fake = FakeReminderStore()
        let invalidColor = try ListsCreate.parse(["--name", "apple-cli-test bad", "--color", "purple"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try invalidColor.run(storeFactory: { fake })
        }

        // Nothing to update is BAD INPUT (64) — distinct from the missing-list 404 below, and
        // the two are the branches most likely to be transposed.
        let emptyUpdate = try ListsUpdate.parse(["--name", "apple-cli-test list"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try emptyUpdate.run(storeFactory: { fake })
        }

        let badUpdateColor = try ListsUpdate.parse([
            "--name", "apple-cli-test list", "--color", "#GGGGGG",
        ])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try badUpdateColor.run(storeFactory: { fake })
        }

        let missingUpdate = try ListsUpdate.parse(["--name", "missing", "--new-name", "apple-cli-test new"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try missingUpdate.run(storeFactory: { fake })
        }

        let missingDelete = try ListsDelete.parse(["--name", "missing"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try missingDelete.run(storeFactory: { fake })
        }

        #expect(fake.savedLists.isEmpty)
        #expect(fake.removedLists.isEmpty)
    }

    @Test("reminder task commands report validation and not-found branches with exact codes/types")
    func taskErrorBranches() throws {
        let fake = FakeReminderStore()
        let missingRead = try TasksRead.parse(["--id", "missing"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try missingRead.run(storeFactory: { fake })
        }

        let badDueWithin = try TasksRead.parse(["--due-within", "next-century"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try badDueWithin.run(storeFactory: { fake })
        }

        let badFilterPriority = try TasksRead.parse(["--filter-priority", "urgent"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try badFilterPriority.run(storeFactory: { fake })
        }

        let emptyTitle = try TasksCreate.parse(["--title", "   "])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try emptyTitle.run(storeFactory: { fake })
        }

        // A NAMED but unknown destination list is a 404, not a validation error — the create
        // path resolves it only after the write gate, so this also proves the gate was passed.
        let missingListCreate = try TasksCreate.parse([
            "--title", "apple-cli-test missing list",
            "--target-list", "missing",
        ])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try missingListCreate.run(storeFactory: { fake })
        }

        let invalidPriorityUpdate = try TasksUpdate.parse(["--id", "task-1", "--priority", "urgent"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try invalidPriorityUpdate.run(storeFactory: { fake })
        }

        let conflictingClear = try TasksUpdate.parse(["--id", "task-1", "--clear-due", "--due", "2026-07-16"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try conflictingClear.run(storeFactory: { fake })
        }

        // Valid flags, unknown id: the by-id fetch 404s (65), NOT 64 — the pairing that
        // `throws: ExitCode.self` alone could never distinguish.
        let missingUpdate = try TasksUpdate.parse(["--id", "missing", "--title", "apple-cli-test renamed"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try missingUpdate.run(storeFactory: { fake })
        }

        let missingDelete = try TasksDelete.parse(["--id", "missing"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try missingDelete.run(storeFactory: { fake })
        }

        #expect(fake.savedReminders.isEmpty)
        #expect(fake.removedReminders.isEmpty)
    }

    @Test("subtask commands report missing reminder and bad reorder branches with exact codes/types")
    func subtaskErrorBranches() throws {
        let fake = FakeReminderStore()
        let missingRead = try SubtasksRead.parse(["--reminder-id", "missing"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try missingRead.run(storeFactory: { fake })
        }

        let row = reminder(list: fake.lists[0], store: fake.ekStore)
        fake.remindersById["task-1"] = row

        // MEASURED, and the pair is the point — `ReminderSubtasks.reorder` has TWO adjacent
        // failure modes with DIFFERENT contractual codes, and `throws: ExitCode.self` alone
        // cannot tell them apart. An id in `--order` that no subtask carries is a 404 …
        let badReorder = try SubtasksReorder.parse(["--reminder-id", "task-1", "--order", "bbbb2222"])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try badReorder.run(storeFactory: { fake })
        }

        // … while an order that omits an EXISTING subtask is bad input (64): reorder is
        // total, not a partial permutation.
        let twoSubtasks = reminder(list: fake.lists[0], store: fake.ekStore)
        twoSubtasks.notes = "[#work] synthetic\n\n---SUBTASKS---\n"
            + "[ ] {aaaa1111} Draft\n[ ] {cccc3333} Review\n---END SUBTASKS---"
        fake.remindersById["task-2"] = twoSubtasks
        #expect(ReminderSubtasks.parse(twoSubtasks.notes).count == 2)   // fixture premise
        let partialReorder = try SubtasksReorder.parse(["--reminder-id", "task-2", "--order", "cccc3333"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try partialReorder.run(storeFactory: { fake })
        }

        let emptyReorder = try SubtasksReorder.parse(["--reminder-id", "task-1"])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try emptyReorder.run(storeFactory: { fake })
        }

        // A malformed subtask id is rejected BEFORE the store is opened (id-shape validation
        // precedes the write gate), so this also pins that ordering.
        let badId = try SubtasksUpdate.parse([
            "--reminder-id", "task-1", "--subtask-id", "not-an-id", "--title", "Review",
        ])
        try expectFailure(exit: AppleExit.usage, type: AppleErrorType.validation) {
            try badId.run(storeFactory: { fake })
        }

        let missingSubtask = try SubtasksDelete.parse([
            "--reminder-id", "task-1", "--subtask-id", "bbbb2222",
        ])
        try expectFailure(exit: AppleExit.notFound, type: AppleErrorType.notFound) {
            try missingSubtask.run(storeFactory: { fake })
        }

        #expect(fake.savedReminders.isEmpty)
    }
}
