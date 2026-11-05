import AppleKit
import Testing
@testable import MessagesKit

@Suite("Conversation creation request planning")
struct MessagesConversationPlanTests {
    private func gate(execute: Bool = false, sandbox: Bool = false,
                      prefix: String = "apple-cli-test", allowed: [String] = []) -> MessagesWriteGuard.Gate {
        .init(willExecute: execute, sandboxActive: sandbox, sandboxPrefix: prefix, allowedRecipients: allowed)
    }

    @Test(arguments: [false, true])
    func preservesInitialTextAndCapturedPosture(_ execute: Bool) throws {
        let text = "apple-cli-test initial\nsecond line"
        let result = try MessagesConversationPlan.build(inputs: ["+1 (212) 555-0100"], message: text,
            service: "imessage", gate: gate(execute: execute), deadline: .millisecondsFromNow(5000),
            loadContacts: { Issue.record("Exact recipient read contacts"); return [] })
        guard case .ready(let plan) = result else { Issue.record("Expected plan"); return }
        #expect(plan.initialText == text)
        #expect(plan.service == "iMessage")
        #expect(plan.gate.willExecute == execute)
        #expect(!plan.isGroup)
        #expect(plan.recipients.map(\.candidate.address.canonical) == ["+12125550100"])
        try #require(plan.recipients.count == 1)
        #expect(plan.recipients[0].input == "+1 (212) 555-0100")
        #expect(plan.recipients[0].index == 0)
    }

    @Test(arguments: ["", " \n\t ", "a\0b", String(repeating: "a", count: 2049)])
    func requiresBoundedNonblankInitialText(_ text: String) {
        #expect(throws: MessagesConversationPlan.Failure.invalidInitialText) {
            try MessagesConversationPlan.build(inputs: ["Alice"], message: text, service: "imessage",
                gate: gate(), deadline: .millisecondsFromNow(5000),
                loadContacts: { Issue.record("Invalid message reached contacts"); return [] })
        }
    }

    @Test(arguments: [nil, "auto", "sms", "rcs", "IMESSAGE"] as [String?])
    func requiresExplicitIMessageService(_ service: String?) {
        #expect(throws: MessagesConversationPlan.Failure.unsupportedService) {
            try MessagesConversationPlan.build(inputs: ["Alice"], message: "initial", service: service,
                gate: gate(), deadline: .millisecondsFromNow(5000),
                loadContacts: { Issue.record("Unsupported service reached contacts"); return [] })
        }
    }

    @Test func requiresOneTo32Inputs() {
        for inputs in [[], Array(repeating: "+12125550100", count: 33)] {
            #expect(throws: MessagesConversationPlan.Failure.invalidRecipientCount) {
                try MessagesConversationPlan.build(inputs: inputs, message: "initial", service: "imessage",
                    gate: gate(), deadline: .millisecondsFromNow(5000), loadContacts: { [] })
            }
        }
    }

    @Test(arguments: [["+1 (212) 555-0100", "+1.212.555.0100"], ["Alice@EXAMPLE.COM", "Alice@example.com"]])
    func rejectsDuplicateCanonicalRecipients(_ inputs: [String]) {
        #expect(throws: MessagesConversationPlan.Failure.duplicateRecipient) {
            try MessagesConversationPlan.build(inputs: inputs, message: "initial", service: "imessage",
                gate: gate(), deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        }
    }

    @Test func nameAndExplicitAliasAreDuplicateRecipients() {
        #expect(throws: MessagesConversationPlan.Failure.duplicateRecipient) {
            try MessagesConversationPlan.build(inputs: ["Alice Example", "Alice@example.com"], message: "initial",
                service: "imessage", gate: gate(), deadline: .millisecondsFromNow(5000),
                loadContacts: { [.init(fullName: "Alice Example", nickname: "", rawAddress: "Alice@EXAMPLE.COM")] })
        }
    }

    @Test func distinctCaseSensitiveEmailRecipientsRemainDistinct() throws {
        let result = try MessagesConversationPlan.build(inputs: ["Alice@example.com", "alice@example.com"],
            message: "initial", service: "imessage", gate: gate(), deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        guard case .ready(let plan) = result else { Issue.record("Expected group plan"); return }
        #expect(plan.isGroup)
        #expect(plan.recipients.count == 2)
    }

    @Test func oneContactCaptureServesAllNames() throws {
        var calls = 0
        let result = try MessagesConversationPlan.build(inputs: ["Alice Example", "Bob Sample"], message: "initial",
            service: "imessage", gate: gate(), deadline: .millisecondsFromNow(5000), loadContacts: {
                calls += 1
                return [.init(fullName: "Alice Example", nickname: "", rawAddress: "+12125550100"),
                        .init(fullName: "Bob Sample", nickname: "", rawAddress: "+12125550101")]
            })
        #expect(calls == 1)
        guard case .ready(let plan) = result else { Issue.record("Expected resolved names"); return }
        #expect(plan.recipients.map(\.index) == [0, 1])
    }

    @Test func ambiguityCannotProducePartialReadyPlan() throws {
        let result = try MessagesConversationPlan.build(inputs: ["+12125550102", "Alice Example", "Nobody"],
            message: "initial", service: "imessage", gate: gate(), deadline: .millisecondsFromNow(5000), loadContacts: {
                [.init(fullName: "Alice Example", nickname: "", rawAddress: "+12125550100"),
                 .init(fullName: "Alice Example", nickname: "", rawAddress: "+12125550101")]
            })
        guard case .unresolved(let issues) = result else { Issue.record("Expected unresolved request"); return }
        #expect(issues.map(\.index) == [1, 2])
        try #require(issues.count == 2)
        guard case .ambiguous(let candidates) = issues[0].reason else { Issue.record("Expected ambiguity"); return }
        #expect(candidates.count == 2)
        guard case .notFound = issues[1].reason else { Issue.record("Expected missing name"); return }
    }

    @Test(arguments: [false, true])
    func sandboxGroupsRefusedInPreviewAndExecution(_ execute: Bool) {
        #expect(throws: MessagesConversationPlan.Failure.sandboxGroupUnavailable) {
            try MessagesConversationPlan.build(inputs: ["Alice", "Bob"], message: "apple-cli-test initial",
                service: "imessage", gate: gate(execute: execute, sandbox: true,
                    allowed: ["+12125550100", "+12125550101"]), deadline: .millisecondsFromNow(5000),
                loadContacts: { Issue.record("Sandbox group reached contacts"); return [] })
        }
    }

    @Test(arguments: [false, true])
    func sandboxLabelAndRecipientChecksApplyToBothPostures(_ execute: Bool) throws {
        let policy = gate(execute: execute, sandbox: true, allowed: ["2125550100"])
        #expect(throws: MessagesConversationPlan.Failure.sandboxLabelRequired) {
            try MessagesConversationPlan.build(inputs: ["+12125550100"], message: "unlabeled", service: "imessage",
                gate: policy, deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        }
        #expect(throws: MessagesConversationPlan.Failure.recipientNotAllowed) {
            try MessagesConversationPlan.build(inputs: ["+12125550101"], message: "apple-cli-test initial", service: "imessage",
                gate: policy, deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        }
        let result = try MessagesConversationPlan.build(inputs: ["+12125550100"], message: "apple-cli-test initial",
            service: "imessage", gate: policy, deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        guard case .ready = result else { Issue.record("Expected allowed direct plan"); return }
    }

    @Test func emptySandboxAllowlistRefuses() {
        #expect(throws: MessagesConversationPlan.Failure.recipientNotAllowed) {
            try MessagesConversationPlan.build(inputs: ["+12125550100"], message: "apple-cli-test initial", service: "imessage",
                gate: gate(sandbox: true), deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        }
    }

    @Test func expiredPlanCannotReadContacts() {
        #expect(throws: WorkerProtocolError.deadlineExpired) {
            try MessagesConversationPlan.build(inputs: ["Alice"], message: "initial", service: "imessage", gate: gate(),
                deadline: .millisecondsFromNow(0), loadContacts: { Issue.record("Expired plan read contacts"); return [] })
        }
    }

    @Test func emptySandboxPrefixCannotDisableLabelCheck() {
        #expect(throws: MessagesConversationPlan.Failure.invalidPolicy) {
            try MessagesConversationPlan.build(inputs: ["Alice"], message: "unlabeled", service: "imessage",
                gate: gate(sandbox: true, prefix: "", allowed: ["+12125550100"]),
                deadline: .millisecondsFromNow(5000), loadContacts: { Issue.record("Invalid policy read contacts"); return [] })
        }
    }

    @Test func acceptsMaximumCountsAndMeasuresTextBytes() throws {
        let inputs = (100..<132).map { "+12125550" + String($0) }
        let text = String(repeating: "é", count: 1024)
        let result = try MessagesConversationPlan.build(inputs: inputs, message: text, service: "imessage",
            gate: gate(), deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        guard case .ready(let plan) = result else { Issue.record("Expected bounded group"); return }
        #expect(plan.recipients.count == 32)
        #expect(plan.initialText.utf8.count == 2048)
        #expect(throws: MessagesConversationPlan.Failure.invalidInitialText) {
            try MessagesConversationPlan.build(inputs: inputs, message: text + "é", service: "imessage",
                gate: gate(), deadline: .millisecondsFromNow(5000), loadContacts: { [] })
        }
    }

    @Test func cancelledPlanCannotReadContacts() {
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesConversationPlan.build(inputs: ["Alice"], message: "initial", service: "imessage", gate: gate(),
                deadline: .millisecondsFromNow(5000), isCancelled: { true },
                loadContacts: { Issue.record("Cancelled plan read contacts"); return [] })
        }
    }
}
