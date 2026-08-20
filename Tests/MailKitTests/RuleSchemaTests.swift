import Testing
import AppleKit
@testable import MailKit

@Suite("RuleSchema")
struct RuleSchemaTests {
    @Test func parsesValidCondition() throws {
        let c = try RuleSchema.parseCondition("from:contains:boss@x.io")
        #expect(c.field == "from")
        #expect(c.operator == "contains")
        #expect(c.value == "boss@x.io")
    }

    @Test func headerNameConditionRequiresHeader() throws {
        let c = try RuleSchema.parseCondition("header_name:equals:1:X-Priority")
        #expect(c.header_name == "X-Priority")
        #expect(throws: Error.self) { _ = try RuleSchema.parseCondition("header_name:equals:1") }
    }

    @Test func rejectsBadFieldOrOperator() {
        #expect(throws: Error.self) { _ = try RuleSchema.parseCondition("nope:contains:x") }
        #expect(throws: Error.self) { _ = try RuleSchema.parseCondition("from:matches:x") }
        #expect(throws: Error.self) { _ = try RuleSchema.parseCondition("from:contains") }
    }

    @Test func valueMayContainColons() throws {
        // A value with colons (subject "Re: Q3", a URL, a time) must survive verbatim.
        #expect(try RuleSchema.parseCondition("subject:contains:Re: Q3 sync").value == "Re: Q3 sync")
        #expect(try RuleSchema.parseCondition("body:contains:https://example.com/x").value == "https://example.com/x")
        #expect(try RuleSchema.parseCondition("subject:equals:9:00 AM").value == "9:00 AM")
    }

    @Test func headerNameTakesFinalColonSegment() throws {
        // header_name:op:value:HEADER — value keeps interior colons; header is the last segment.
        let c = try RuleSchema.parseCondition("header_name:contains:a:b:X-Spam")
        #expect(c.value == "a:b")
        #expect(c.header_name == "X-Spam")
    }

    @Test func allOperatorsAccepted() throws {
        for op in RuleSchema.conditionOperators {
            #expect(try RuleSchema.parseCondition("subject:\(op):x").operator == op)
        }
    }

    @Test func parsesActions() throws {
        let a = try RuleSchema.parseActions(["move_to=Gmail/Archive", "mark_read=true", "flag_color=red", "forward_to=a@x.io,b@y.io"])
        #expect(a.move_to == "Gmail/Archive")
        #expect(a.mark_read == true)
        #expect(a.flag_color == "red")
        #expect(a.forward_to == ["a@x.io", "b@y.io"])
    }

    @Test func refusesUnsupportedActions() {
        // The update_rule unsupported-action refusal (run-AppleScript/redirect/reply/sound/color).
        #expect(throws: Error.self) { _ = try RuleSchema.parseActions(["run_applescript=/x.scpt"]) }
        #expect(throws: Error.self) { _ = try RuleSchema.parseActions(["redirect=a@x.io"]) }
        #expect(throws: Error.self) { _ = try RuleSchema.parseActions(["reply=hi"]) }
    }

    @Test func rejectsEmptyActionsAndBadColor() {
        #expect(throws: Error.self) { _ = try RuleSchema.parseActions([]) }
        #expect(throws: Error.self) { _ = try RuleSchema.parseActions(["flag_color=chartreuse"]) }
        #expect(throws: Error.self) { _ = try RuleSchema.parseActions(["notakey=1"]) }
    }
}

/// The live create/update safety invariant (`rules create` + `rules update` both route through it).
/// Pure — no Mail.app. Locks that a live-authored rule can only ever be a self-scoped, non-destructive
/// test rule, so the AppleScript path can never be handed a rule that would act on real mail.
@Suite("RuleLiveGuards (live rule safety invariant)")
struct RuleLiveGuardsTests {
    let label = TestMode.sandboxPrefix

    @Test func labeledNameGate() throws {
        try RuleLiveGuards.requireLabeledName(label + "-rule")            // labeled → passes
        #expect(throws: Error.self) { try RuleLiveGuards.requireLabeledName("real-inbox-rule") }
    }

    @Test func controlCharGate() throws {
        #expect(throws: Error.self) { try RuleLiveGuards.requireNoControlChars(name: "x\u{1f}y", conditions: []) }
        let clean = try RuleSchema.parseCondition("subject:contains:\(label)")
        try RuleLiveGuards.requireNoControlChars(name: label, conditions: [clean])   // clean → passes
    }

    @Test func selfScopedRequiresMatchAllAndLabelCondition() throws {
        let labeled = try RuleSchema.parseCondition("subject:contains:\(label)")
        let unlabeled = try RuleSchema.parseCondition("from:contains:boss@x.io")
        #expect(throws: Error.self) { try RuleLiveGuards.requireSelfScoped(conditions: [labeled], match: "any") }    // any → refused
        #expect(throws: Error.self) { try RuleLiveGuards.requireSelfScoped(conditions: [unlabeled], match: "all") }  // no label cond → refused
        try RuleLiveGuards.requireSelfScoped(conditions: [labeled, unlabeled], match: "all")                         // labeled+all → passes
    }

    /// header_name is now WIRED for live mutation (Mail.sdef RuleType `header key` + the rule
    /// condition's `header` property), so it is no longer refused — it used to be blocked only
    /// because the AppleScript could not express it. The self-scoping invariant is what keeps it
    /// safe: the rule is still an AND-rule carrying the test-label subject condition, so a header
    /// condition can only NARROW what it matches, never widen it.
    @Test func selfScopedAllowsHeaderNameAlongsideTheLabelCondition() throws {
        let labeled = try RuleSchema.parseCondition("subject:contains:\(label)")
        let hdr = try RuleSchema.parseCondition("header_name:contains:x:X-Test")
        try RuleLiveGuards.requireSelfScoped(conditions: [labeled, hdr], match: "all")
        // ...but a header condition does NOT substitute for the label condition.
        #expect(throws: Error.self) { try RuleLiveGuards.requireSelfScoped(conditions: [hdr], match: "all") }
        // ...and it does not unlock an OR-rule, where the label would stop constraining.
        #expect(throws: Error.self) { try RuleLiveGuards.requireSelfScoped(conditions: [labeled, hdr], match: "any") }
    }

    /// Previews describe what the live path would refuse rather than refusing outright, so
    /// `liveActionBlockers` must name exactly the actions `liveActionPlan` throws on. `delete` is
    /// live-wired (operator-ruled full parity, 2026-08-19) so it is no longer a blocker — it now
    /// carries an advisory `liveActionWarnings` entry instead (locked separately below).
    @Test func liveActionBlockersMatchWhatLiveActionPlanRefuses() throws {
        let fwd = try RuleSchema.parseActions(["forward_to=x@y.test"])
        #expect(RuleLiveGuards.liveActionBlockers(fwd).count == 1)
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionPlan(fwd) }

        let del = try RuleSchema.parseActions(["delete=true"])
        #expect(RuleLiveGuards.liveActionBlockers(del).isEmpty)
        _ = try RuleLiveGuards.liveActionPlan(del)

        // A supported action has no blockers and plans cleanly — the two must not disagree.
        let ok = try RuleSchema.parseActions(["mark_read=true"])
        #expect(RuleLiveGuards.liveActionBlockers(ok).isEmpty)
        _ = try RuleLiveGuards.liveActionPlan(ok)
    }

    @Test func liveActionPlanCapturesMarkVerbs() throws {
        let p1 = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["mark_read=true"]))
        #expect(p1.markRead == true && p1.markFlagged == false && p1.moveTo == nil)
        let p2 = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["mark_flagged=true", "mark_read=true"]))
        #expect(p2.markRead == true && p2.markFlagged == true)
    }

    @Test func liveActionPlanWiresMoveCopyFlagColor() throws {
        // move_to/copy_to/flag_color are NOW live-wired (were previously refused).
        let mv = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["move_to=iCloud/Archive"]))
        #expect(mv.moveTo == "iCloud/Archive")
        let cp = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["copy_to=iCloud/Saved"]))
        #expect(cp.copyTo == "iCloud/Saved")
        let fc = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["flag_color=red"]))
        #expect(fc.flagColorIndex == MailFlagColor.red.rawValue && fc.markFlagged == true)
        // move_to/copy_to must carry an Account/Mailbox path (need a resolvable target).
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["move_to=Archive"])) }
    }

    @Test func liveActionPlanFlagColorNoneHandling() throws {
        // flag_color=none resolves to NO index; a paired mark_flagged must still yield a valid plan
        // (the token is gated on the resolved index, not on flag_color-token presence).
        let p = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["mark_flagged=true", "flag_color=none"]))
        #expect(p.markFlagged == true && p.flagColorIndex == nil && p.tokens.contains("mark_flagged"))
        // flag_color=none as the SOLE action is not a real action → refused.
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["flag_color=none"])) }
    }

    @Test func liveActionPlanRefusesForward() throws {
        // forward_to (auto-send to others) remains refused — latent exfil surface.
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["forward_to=a@x.io"])) }
    }

    /// delete (auto-trash) is now LIVE-WIRED (operator-ruled full parity with oracle A,
    /// 2026-08-19): a rule may carry `delete` and `liveActionPlan` must not throw on it, must
    /// mark `plan.delete == true`, and must emit a `"delete"` token (consumed by
    /// `MailScript.createRule`/`updateRuleMeta` to set Mail.sdef's `delete message` property). The
    /// action stays advisory-flagged (not blocked) via `liveActionWarnings`.
    @Test func liveActionPlanWiresDelete() throws {
        let plan = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["delete=true"]))
        #expect(plan.delete == true)
        #expect(plan.tokens.contains("delete"))

        let warnings = RuleLiveGuards.liveActionWarnings(try RuleSchema.parseActions(["delete=true"]))
        #expect(warnings.count == 1)
        #expect(RuleLiveGuards.liveActionWarnings(try RuleSchema.parseActions(["mark_read=true"])).isEmpty)

        // delete=false is not a real action — same "at least one action" refusal as any empty set.
        var noDelete = RuleSchema.Action()
        noDelete.delete = false
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionPlan(noDelete) }
    }
}

/// header_name became the 4th US-delimited field of each RS-delimited condition record, so it
/// needs the same control-character guard `value` has. A header name carrying US/RS would shift
/// every following field by one and build a differently-typed condition on attacker-chosen text.
/// `parseCondition` takes the header from the FINAL colon-segment of user input, so this is
/// reachable straight from the command line.
@Suite("Rule condition delimiter integrity")
struct RuleConditionDelimiterTests {
    private let US = "\u{1F}"
    private let RS = "\u{1E}"

    @Test func headerNameWithDelimitersIsRejected() throws {
        for ctl in [US, RS] {
            let c = RuleSchema.Condition(field: "header_name", operator: "contains",
                                         value: "v", header_name: "X-Bad\(ctl)injected")
            #expect(throws: Error.self) {
                try RuleLiveGuards.requireNoControlChars(name: nil, conditions: [c])
            }
        }
    }

    @Test func aCleanHeaderNamePasses() throws {
        let c = RuleSchema.Condition(field: "header_name", operator: "contains",
                                     value: "spam", header_name: "X-Spam-Flag")
        try RuleLiveGuards.requireNoControlChars(name: nil, conditions: [c])
    }

    /// The pre-existing guards must not have regressed while adding the new one.
    @Test func valueAndNameGuardsStillApply() throws {
        let badValue = RuleSchema.Condition(field: "subject", operator: "contains",
                                            value: "a\(US)b", header_name: nil)
        #expect(throws: Error.self) { try RuleLiveGuards.requireNoControlChars(name: nil, conditions: [badValue]) }
        #expect(throws: Error.self) { try RuleLiveGuards.requireNoControlChars(name: "r\(RS)x", conditions: []) }
    }
}

/// A preview must report EVERY refusal the live path would raise. The update preview once
/// dropped the self-scoping refusal entirely — printing `live_blockers: []`, an affirmative claim
/// that execute would accept a rule execute actually refuses with exit 77. These lock the
/// predicate the preview and the execute path now share.
@Suite("Preview/execute refusal parity")
struct PreviewRefusalParityTests {
    private let label = TestMode.canonicalSandboxPrefix

    @Test func isSelfScopedMatchesWhatRequireSelfScopedThrowsOn() throws {
        let labeled = try RuleSchema.parseCondition("subject:contains:\(label)-x")
        let unlabeled = try RuleSchema.parseCondition("from:contains:boss@example.com")

        // Agreement in BOTH directions is the point: the preview predicate must be true exactly
        // when the execute check passes.
        #expect(RuleLiveGuards.isSelfScoped([labeled, unlabeled]))
        try RuleLiveGuards.requireSelfScoped(conditions: [labeled, unlabeled], match: "all")

        #expect(RuleLiveGuards.isSelfScoped([unlabeled]) == false)
        #expect(throws: Error.self) { try RuleLiveGuards.requireSelfScoped(conditions: [unlabeled], match: "all") }

        #expect(RuleLiveGuards.isSelfScoped([]) == false)
    }

    /// Only subject conditions with a containment-style operator bind the label; a label appearing
    /// in some OTHER field must not count as self-scoping.
    @Test func onlySubjectContainmentConditionsCountAsSelfScoping() throws {
        let inSender = try RuleSchema.parseCondition("from:contains:\(label)@x.io")
        #expect(RuleLiveGuards.isSelfScoped([inSender]) == false)
        let wrongOp = try RuleSchema.parseCondition("subject:does_not_contain:\(label)")
        #expect(RuleLiveGuards.isSelfScoped([wrongOp]) == false)
    }

    /// Oracle A rejects an empty condition value; an empty `contains` matches EVERY message.
    /// The header_name grammar is the tricky case — the value only becomes empty AFTER the
    /// header is peeled off the final colon-segment.
    @Test func emptyConditionValueIsRejectedIncludingAfterTheHeaderSplit() {
        #expect(throws: Error.self) { _ = try RuleSchema.parseCondition("subject:contains:") }
        #expect(throws: Error.self) { _ = try RuleSchema.parseCondition("subject:contains:   ") }
        #expect(throws: Error.self) { _ = try RuleSchema.parseCondition("header_name:contains::X-Foo") }
        // A real value with a colon in it still survives verbatim.
        let ok = try? RuleSchema.parseCondition("subject:contains:Re: Q3")
        #expect(ok?.value == "Re: Q3")
        let hdr = try? RuleSchema.parseCondition("header_name:contains:9:00:X-When")
        #expect(hdr?.value == "9:00" && hdr?.header_name == "X-When")
    }
}
