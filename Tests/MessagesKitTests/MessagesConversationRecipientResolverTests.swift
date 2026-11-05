import AppleKit
import Testing
@testable import MessagesKit

@Suite("Conversation creation recipient resolution")
struct MessagesConversationRecipientResolverTests {
    private func record(_ name: String, _ raw: String, nickname: String = "") -> MessagesConversationRawContacts.Record {
        .init(fullName: name, nickname: nickname, rawAddress: raw)
    }

    @Test func explicitAddressDoesNotReadContacts() throws {
        let result = try MessagesConversationRecipientResolver.resolve("+1 (212) 555-0100",
            deadline: .millisecondsFromNow(5000), loadContacts: {
                Issue.record("Explicit addresses must not read contacts")
                return []
            })
        guard case .resolved(let candidate) = result else {
            Issue.record("Expected exact recipient"); return
        }
        #expect(candidate.address.canonical == "+12125550100")
        #expect(candidate.rawAddresses == ["+1 (212) 555-0100"])
    }

    @Test(arguments: ["+12125550100 ext 42", "2125550100", "Alice@@example.com", "+１２１２５５５０１００"])
    func malformedExplicitAddressNeverFallsBackToName(_ raw: String) {
        #expect(throws: (any Error).self) {
            try MessagesConversationRecipientResolver.resolve(raw, deadline: .millisecondsFromNow(5000),
                loadContacts: { Issue.record("Malformed address reached contacts"); return [] })
        }
    }

    @Test func nameUsesExistingMatchingScoresAndNickname() throws {
        let result = try MessagesConversationRecipientResolver.resolve("Al", deadline: .millisecondsFromNow(5000),
            loadContacts: { [record("Alice Example", "Alice@EXAMPLE.COM", nickname: "Al")] })
        guard case .resolved(let candidate) = result else {
            Issue.record("Expected nickname match"); return
        }
        #expect(candidate.address.canonical == "Alice@example.com")
        #expect(candidate.displayName == "Alice Example")
        #expect(candidate.score == 1)
        #expect(candidate.matchedOn == "Al")
    }

    @Test func returnsAllAmbiguousAddressesInStableOrder() throws {
        let records = [record("Alice Example", "+12125550101"), record("Alice Example", "+12125550100")]
        for rows in [records, records.reversed().map { $0 }] {
            let result = try MessagesConversationRecipientResolver.resolve("Alice Example",
                deadline: .millisecondsFromNow(5000), loadContacts: { rows })
            guard case .ambiguous(let candidates) = result else {
                Issue.record("Expected ambiguity"); return
            }
            #expect(candidates.map(\.address.canonical) == ["+12125550100", "+12125550101"])
        }
    }

    @Test(arguments: ["", "+12125550100 ext 42", "Alice@example.com\n"])
    func invalidMatchedAddressCannotManufactureUniqueness(_ invalid: String) {
        #expect(throws: MessagesConversationRecipientResolver.Failure.invalidMatchedAddress) {
            try MessagesConversationRecipientResolver.resolve("Alice Example", deadline: .millisecondsFromNow(5000),
                loadContacts: { [record("Alice Example", "+12125550100"), record("Alice Example", invalid)] })
        }
    }

    @Test func canonicalContactDuplicatesRetainRawProvenance() throws {
        let result = try MessagesConversationRecipientResolver.resolve("Alice", deadline: .millisecondsFromNow(5000),
            loadContacts: { [record("Alice Example", "+1 (212) 555-0100"), record("Alice Example", "+12125550100")] })
        guard case .resolved(let candidate) = result else {
            Issue.record("Expected one canonical address"); return
        }
        #expect(candidate.rawAddresses == ["+1 (212) 555-0100", "+12125550100"])
    }

    @Test func emailLocalCaseRemainsAmbiguous() throws {
        let result = try MessagesConversationRecipientResolver.resolve("Alice Example", deadline: .millisecondsFromNow(5000),
            loadContacts: { [record("Alice Example", "Alice@example.com"), record("Alice Example", "alice@example.com")] })
        guard case .ambiguous(let candidates) = result else {
            Issue.record("Local-part case cannot merge addresses"); return
        }
        #expect(candidates.count == 2)
    }

    @Test func missingNameReturnsNotFound() throws {
        let result = try MessagesConversationRecipientResolver.resolve("Nobody", deadline: .millisecondsFromNow(5000),
            loadContacts: { [] })
        guard case .notFound = result else { Issue.record("Expected not found"); return }
    }

    @Test func unreadableContactsCannotBecomeNotFound() {
        #expect(throws: MessagesConversationRawContacts.Failure.invalidRecord) {
            try MessagesConversationRecipientResolver.resolve("Alice", deadline: .millisecondsFromNow(5000),
                loadContacts: { throw MessagesConversationRawContacts.Failure.invalidRecord })
        }
    }

    @Test(arguments: ["", "   ", "Alice\n", "Al\0ice", String(repeating: "a", count: 513)])
    func refusesInvalidInputBeforeLoading(_ input: String) {
        #expect(throws: MessagesConversationRecipientResolver.Failure.invalidInput) {
            try MessagesConversationRecipientResolver.resolve(input, deadline: .millisecondsFromNow(5000),
                loadContacts: { Issue.record("Invalid input reached contacts"); return [] })
        }
    }

    @Test func rejectsIncompleteOversizedSnapshot() {
        let rows = Array(repeating: record("Alice", "+12125550100"), count: 8193)
        #expect(throws: MessagesConversationRecipientResolver.Failure.limitExceeded) {
            try MessagesConversationRecipientResolver.resolve("Alice", deadline: .millisecondsFromNow(5000),
                loadContacts: { rows })
        }
    }

    @Test func expiredAndCancelledResolutionCannotReturnPartialMatch() {
        #expect(throws: WorkerProtocolError.deadlineExpired) {
            try MessagesConversationRecipientResolver.resolve("Alice", deadline: .millisecondsFromNow(0),
                loadContacts: { Issue.record("Expired call read contacts"); return [] })
        }
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesConversationRecipientResolver.resolve("Alice", deadline: .millisecondsFromNow(5000),
                isCancelled: { true }, loadContacts: { Issue.record("Cancelled call read contacts"); return [] })
        }
    }
}
