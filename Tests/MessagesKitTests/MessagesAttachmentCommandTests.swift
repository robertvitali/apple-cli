import ArgumentParser
import AppleKit
import Foundation
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentCommandTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        let body = NSMutableAttributedString(string: "\u{fffc}")
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: NSRange(location: 0, length: 1))
        body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: "a10", range: NSRange(location: 0, length: 1))
        try fx.insertMessage(rowid: 60, guid: "synthetic-attachment-message", attributedBody: NSArchiver.archivedData(withRootObject: body),
            chatRowid: 3, date: fx.base, cacheHasAttachments: true)
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,10)")
        return fx
    }
    private func dependencies(_ fx: ChatFixture) -> MessagesCommandDependencies {
        let path = fx.path, home = fx.homePath
        var deps = MessagesCommandDependencies.live
        deps.loadAddressBook = { AddressBook() }
        deps.makeChatDB = { try ChatDB(path: path, book: $0, homeDirectoryForTilde: home) }
        return deps
    }
    private var gate: MessagesWriteGuard.Gate {
        .init(willExecute: false, sandboxActive: false, allowedRecipients: [])
    }
    private func command(_ extra: [String] = []) throws -> MessagesAttachmentRetrieve {
        try MessagesAttachmentRetrieve.parse(["--chat-rowid", "3", "--message-rowid", "60", "--part-index", "0"] + extra)
    }

    @Test func registeredCommandResolvesExactMembership() throws {
        let parsed = try MessagesCommand.parseAsRoot(["attachment", "retrieve", "--chat-rowid", "3",
            "--message-rowid", "60", "--part-index", "0", "--dry-run"])
        let options = try #require(parsed as? MessagesAttachmentRetrieve)
        let fx = try fixture()
        let request = try options.resolve(dependencies: dependencies(fx), databasePath: fx.path, gate: gate)
        #expect(request.messageRowid == 60)
        #expect(request.chatRowid == 3)
        #expect(request.membershipCount == 1)
    }

    @Test func ambiguousSelectorsAndAbsentNativePartAreRefused() throws {
        let fx = try fixture(), deps = dependencies(fx)
        let ambiguous = try command(["--message-guid", "synthetic-attachment-message"])
        #expect(throws: (any Error).self) { try ambiguous.resolve(dependencies: deps, databasePath: fx.path, gate: gate) }
        let missing = try MessagesAttachmentRetrieve.parse(["--chat-rowid", "3", "--message-rowid", "60"])
        #expect(throws: (any Error).self) { try missing.resolve(dependencies: deps, databasePath: fx.path, gate: gate) }
        try fx.exec("UPDATE attachment SET guid='different-attachment' WHERE ROWID=10")
        #expect(throws: (any Error).self) { try command().resolve(dependencies: deps, databasePath: fx.path, gate: gate) }
    }

    @Test func sandboxRefusesUnlabeledAttachmentTarget() throws {
        let fx = try fixture(), deps = dependencies(fx)
        let sandbox = MessagesWriteGuard.Gate(willExecute: false, sandboxActive: true, allowedRecipients: ["+12125550100"])
        #expect(throws: (any Error).self) { try command().resolve(dependencies: deps, databasePath: fx.path, gate: sandbox) }
    }
}
