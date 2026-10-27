import ArgumentParser
import AppleKit
import Foundation
import os
import Testing
@testable import MessagesKit

@Suite struct MessagesAttachmentResolverRegressionTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        let body = NSMutableAttributedString(string: "apple-cli-test \u{fffc}")
        let range = NSRange(location: body.length - 1, length: 1)
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: range)
        body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: "a10", range: range)
        try fx.insertMessage(rowid: 60, guid: "synthetic-retrieval", attributedBody: NSArchiver.archivedData(withRootObject: body),
                             chatRowid: 3, date: fx.base, cacheHasAttachments: true)
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,10); ALTER TABLE attachment ADD COLUMN transfer_state; UPDATE attachment SET transfer_state=5")
        return fx
    }

    private func read(_ fx: ChatFixture, sandbox: String? = nil,
                      deadline: WorkerDeadline = .millisecondsFromNow(5000),
                      isCancelled: @escaping () -> Bool = { false }) throws -> MessagesAttachmentTargetResolver.Capture {
        try MessagesAttachmentTargetResolver.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(60),
            partIndex: 0, sandboxPrefix: sandbox, deadline: deadline, isCancelled: isCancelled)
    }

    @Test func sandboxPolicyIsBoundAndNativeTextCanSupplyLabel() throws {
        let fx = try fixture()
        let capture = try read(fx, sandbox: "apple-cli-test")
        #expect(capture.request.sandboxPrefix == "apple-cli-test")
        #expect(capture.request.membershipCount == 1)
        let roundTrip = try JSONDecoder().decode(MessagesAttachmentRetrievalRequest.self, from: capture.request.workerPayloadData())
        #expect(roundTrip.sandboxPrefix == "apple-cli-test")
        let ordinary = try read(fx)
        #expect(try ordinary.request.workerPayloadData() != capture.request.workerPayloadData())
    }

    @Test(arguments: [
        "INSERT INTO message(ROWID,guid) VALUES(61,'synthetic-retrieval')",
        "INSERT INTO chat_message_join VALUES(1,60)",
        "INSERT INTO chat_message_join VALUES(3,60)",
        "INSERT INTO chat_handle_join VALUES(3,1)",
        "INSERT INTO chat_handle_join VALUES(3,999)",
        "ALTER TABLE message ADD COLUMN _rowid_ INTEGER",
        "UPDATE message SET attributedBody=zeroblob(1048577) WHERE ROWID=60",
        "UPDATE message SET text=CAST(zeroblob(1048577) AS TEXT) WHERE ROWID=60"
    ]) func malformedOrUnboundedTargetIsRefused(_ sql: String) throws {
        let fx = try fixture()
        try fx.exec(sql)
        #expect(throws: (any Error).self) { try read(fx) }
    }

    @Test(arguments: [
        "UPDATE chat SET style=43 WHERE ROWID=3",
        "UPDATE chat SET style=99 WHERE ROWID=3",
        "UPDATE chat SET style=NULL WHERE ROWID=3",
        "UPDATE message SET text='label removed' WHERE ROWID=60"
    ]) func sandboxDriftIsRefused(_ sql: String) throws {
        let fx = try fixture()
        _ = try read(fx, sandbox: "apple-cli-test")
        try fx.exec(sql)
        #expect(throws: (any Error).self) { try read(fx, sandbox: "apple-cli-test") }
    }

    @Test func commonDeadlineAndCancellationStopResolution() throws {
        let fx = try fixture()
        #expect(throws: MessagesAXNavigationError.deadlineExpired) { try read(fx, deadline: .millisecondsFromNow(0)) }
        #expect(throws: WorkerProtocolError.cancelled) { try read(fx, isCancelled: { true }) }
        var checks = 0
        #expect(throws: (any Error).self) {
            try read(fx, isCancelled: { checks += 1; return checks > 15 })
        }
        #expect(checks > 15)
    }

    @Test func commandUsesBoundedReaderWithoutPresentationEnrichment() throws {
        let fx = try fixture()
        var dependencies = MessagesCommandDependencies.live
        let addressBookReads = OSAllocatedUnfairLock(initialState: 0)
        let legacyReads = OSAllocatedUnfairLock(initialState: 0)
        dependencies.loadAddressBook = { addressBookReads.withLock { $0 += 1 }; return AddressBook() }
        dependencies.makeChatDB = { _ in legacyReads.withLock { $0 += 1 }; throw MessagesAttachmentTargetResolver.Failure.invalidTarget }
        let command = try MessagesAttachmentRetrieve.parse(["--chat-rowid", "3", "--message-rowid", "60", "--part-index", "0"])
        let request = try command.resolve(dependencies: dependencies, databasePath: fx.path,
            gate: .init(willExecute: false, sandboxActive: true, allowedRecipients: ["+12125550100"]))
        #expect(request.membershipCount == 1)
        #expect(addressBookReads.withLock { $0 } == 0)
        #expect(legacyReads.withLock { $0 } == 0)
    }
}
