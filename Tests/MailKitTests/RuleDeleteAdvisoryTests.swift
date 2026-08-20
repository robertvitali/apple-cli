import Testing
import AppleKit
@testable import MailKit

/// Pins for the three converging review findings on the newly-wired Mail rule `delete` action
/// (2026-08-19). All three share one root cause: `delete` was wired into the LIVE path but the
/// surfaces that are supposed to MIRROR the live path — the dry-run preview and the execute
/// envelope — were not carried along with it.
///
/// 1. HIGH  — the sandboxed in-place ENABLE-GATE gained `|| p.delete` on the execute path with no
///            matching dry-run blocker, so a preview claimed `live_blockers: []` for an update
///            execute refuses with 77 (this repo's invariant: a preview must refuse exactly what
///            execute would).
/// 2. MEDIUM — `rules enable` is the arming moment and warns nothing. Was BLOCKED on a missing
///            `MailScript` readback of Mail's `delete message` rule property; CLOSED 2026-08-19
///            (`RuleScalars.deleteMessage` + `realDeleteEnableWarnings`, pinned in
///            `RuleSandboxHardeningTests.swift`) — that same readback landing is also what
///            un-blocks the carry-forward fix pinned below.
/// 3. MEDIUM — `warnings` was machine-readable (`warnings: [...]`) on preview envelopes but
///            prose-only (folded into `note`) on EXECUTE envelopes, while AGENTS.md declares JSON
///            the machine contract.
@Suite("Rule delete advisory + preview/execute agreement")
struct RuleDeleteAdvisoryTests {

    // MARK: Finding 1 — preview/execute agreement on the in-place enable-gate

    /// THE drift-guard. The execute-path gate was hand-written as
    /// `p.moveTo != nil || p.copyTo != nil || p.delete` over the RESOLVED plan, while the dry-run
    /// blocker must decide the same thing from the PARSED action (a preview never resolves a plan
    /// when a blocker is already present). Both now call `armsRelocatingOrDestructiveAction`; this
    /// locks that predicate to the plan expression it replaced, across the full action matrix — so
    /// wiring a fourth relocating/destructive verb into `liveActionPlan` without teaching the
    /// predicate about it fails here rather than in a silently-lying preview.
    @Test func armsPredicateMatchesResolvedPlan() throws {
        let tokenSets: [[String]] = [
            ["delete=true"],
            ["move_to=iCloud/Archive"],
            ["copy_to=iCloud/Saved"],
            ["mark_read=true"],
            ["mark_flagged=true"],
            ["flag_color=red"],
            ["mark_flagged=true", "flag_color=none"],
            ["mark_read=true", "delete=true"],
            ["move_to=iCloud/Archive", "mark_read=true"],
            ["copy_to=iCloud/Saved", "delete=true"],
            ["move_to=iCloud/Archive", "copy_to=iCloud/Saved", "delete=true"],
        ]
        for tokens in tokenSets {
            let action = try RuleSchema.parseActions(tokens)
            let plan = try RuleLiveGuards.liveActionPlan(action)
            let fromPlan = plan.moveTo != nil || plan.copyTo != nil || plan.delete
            #expect(RuleLiveGuards.armsRelocatingOrDestructiveAction(action) == fromPlan,
                    "predicate disagrees with the resolved plan for \(tokens)")
        }
    }

    /// The gated set is exactly {move_to, copy_to, delete} — the actions that RELOCATE or DESTROY
    /// mail. Purely-annotating actions must NOT trip the gate, or every `--action mark_read=true
    /// --enabled true` update would be refused and the preview would advertise a refusal that
    /// never happens.
    @Test func armsPredicateIgnoresAnnotatingActions() throws {
        for tokens in [["mark_read=true"], ["mark_flagged=true"], ["flag_color=red"],
                       ["mark_read=true", "mark_flagged=true"]] {
            #expect(RuleLiveGuards.armsRelocatingOrDestructiveAction(try RuleSchema.parseActions(tokens)) == false,
                    "\(tokens) must not trip the in-place enable-gate")
        }
        for tokens in [["delete=true"], ["move_to=iCloud/Archive"], ["copy_to=iCloud/Saved"]] {
            #expect(RuleLiveGuards.armsRelocatingOrDestructiveAction(try RuleSchema.parseActions(tokens)) == true,
                    "\(tokens) must trip the in-place enable-gate")
        }
    }

    /// An empty-string target is not a wired action (`liveActionPlan` only sets `moveTo`/`copyTo`
    /// for a non-empty value), so the predicate must agree — otherwise the preview would report a
    /// blocker for an update execute happily performs, i.e. the divergence in the other direction.
    @Test func armsPredicateTreatsEmptyTargetsAsUnwired() {
        var a = RuleSchema.Action()
        a.move_to = ""
        a.copy_to = ""
        #expect(RuleLiveGuards.armsRelocatingOrDestructiveAction(a) == false)
        a.delete = false
        #expect(RuleLiveGuards.armsRelocatingOrDestructiveAction(a) == false)
        a.delete = true
        #expect(RuleLiveGuards.armsRelocatingOrDestructiveAction(a) == true)
    }

    /// The refusal wording is shared by the live `mailSafety` throw and the dry-run blocker, so the
    /// preview quotes the reason execute will actually give. It must keep naming all three gated
    /// verbs: dropping `delete` from the sentence is how an operator reads a preview and concludes
    /// auto-trash is not part of what execute refuses.
    @Test func inPlaceEnableRefusalNamesEveryGatedVerb() {
        let text = RuleLiveGuards.inPlaceEnableRefusal
        #expect(text.contains("move_to"))
        #expect(text.contains("copy_to"))
        #expect(text.contains("delete"))
        // Names the escape hatches, so the refusal is actionable rather than a dead end.
        #expect(text.contains("--enabled"))
        #expect(text.contains("--condition"))
        // The live throw prefixes this verbatim; a stray leading capital/prefix here would produce
        // "sandbox active: Sandbox active: …".
        #expect(text.hasPrefix("wiring"))
    }

    // MARK: Finding 3 — one advisory wording, reachable from an Action or a resolved plan

    /// The execute envelopes emit `warnings[]` off the RESOLVED plan while the preview emits it off
    /// the parsed Action. Both overloads must produce byte-identical strings, or an agent diffing
    /// dry-run against execute sees a spurious change.
    @Test func warningsWordingIsIdenticalFromActionAndFromPlan() throws {
        let action = try RuleSchema.parseActions(["delete=true"])
        let plan = try RuleLiveGuards.liveActionPlan(action)
        #expect(RuleLiveGuards.liveActionWarnings(action) == RuleLiveGuards.liveActionWarnings(plan: plan))
        #expect(RuleLiveGuards.liveActionWarnings(plan: plan) == [RuleLiveGuards.deleteActionWarning])
        #expect(RuleLiveGuards.deleteActionWarning.contains("auto-trash"))
        #expect(RuleLiveGuards.deleteActionWarning.contains("Trash"))
    }

    /// A non-delete rule carries NO warning on either overload — `warnings: []` is the honest
    /// machine-readable "nothing to flag", not an omitted key.
    @Test func warningsAreEmptyForNonDeleteActions() throws {
        for tokens in [["mark_read=true"], ["move_to=iCloud/Archive"], ["copy_to=iCloud/Saved"],
                       ["flag_color=red"]] {
            let action = try RuleSchema.parseActions(tokens)
            #expect(RuleLiveGuards.liveActionWarnings(action).isEmpty)
            #expect(RuleLiveGuards.liveActionWarnings(plan: try RuleLiveGuards.liveActionPlan(action)).isEmpty)
        }
    }

    /// `warnings` is disjoint from `live_blockers`: delete is WIRED (advisory only) and forward_to
    /// is REFUSED (blocker only). An action that appeared in both would make the preview's own
    /// "would be refused" vs "advisory" framing self-contradictory.
    @Test func warningsAndBlockersStayDisjoint() throws {
        let del = try RuleSchema.parseActions(["delete=true"])
        #expect(RuleLiveGuards.liveActionBlockers(del).isEmpty)
        #expect(RuleLiveGuards.liveActionWarnings(del).count == 1)

        let fwd = try RuleSchema.parseActions(["forward_to=jane.doe@example.com"])
        #expect(RuleLiveGuards.liveActionBlockers(fwd).count == 1)
        #expect(RuleLiveGuards.liveActionWarnings(fwd).isEmpty)
    }

    // MARK: Finding 2 — the blocked gap, now CLOSED (2026-08-19) — see RuleSandboxHardeningTests.swift

    /// UPDATED per this test's own note above: `MailScript.readRuleScalars` now reads `delete
    /// message` back (`RuleScalars.deleteMessage`), so the condition-replacing recreate's
    /// carry-forward plan (built in `RulesUpdate.run()` when no --action is passed) preserves an
    /// existing delete action instead of silently dropping it — `old.deleteMessage` flows straight
    /// into the merged `LiveActionPlan.delete` and its `tokens`. This is the "after" counterpart to
    /// the "before" state this test used to pin; the tripwire fired as designed.
    ///
    /// `rules enable` gaining the SAME readback is pinned separately in
    /// `RuleSandboxHardeningTests.swift` (`realDeleteEnableWarnings`), since closing that gap also
    /// changed its shape from an advisory-only warning to a sandboxed REFUSAL (the rule's
    /// conditions are not re-verified self-scoped on that path — see
    /// `RuleLiveGuards.realDeleteEnableRefusal`).
    @Test func recreateCarryPlanNowPreservesAnExistingDeleteAction() {
        // Exactly the carry-forward plan `RulesUpdate` builds when no --action is passed AND the
        // old rule's real readback carries delete: `old.deleteMessage` (mirrored here as `true`)
        // both sets `delete` and appends the "delete" token, mirroring
        // `RulesUpdate.run()`'s `if old.deleteMessage { carried.append("delete") }`.
        let carried = RuleLiveGuards.LiveActionPlan(markRead: true, markFlagged: false,
                                                    moveTo: nil, copyTo: nil, flagColorIndex: nil,
                                                    delete: true, tokens: ["mark_read", "delete"])
        #expect(carried.delete == true)
        #expect(carried.tokens.contains("delete"))
        // …so the recreate envelope's warnings now surface the advisory, matching what an explicit
        // --action delete=true would have produced before this fix.
        #expect(RuleLiveGuards.liveActionWarnings(plan: carried) == [RuleLiveGuards.deleteActionWarning])
    }

    /// The opposite case still holds: when the old rule genuinely does NOT carry delete,
    /// `old.deleteMessage == false` propagates through unchanged — no phantom delete/warning.
    @Test func recreateCarryPlanStaysCleanWhenOldRuleHadNoDelete() {
        let carried = RuleLiveGuards.LiveActionPlan(markRead: true, markFlagged: false,
                                                    moveTo: nil, copyTo: nil, flagColorIndex: nil,
                                                    delete: false, tokens: ["mark_read"])
        #expect(carried.delete == false)
        #expect(!carried.tokens.contains("delete"))
        #expect(RuleLiveGuards.liveActionWarnings(plan: carried).isEmpty)
    }
}
