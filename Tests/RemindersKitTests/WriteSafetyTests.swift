import Testing
import Foundation
import EventKit
@testable import RemindersKit
import EventKitCore
import AppleKit

// Write-safety + read-enrichment tests. These use in-memory EKReminder objects (constructing an
// EKEventStore / EKReminder does NOT touch the store or trigger TCC — authorization is only
// requested on data ACCESS), so they run in the pure logic tier with no permissions.

// MARK: - Write-safety label guard (regression guard for the tasks update/delete fix)

@Suite("Write-safety: requireLabeledReminder")
struct LabelGuardTests {
    @Test func isLabeledPredicate() {
        #expect(LabelGuard.isLabeled("apple-cli-test-x") == true)
        #expect(LabelGuard.isLabeled("apple-cli-test") == true)
        #expect(LabelGuard.isLabeled("Buy groceries") == false)
        #expect(LabelGuard.isLabeled(nil) == false)
        #expect(LabelGuard.isLabeled("") == false)
    }

    func reminder(titled title: String?) -> EKReminder {
        let r = EKReminder(eventStore: EKEventStore())
        r.title = title
        return r
    }

    // THE regression guard: a live tasks update/delete mutates an existing reminder fetched by
    // opaque id; the write guard's labeledName can't vet that target, so requireLabeledReminder
    // (called post-fetch by both tasks update and tasks delete) MUST refuse a non-labeled target.
    @Test func refusesUnlabeledExistingTarget() {
        #expect(throws: AppleError.self) { try requireLabeledReminder(reminder(titled: "Real Reminder")) }
        #expect(throws: AppleError.self) { try requireLabeledReminder(reminder(titled: nil)) }
        #expect(throws: AppleError.self) { try requireLabeledReminder(reminder(titled: "almost-apple-cli-test")) }
    }

    @Test func allowsLabeledTestTarget() {
        #expect(throws: Never.self) { try requireLabeledReminder(reminder(titled: "apple-cli-test-groceries")) }
    }
}

// MARK: - ReminderRead.enrich (tags + subtasks + progress surfaced on read)

@Suite("ReminderRead.enrich surfaces tags + subtasks")
struct EnrichTests {
    @Test func populatesTagsAndSubtasksFromNotes() {
        let notes = "[#work] [#urgent] body\n\n---SUBTASKS---\n[ ] {aaaa1111} A\n[x] {bbbb2222} B\n---END SUBTASKS---"
        let base = Reminder(id: "R1", notes: notes, completed: false, priority: 0, has_recurrence: false)
        let enriched = ReminderRead.enrich(base)
        #expect(enriched.tags == ["work", "urgent"])
        #expect(enriched.subtasks?.count == 2)
        #expect(enriched.subtasks?[0].id == "aaaa1111")
        #expect(enriched.subtasks?[0].completed == false)
        #expect(enriched.subtasks?[1].completed == true)
        #expect(enriched.subtask_progress?.completed == 1)
        #expect(enriched.subtask_progress?.total == 2)
        #expect(enriched.subtask_progress?.percentage == 50)
    }

    @Test func noEnrichmentWhenNotesPlain() {
        let base = Reminder(id: "R1", notes: "just a plain note", completed: false, priority: 0, has_recurrence: false)
        let enriched = ReminderRead.enrich(base)
        #expect(enriched.tags == nil)
        #expect(enriched.subtasks == nil)
        #expect(enriched.subtask_progress == nil)
    }

    @Test func enrichedReminderEmitsSubtasksInJson() throws {
        let notes = "---SUBTASKS---\n[ ] {aaaa1111} A\n---END SUBTASKS---"
        let base = Reminder(id: "R1", notes: notes, completed: false, priority: 0, has_recurrence: false)
        let s = String(data: try Output.encodeSuccess(tool: "reminders", data: ReminderRead.enrich(base)), encoding: .utf8)!
        #expect(s.contains("\"subtasks\""))
        #expect(s.contains("\"subtask_progress\""))
        #expect(s.contains("aaaa1111"))
    }
}
