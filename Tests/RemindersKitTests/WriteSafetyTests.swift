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
    // opaque id, which no argv check can vet — so requireLabeledReminder (called post-fetch by
    // tasks update/delete and every subtask op) MUST refuse a non-labeled target IN THE SANDBOX.
    @Test func refusesUnlabeledExistingTargetInSandbox() {
        let p = TestMode.canonicalSandboxPrefix
        #expect(throws: AppleError.self) {
            try requireLabeledReminder(reminder(titled: "Real Reminder"), sandboxActive: true, prefix: p)
        }
        #expect(throws: AppleError.self) {
            try requireLabeledReminder(reminder(titled: nil), sandboxActive: true, prefix: p)
        }
        #expect(throws: AppleError.self) {
            try requireLabeledReminder(reminder(titled: "almost-\(p)"), sandboxActive: true, prefix: p)
        }
    }

    @Test func allowsLabeledTestTarget() {
        let p = TestMode.canonicalSandboxPrefix
        #expect(throws: Never.self) {
            try requireLabeledReminder(reminder(titled: "\(p)-groceries"), sandboxActive: true, prefix: p)
        }
    }

    // LIFT PIN: outside the sandbox the post-fetch check is a no-op — that IS write-model v2 (the
    // oracle's `reminders_tasks action=delete` removes any reminder by id on call). A throw here
    // means the v1 gate was silently reinstated.
    @Test func unsandboxedIsANoOp() {
        let p = TestMode.canonicalSandboxPrefix
        for title: String? in ["Real Reminder", nil, "almost-\(p)"] {
            #expect(throws: Never.self) {
                try requireLabeledReminder(reminder(titled: title), sandboxActive: false, prefix: p)
            }
        }
    }
}

// MARK: - Write-model v2 posture (docs/write-model-v2.md)

/// Pins the v2 DECISION `ReminderWriteGuard.resolve` makes. The bats tier cannot assert "a flagless
/// `reminders tasks create` executes" without writing to the operator's real Reminders store, and
/// the AppleKit core tier only proves the precedence chain — not that THIS domain opted in. A
/// silent revert to dry-run-by-default fails here and only here.
@Suite("Reminders write-model v2 posture")
struct RemindersWriteModelV2Tests {
    func opts(_ args: [String]) throws -> GlobalOptions { try GlobalOptions.parse(args) }

    @Test("the test environment is clean (precondition for every pin below)")
    func cleanEnvironment() {
        let env = ProcessInfo.processInfo.environment
        #expect(env["APPLE_TEST_MODE"] == nil || env["APPLE_TEST_MODE"]!.isEmpty)
        #expect(env["APPLE_DRY_RUN"] == nil || env["APPLE_DRY_RUN"]!.isEmpty)
    }

    @Test("DEFAULT PIN: a flagless reminders write EXECUTES and is unsandboxed")
    func defaultsToExecute() throws {
        let gate = try ReminderWriteGuard.resolve(opts([]))
        #expect(gate.willExecute == true)
        #expect(gate.sandboxActive == false)
    }

    @Test("--dry-run previews; --execute is redundant; --dry-run wins over --execute")
    func dryRunPrecedence() throws {
        #expect(try ReminderWriteGuard.resolve(opts(["--dry-run"])).willExecute == false)
        #expect(try ReminderWriteGuard.resolve(opts(["--execute"])).willExecute == true)
        #expect(try ReminderWriteGuard.resolve(opts(["--dry-run", "--execute"])).willExecute == false)
    }

    @Test("--test-mode alone engages the sandbox without forcing a preview")
    func flagEngagesSandbox() throws {
        let gate = try ReminderWriteGuard.resolve(opts(["--test-mode"]))
        #expect(gate.sandboxActive == true)
        #expect(gate.willExecute == true)
    }

    /// Pinned via the `prefix:` seam — see CalendarWriteModelV2Tests for the env-race rationale.
    @Test("LIFT PIN: the argv label gate applies ONLY inside the sandbox")
    func labelGateIsSandboxOnly() throws {
        let p = TestMode.canonicalSandboxPrefix
        #expect(throws: Never.self) {
            try ReminderWriteGuard.requireLabeled("Groceries", what: "list", sandboxActive: false, prefix: p)
        }
        #expect(throws: AppleError.self) {
            try ReminderWriteGuard.requireLabeled("Groceries", what: "list", sandboxActive: true, prefix: p)
        }
        #expect(throws: Never.self) {
            try ReminderWriteGuard.requireLabeled("\(p) list", what: "list", sandboxActive: true, prefix: p)
        }
        // nil means "the caller had no such name" — never a refusal, in either posture.
        #expect(throws: Never.self) {
            try ReminderWriteGuard.requireLabeled(nil, what: "list", sandboxActive: true, prefix: p)
        }
    }

    /// DESTINATION PIN: the Notes flip shipped a bug where `move --folder` never label-checked its
    /// destination while `batch-move` did, so a sandboxed write landed in a REAL folder. The
    /// equivalent Reminders surfaces are `--new-name` (list rename) and the rename target.
    @Test("DESTINATION PIN: an unlabeled destination is refused inside the sandbox")
    func destinationIsChecked() throws {
        let p = TestMode.canonicalSandboxPrefix
        for what in ["destination list", "new list name", "new reminder title"] {
            #expect(throws: AppleError.self) {
                try ReminderWriteGuard.requireLabeled("Real Destination", what: what,
                                                      sandboxActive: true, prefix: p)
            }
            // The refusal message must name WHICH field was rejected, or a caller with several
            // labeled-name arguments cannot tell which one to fix.
            do {
                try ReminderWriteGuard.requireLabeled("Real Destination", what: what,
                                                      sandboxActive: true, prefix: p)
                Issue.record("expected a refusal for \(what)")
            } catch let e as AppleError {
                #expect(String(describing: e).contains(what))
            }
        }
    }

    /// ID-DESTINATION PIN (review finding). `--target-list` documents "name **or** id" and
    /// `EventStore.calendar(matching:)` resolves id-first, so a raw argv label test on it was
    /// WRONG: a labeled list's opaque identifier does not carry the prefix, and the first version
    /// of this flip refused it — breaking the flow the repo's own conduct rules prescribe
    /// (`lists create` hands back an id; TEST-CLEANUP.md tracks BY id). A labeled NAME is accepted
    /// outright; anything else DEFERS to the resolved title rather than refusing on sight.
    @Test("a labeled name is settled from argv; an id defers instead of being refused")
    func destinationIdDefersRatherThanRefusing() {
        let p = TestMode.canonicalSandboxPrefix
        // A labeled name is settled here — nothing to defer.
        #expect(ReminderWriteGuard.destinationCheckDeferred("\(p) list", sandboxActive: true, prefix: p) == false)
        // An opaque EventKit identifier is NOT refused; it is deferred to post-resolution.
        let ekId = "x-apple-calendar://ABCD-1234-EF56"
        #expect(ReminderWriteGuard.destinationCheckDeferred(ekId, sandboxActive: true, prefix: p) == true)
        // A real list NAME also defers — the post-resolution check is what refuses it, and it does.
        #expect(ReminderWriteGuard.destinationCheckDeferred("Groceries", sandboxActive: true, prefix: p) == true)
        // No destination given, and unsandboxed: nothing to defer in either case.
        #expect(ReminderWriteGuard.destinationCheckDeferred(nil, sandboxActive: true, prefix: p) == false)
        #expect(ReminderWriteGuard.destinationCheckDeferred("Groceries", sandboxActive: false, prefix: p) == false)
    }

    /// The deferral is only safe because something downstream actually refuses. This pins the
    /// post-resolution half — without it, `destinationCheckDeferred` would be a hole, not a defer.
    @Test("the post-resolution destination check refuses an unlabeled resolved list")
    func postResolutionDestinationRefuses() {
        let p = TestMode.canonicalSandboxPrefix
        func list(titled t: String) -> EKCalendar {
            let c = EKCalendar(for: .reminder, eventStore: EKEventStore())
            c.title = t
            return c
        }
        #expect(throws: AppleError.self) {
            try requireLabeledDestinationList(list(titled: "Groceries"), sandboxActive: true, prefix: p)
        }
        #expect(throws: Never.self) {
            try requireLabeledDestinationList(list(titled: "\(p) list"), sandboxActive: true, prefix: p)
        }
        // Unsandboxed it is a no-op, per write-model v2.
        #expect(throws: Never.self) {
            try requireLabeledDestinationList(list(titled: "Groceries"), sandboxActive: false, prefix: p)
        }
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
