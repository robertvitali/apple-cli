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

    @Test func selfScopedRejectsHeaderNameCondition() throws {
        let labeled = try RuleSchema.parseCondition("subject:contains:\(label)")
        let hdr = try RuleSchema.parseCondition("header_name:contains:x:X-Test")
        #expect(throws: Error.self) { try RuleLiveGuards.requireSelfScoped(conditions: [labeled, hdr], match: "all") }
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

    @Test func liveActionPlanRefusesForwardAndDelete() throws {
        // forward_to (auto-send) + delete (auto-trash) remain refused — latent exfil/destructive.
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["forward_to=a@x.io"])) }
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionPlan(RuleSchema.parseActions(["delete=true"])) }
    }
}
