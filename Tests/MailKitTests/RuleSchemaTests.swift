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

    @Test func liveActionTokensAllowsOnlyMarkVerbs() throws {
        #expect(try RuleLiveGuards.liveActionTokens(RuleSchema.parseActions(["mark_read=true"])) == ["mark_read"])
        #expect(try RuleLiveGuards.liveActionTokens(RuleSchema.parseActions(["mark_flagged=true", "mark_read=true"])).sorted()
                == ["mark_flagged", "mark_read"])
    }

    @Test func liveActionTokensRefusesDestructiveAndUnwired() throws {
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionTokens(RuleSchema.parseActions(["forward_to=a@x.io"])) }
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionTokens(RuleSchema.parseActions(["delete=true"])) }
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionTokens(RuleSchema.parseActions(["move_to=Archive"])) }
        #expect(throws: Error.self) { _ = try RuleLiveGuards.liveActionTokens(RuleSchema.parseActions(["flag_color=red"])) }
    }
}
