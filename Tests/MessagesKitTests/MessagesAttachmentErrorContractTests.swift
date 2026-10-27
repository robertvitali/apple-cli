import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleKit
@testable import MessagesKit

@Suite struct MessagesAttachmentErrorContractTests {
    @Test(arguments: ["label", "group", "recipient", "empty-recipient", "nonempty-recipient", "blob-label", "rowid", "missing", "part", "native-guid", "schema"])
    func expectedRefusalsHavePublicErrorCategories(_ scenario: String) throws {
        let fx = try ChatFixture()
        let body = NSMutableAttributedString(string: scenario == "blob-label" ? "unlabeled \u{fffc}" : "apple-cli-test \u{fffc}")
        let range = NSRange(location: body.length - 1, length: 1)
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: range)
        body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: "a10", range: range)
        try fx.insertMessage(rowid: 60, guid: "synthetic-error-target", attributedBody: NSArchiver.archivedData(withRootObject: body),
                             chatRowid: 3, date: fx.base, cacheHasAttachments: true)
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,10)")
        var message = "60", part = "0"
        var expectedType = "safety_violation"
        var expectedCode: Int32 = 77
        let sandbox = ["label", "group", "recipient", "empty-recipient", "nonempty-recipient", "blob-label"].contains(scenario)
        switch scenario {
        case "label": try fx.exec("UPDATE message SET text='unlabeled' WHERE ROWID=60")
        case "group": try fx.exec("UPDATE chat SET style=43 WHERE ROWID=3")
        case "recipient": break
        case "empty-recipient": try fx.exec("UPDATE handle SET id='synthetic-peer' WHERE ROWID=1")
        case "nonempty-recipient": try fx.exec("UPDATE handle SET id='synthetic-peer-12125550100' WHERE ROWID=1")
        case "blob-label":
            try fx.exec("UPDATE message SET text=CAST('apple-cli-test forged label' AS BLOB) WHERE ROWID=60")
            expectedType = "validation_error"; expectedCode = 64
        case "native-guid":
            try fx.exec("UPDATE message SET guid='synthetic_message' WHERE ROWID=60")
            expectedType = "validation_error"; expectedCode = 64
        case "rowid": message = "0"; expectedType = "validation_error"; expectedCode = 64
        case "missing": message = "999"; expectedType = "not_found"; expectedCode = 65
        case "part": part = "99"; expectedType = "validation_error"; expectedCode = 64
        default: try fx.exec("ALTER TABLE message RENAME COLUMN attributedBody TO old_body"); expectedType = "upstream_error"; expectedCode = 69
        }
        let allowlist = scenario == "empty-recipient" ? ["synthetic-self"] :
            (scenario == "recipient" ? ["+12125550101"] : ["+12125550100"])
        var dependencies = MessagesCommandDependencies.fixture(launchObservedWorker: { _ in
            Issue.record("refused target launched a worker")
            throw WorkerProtocolError.malformedFrame
        })
        dependencies.resolveGate = { _ in
            .init(willExecute: false, sandboxActive: sandbox, allowedRecipients: allowlist)
        }
        let stdout = MemoryOutputSink(), stderr = MemoryOutputSink()
        var exitCode: Int32?
        do {
            try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                try MessagesAttachmentRetrieve.parse(["--chat-rowid", "3", "--message-rowid", message,
                    "--part-index", part, "--dry-run"]).run(dependencies: dependencies, databasePath: fx.path)
            }
        } catch let exit as ExitCode { exitCode = exit.rawValue }
        let envelope = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(envelope["ok"] as? Bool == false)
        #expect(error["type"] as? String == expectedType)
        #expect(exitCode == expectedCode)
        if expectedType == "safety_violation" { #expect(error["sandbox"] as? Bool == true) }
        else { #expect(error["sandbox"] == nil) }
    }

    @Test(arguments: [
        "UPDATE message SET text='label removed' WHERE ROWID=60",
        "UPDATE chat SET style=43 WHERE ROWID=3",
        "UPDATE handle SET id='+12125550101' WHERE ROWID=1"
    ])
    func lockedResolutionRetainsSandboxError(_ mutation: String) throws {
        let fx = try ChatFixture()
        let body = NSMutableAttributedString(string: "apple-cli-test \u{fffc}")
        let range = NSRange(location: body.length - 1, length: 1)
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: range)
        body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: "a10", range: range)
        try fx.insertMessage(rowid: 60, guid: "synthetic-locked-target", attributedBody: NSArchiver.archivedData(withRootObject: body),
                             chatRowid: 3, date: fx.base, cacheHasAttachments: true)
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,10)")
        let stateRoot = fx.homePath + "/attachment-state"
        let databasePath = fx.path
        var dependencies = MessagesCommandDependencies.fixture(
            messagesAutomationStateRoot: { stateRoot },
            launchObservedWorker: { action in
                var database: OpaquePointer?
                let opened = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READWRITE, nil)
                defer { if let database { sqlite3_close(database) } }
                guard opened == SQLITE_OK,
                      sqlite3_exec(database, mutation, nil, nil, nil) == SQLITE_OK else {
                    throw AppleError.upstream("synthetic fixture mutation failed")
                }
                return try WorkerLauncher().launchObserved(action)
            })
        dependencies.resolveGate = { _ in
            .init(willExecute: true, sandboxActive: true, allowedRecipients: ["+12125550100"])
        }
        let stdout = MemoryOutputSink(), stderr = MemoryOutputSink()
        var exitCode: Int32?
        do {
            try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                try MessagesAttachmentRetrieve.parse(["--chat-rowid", "3", "--message-rowid", "60",
                    "--part-index", "0", "--experimental-ui-handoff"])
                    .run(dependencies: dependencies, databasePath: fx.path)
            }
        } catch let exit as ExitCode { exitCode = exit.rawValue }
        let envelope = try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(envelope["ok"] as? Bool == false)
        #expect(error["type"] as? String == "safety_violation")
        #expect(error["sandbox"] as? Bool == true)
        #expect(exitCode == 77)
        try AppleAutomationJournal.withLockedJournal(root: stateRoot, deadline: .millisecondsFromNow(1000)) { lease in
            let snapshot = try lease.loadSnapshot()
            #expect(snapshot.pending == nil)
            #expect(snapshot.receipts.isEmpty)
        }
    }
}
