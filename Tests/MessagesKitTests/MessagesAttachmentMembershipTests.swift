import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentMembershipTests {
    private func identity(_ row: Int64, _ guid: String) throws -> MessagesAttachmentRetrievalState.Identity {
        try #require(MessagesAttachmentRetrievalState.Identity(rowid: row, guid: guid))
    }

    @Test func orderingAndIdentityDrift() throws {
        let a = try identity(1, "synthetic-a"), b = try identity(2, "synthetic-b")
        let expected = try #require(MessagesAttachmentMembership([a, b]))
        #expect(expected == MessagesAttachmentMembership([b, a]))
        #expect(expected.count == 2)
        #expect(expected.sha256.utf8.count == 64)
        #expect(expected != MessagesAttachmentMembership([a]))
        #expect(expected != MessagesAttachmentMembership([a, try identity(3, "synthetic-b")]))
        #expect(expected != MessagesAttachmentMembership([a, try identity(2, "synthetic-c")]))
        #expect(MessagesAttachmentMembership([try identity(1, "\u{e9}")]) !=
                MessagesAttachmentMembership([try identity(1, "e\u{301}")]))
    }

    @Test func rejectsIncompleteOrDuplicateSets() throws {
        let a = try identity(1, "synthetic-a")
        #expect(MessagesAttachmentMembership([]) == nil)
        #expect(MessagesAttachmentMembership([a, a]) == nil)
        #expect(MessagesAttachmentMembership([a, try identity(1, "synthetic-b")]) == nil)
        #expect(MessagesAttachmentMembership([a, try identity(2, "synthetic-a")]) == nil)
        let values = try (1...1_025).map { try identity(Int64($0), "synthetic-\($0)") }
        #expect(MessagesAttachmentMembership(values) == nil)
        #expect(MessagesAttachmentMembership(Array(values.prefix(1_024)))?.count == 1_024)
    }
}
