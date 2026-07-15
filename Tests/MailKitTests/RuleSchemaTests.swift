import Testing
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
