import Testing
import Foundation
@testable import RemindersKit
import EventKitCore
import AppleKit

// Pure logic tests for the Reminders domain — no EKEventStore, no TCC. Cover priority parsing,
// dueWithin windows, the notes-field tag + subtask model (parity with the apple-events MCP
// tagUtils.ts / subtaskUtils.ts), the update notes-rebuild, alarm/recurrence spec parsing, and
// the write-preview envelope shapes.

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
