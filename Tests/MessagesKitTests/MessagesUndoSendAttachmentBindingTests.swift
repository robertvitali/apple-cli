import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesUndoSendAttachmentBindingTests {
    private func identity(_ rowid: Int64, _ guid: String) throws -> MessagesAttachmentRetrievalState.Identity {
        try #require(MessagesAttachmentRetrievalState.Identity(rowid: rowid, guid: guid))
    }
    private func part(_ index: Int, _ guid: String?) -> NativeMessageParts.NativePart {
        .init(index: index, utf16Ranges: [.init(location: index, length: 1)], attachmentGUID: guid)
    }

    @Test func resolvesSelectedAttachmentWithoutUsingMemberOrder() throws {
        let first = try identity(10, "attachment-a"), second = try identity(11, "attachment-b")
        let value = try MessagesUndoSendAttachmentBinding.bind(
            nativeParts: [part(0, nil), part(1, "attachment-a"), part(2, "attachment-b")],
            selectedIndex: 2, members: [second, first])
        #expect(value == second)
    }

    @Test func textPartDoesNotAcquireAnotherPartsAttachment() throws {
        let member = try identity(10, "attachment-a")
        #expect(try MessagesUndoSendAttachmentBinding.bind(nativeParts: [part(0, nil), part(1, "attachment-a")],
            selectedIndex: 0, members: [member]) == nil)
        #expect(try MessagesUndoSendAttachmentBinding.bind(nativeParts: [part(0, nil)],
            selectedIndex: 0, members: []) == nil)
    }

    @Test func missingMembershipCannotBeSubstituted() throws {
        let member = try identity(10, "other-attachment")
        #expect(throws: (any Error).self) {
            try MessagesUndoSendAttachmentBinding.bind(nativeParts: [part(0, "attachment-a")],
                selectedIndex: 0, members: [member])
        }
        #expect(throws: (any Error).self) {
            try MessagesUndoSendAttachmentBinding.bind(nativeParts: [part(0, nil), part(1, "attachment-a")],
                selectedIndex: 0, members: [])
        }
    }

    @Test func canonicalUnicodeEqualityDoesNotBindDifferentGUIDBytes() throws {
        let member = try identity(10, "\u{e9}")
        #expect(throws: (any Error).self) {
            try MessagesUndoSendAttachmentBinding.bind(nativeParts: [part(0, "e\u{301}")],
                selectedIndex: 0, members: [member])
        }
        #expect(try MessagesUndoSendAttachmentBinding.bind(nativeParts: [part(0, "\u{e9}")],
            selectedIndex: 0, members: [member]) == member)
    }

    @Test func refusesDuplicateRowsOrGUIDsEvenOutsideSelectedMember() throws {
        let a = try identity(10, "a"), sameRow = try identity(10, "b"), sameGUID = try identity(11, "a")
        for members in [[a, a], [a, sameRow], [a, sameGUID]] {
            #expect(throws: (any Error).self) {
                try MessagesUndoSendAttachmentBinding.bind(nativeParts: [part(0, nil)],
                    selectedIndex: 0, members: members)
            }
        }
    }

    @Test func refusesDuplicatePartIndexOrSharedAttachmentMapping() throws {
        let a = try identity(10, "a")
        for parts in [[part(0, nil), part(0, "a")], [part(0, "a"), part(1, "a")]] {
            #expect(throws: (any Error).self) {
                try MessagesUndoSendAttachmentBinding.bind(nativeParts: parts, selectedIndex: 0, members: [a])
            }
        }
    }

    @Test func refusesInvalidAndMissingPartSelection() throws {
        for index in [-1, 1, Int.max] {
            #expect(throws: (any Error).self) {
                try MessagesUndoSendAttachmentBinding.bind(nativeParts: [part(0, nil)],
                    selectedIndex: index, members: [])
            }
        }
        #expect(throws: (any Error).self) {
            try MessagesUndoSendAttachmentBinding.bind(nativeParts: [], selectedIndex: 0, members: [])
        }
    }

    @Test func refusesOversizedMembership() throws {
        let members = try (1...1025).map { try identity(Int64($0), "synthetic-\($0)") }
        #expect(throws: (any Error).self) {
            try MessagesUndoSendAttachmentBinding.bind(nativeParts: [part(0, nil)], selectedIndex: 0, members: members)
        }
    }
}
