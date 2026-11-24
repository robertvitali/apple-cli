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
        body.addAttribute(.init("__kIMMessagePartAttributeName"), value: NSNumber(value: 1),
                          range: NSRange(location: 0, length: range.location))
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

    @Test(arguments: ["unchanged", "unrelated", "path", "equivalent-path", "transfer", "second-file", "recipient", "membership"])
    func confirmationRechecksTheBoundSnapshotAfterFileInspection(_ change: String) throws {
        let fx = try fixture()
        try fx.exec("""
            INSERT INTO attachment(ROWID,guid,filename,transfer_state) VALUES(85,'sibling','sibling.bin',5);
            INSERT INTO message_attachment_join VALUES(60,85);
            UPDATE attachment SET filename='caf\u{e9}.bin' WHERE ROWID=10
            """)
        let payload = try read(fx, sandbox: "apple-cli-test").request
        let worker = MessagesAttachmentDownloadObservation(payload: payload, databasePath: fx.path, homeDirectory: fx.homePath)
        let result = Result {
            try worker.confirmDownloaded(deadline: .millisecondsFromNow(5000)) { items in
                #expect(items.count == 2)
                switch change {
                case "unchanged": break
                case "unrelated": try fx.exec("UPDATE message SET text='other' WHERE ROWID=1")
                case "path": try fx.exec("UPDATE attachment SET filename='moved.bin' WHERE ROWID=10")
                case "equivalent-path": try fx.exec("UPDATE attachment SET filename='cafe\u{301}.bin' WHERE ROWID=10")
                case "transfer": try fx.exec("UPDATE attachment SET transfer_state=3 WHERE ROWID=10")
                case "second-file": try fx.exec("UPDATE attachment SET transfer_state=3 WHERE ROWID=85")
                case "recipient": try fx.exec("UPDATE handle SET id='other@example.invalid' WHERE ROWID IN (SELECT handle_id FROM chat_handle_join WHERE chat_id=3)")
                case "membership": try fx.exec("DELETE FROM message_attachment_join WHERE message_id=60 AND attachment_id=85")
                default: Issue.record("Unexpected test case")
                }
                return true
            }
        }
        if change == "recipient" || change == "membership" {
            #expect(throws: MessagesAXNavigationError.targetDrift) { try result.get() }
        } else {
            #expect(try result.get() == (change == "unchanged" || change == "unrelated"))
        }
    }

    @Test(arguments: [(0, false), (2, false), (0, true), (2, true)])
    func attachmentRequiresOneNativeAddress(_ index: Int, _ repeated: Bool) throws {
        let fx = try fixture()
        let partKey = NSAttributedString.Key("__kIMMessagePartAttributeName")
        let body = NSMutableAttributedString(string: "apple-cli-test ")
        let attachment = NSAttributedString(string: "\u{fffc}", attributes: [
            partKey: NSNumber(value: index), .init("__kIMFileTransferGUIDAttributeName"): "a10"
        ])
        if repeated {
            body.addAttribute(partKey, value: NSNumber(value: 1), range: NSRange(location: 0, length: body.length))
            body.append(attachment)
            body.append(NSAttributedString(string: " ", attributes: [partKey: NSNumber(value: 1)]))
        }
        body.append(attachment)
        let hex = NSArchiver.archivedData(withRootObject: body).map { String(format: "%02x", $0) }.joined()
        try fx.exec("UPDATE message SET attributedBody=X'\(hex)' WHERE ROWID=60")
        func resolve() throws -> MessagesAttachmentRetrievalRequest {
            try MessagesAttachmentTargetResolver.read(databasePath: fx.path, chat: .rowid(3), message: .rowid(60),
                partIndex: index, sandboxPrefix: "apple-cli-test", deadline: .millisecondsFromNow(5000)).request
        }
        if index == 0 || repeated {
            #expect(throws: MessagesAttachmentTargetResolver.Failure.invalidTarget) { try resolve() }
        } else {
            let request = try resolve()
            #expect(request.selectedAttachmentGUID == "a10")
            #expect(request.nativePartIndex == index)
        }
    }

    @Test func sandboxChecksTheLabelBytesOnBothRepresentations() throws {
        let fx = try fixture()
        let prefix = "test-\u{e9}"
        let alternate = "test-e\u{301}"
        let body = NSMutableAttributedString(string: prefix + " \u{fffc}")
        let attachment = NSRange(location: body.length - 1, length: 1)
        let part = NSAttributedString.Key("__kIMMessagePartAttributeName")
        body.addAttribute(part, value: 1, range: NSRange(location: 0, length: attachment.location))
        body.addAttribute(part, value: 0, range: attachment)
        body.addAttribute(.init("__kIMFileTransferGUIDAttributeName"), value: "a10", range: attachment)
        let bytes = NSArchiver.archivedData(withRootObject: body).map { String(format: "%02x", $0) }.joined()
        try fx.exec("UPDATE message SET attributedBody=X'\(bytes)', text='\(prefix) caption' WHERE ROWID=60")
        #expect(try read(fx, sandbox: prefix).request.selectedAttachmentGUID == "a10")
        #expect(throws: MessagesAttachmentTargetResolver.Failure.sandboxViolation) {
            try read(fx, sandbox: alternate)
        }
        try fx.exec("UPDATE message SET text='\(alternate) caption' WHERE ROWID=60")
        #expect(throws: MessagesAttachmentTargetResolver.Failure.sandboxViolation) {
            try read(fx, sandbox: prefix)
        }
        #expect(try read(fx).request.selectedAttachmentGUID == "a10")
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

    @Test(arguments: [
        ("chat_handle_join", "chat_id, handle_id", "'0.3e1',999"),
        ("chat_message_join", "chat_id, message_id", "1,'0.6e2'")
    ]) func malformedEquivalentMembershipCannotHide(_ table: String, _ columns: String, _ edge: String) throws {
        let fx = try fixture()
        try fx.exec("""
            ALTER TABLE \(table) RENAME TO old_edges;
            CREATE TABLE \(table)(\(columns));
            INSERT INTO \(table) SELECT \(columns) FROM old_edges;
            INSERT INTO \(table) VALUES(\(edge));
            """)
        #expect(throws: (any Error).self) { try read(fx, sandbox: "apple-cli-test") }
    }

    @Test func generatedParticipantCannotSatisfyRecipientCheck() throws {
        let fx = try fixture()
        try fx.exec("""
            ALTER TABLE handle RENAME COLUMN id TO original_id;
            UPDATE handle SET original_id='+12125550199' WHERE ROWID=1;
            ALTER TABLE handle ADD COLUMN id TEXT GENERATED ALWAYS AS ('+12125550100') VIRTUAL;
            """)
        #expect(throws: MessagesAttachmentTargetResolver.Failure.unsupportedSchema) {
            try read(fx, sandbox: "apple-cli-test")
        }
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
