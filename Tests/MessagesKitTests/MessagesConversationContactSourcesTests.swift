import AppleKit
import Foundation
import TestSupport
import Testing
@testable import MessagesKit

@Suite("Conversation creation contact source discovery")
struct MessagesConversationContactSourcesTests {
    private let scratch = ScratchDirs("conversation-contact-sources")
    private let fileManager = FileManager.default

    private func createDatabase(_ directory: URL) throws -> String {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("AddressBook-v22.abcddb")
        try Data().write(to: path)
        return path.path
    }

    @Test func discoversAllSourceAndTopLevelDatabases() throws {
        let root = try scratch.directory()
        let a = try createDatabase(root.appendingPathComponent("Sources/a"))
        let b = try createDatabase(root.appendingPathComponent("Sources/b"))
        let top = try createDatabase(root)
        let actual = try MessagesConversationContactSources.discover(addressBookRoot: root.path,
            deadline: .millisecondsFromNow(5000))
        #expect(actual == [a, b, top].sorted())
    }

    @Test func missingSourcesDirectoryCanUseVerifiedTopLevelDatabase() throws {
        let root = try scratch.directory(), top = try createDatabase(root)
        #expect(try MessagesConversationContactSources.discover(addressBookRoot: root.path,
            deadline: .millisecondsFromNow(5000)) == [top])
    }

    @Test func missingRootDoesNotBecomeEmptyContactSet() throws {
        let root = try scratch.directory().appendingPathComponent("missing")
        #expect(throws: MessagesConversationContactSources.Failure.unavailable) {
            try MessagesConversationContactSources.discover(addressBookRoot: root.path,
                deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func emptyCatalogDoesNotClaimReadableContacts() throws {
        let root = try scratch.directory()
        try fileManager.createDirectory(at: root.appendingPathComponent("Sources/a"), withIntermediateDirectories: true)
        #expect(throws: MessagesConversationContactSources.Failure.unavailable) {
            try MessagesConversationContactSources.discover(addressBookRoot: root.path,
                deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func sourceDirectoryTypeMismatchIsTerminal() throws {
        let root = try scratch.directory()
        _ = try createDatabase(root)
        try Data().write(to: root.appendingPathComponent("Sources"))
        #expect(throws: MessagesConversationContactSources.Failure.unavailable) {
            try MessagesConversationContactSources.discover(addressBookRoot: root.path,
                deadline: .millisecondsFromNow(5000))
        }
    }

    @Test(arguments: ["root", "sources", "account", "database"])
    func refusesObservedSymlinks(_ kind: String) throws {
        let base = try scratch.directory(), actual = try scratch.directory()
        _ = try createDatabase(actual)
        let root = kind == "root" ? base.appendingPathComponent("root") : base
        if kind == "root" {
            try fileManager.createSymbolicLink(at: root, withDestinationURL: actual)
        } else if kind == "sources" {
            try fileManager.createSymbolicLink(at: root.appendingPathComponent("Sources"), withDestinationURL: actual)
        } else {
            let sources = root.appendingPathComponent("Sources")
            try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
            if kind == "account" {
                try fileManager.createSymbolicLink(at: sources.appendingPathComponent("account"), withDestinationURL: actual)
            } else {
                try fileManager.createSymbolicLink(at: root.appendingPathComponent("AddressBook-v22.abcddb"),
                    withDestinationURL: actual.appendingPathComponent("AddressBook-v22.abcddb"))
            }
        }
        #expect(throws: MessagesConversationContactSources.Failure.unavailable) {
            try MessagesConversationContactSources.discover(addressBookRoot: root.path,
                deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func rejectsMoreThan64Databases() throws {
        let root = try scratch.directory()
        for index in 0..<65 { _ = try createDatabase(root.appendingPathComponent("Sources/entry-\(index)")) }
        #expect(throws: MessagesConversationContactSources.Failure.limitExceeded) {
            try MessagesConversationContactSources.discover(addressBookRoot: root.path,
                deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func rejectsIncompleteDirectoryEnumeration() throws {
        let root = try scratch.directory(), sources = root.appendingPathComponent("Sources")
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        _ = try createDatabase(root)
        for index in 0..<257 { try Data().write(to: sources.appendingPathComponent("metadata-\(index)")) }
        #expect(throws: MessagesConversationContactSources.Failure.limitExceeded) {
            try MessagesConversationContactSources.discover(addressBookRoot: root.path,
                deadline: .millisecondsFromNow(5000))
        }
    }

    @Test func cancellationAndExpiryPrecedeFilesystemAccess() {
        #expect(throws: WorkerProtocolError.cancelled) {
            try MessagesConversationContactSources.discover(addressBookRoot: "/synthetic",
                deadline: .millisecondsFromNow(5000), isCancelled: { true })
        }
        #expect(throws: WorkerProtocolError.deadlineExpired) {
            try MessagesConversationContactSources.discover(addressBookRoot: "/synthetic",
                deadline: .millisecondsFromNow(0))
        }
    }

    @Test func unreadableCatalogCannotReturnOnlyTopLevelDatabase() throws {
        let root = try scratch.directory(), sources = root.appendingPathComponent("Sources")
        _ = try createDatabase(root)
        _ = try createDatabase(sources.appendingPathComponent("account"))
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: sources.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sources.path) }
        #expect(throws: MessagesConversationContactSources.Failure.unavailable) {
            try MessagesConversationContactSources.discover(addressBookRoot: root.path,
                deadline: .millisecondsFromNow(5000))
        }
    }
}
