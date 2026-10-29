import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleKit
@testable import MessagesKit

@Suite struct MessagesEditCommandTests {
    private var now: Date { Date(timeIntervalSince1970: 800_000_002 + MessageTime.appleUnixOffset) }
    private func fixture(original: String = "apple-cli-test original") throws -> ChatFixture {
        let fx = try ChatFixture()
        let body = NSMutableAttributedString(string: original)
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0),
                          range: NSRange(location: 0, length: body.length))
        try fx.insertMessage(rowid: 60, guid: "synthetic-edit", attributedBody: NSArchiver.archivedData(withRootObject: body),
            chatRowid: 3, date: 800_000_000_000_000_000)
        let summary = try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
        let hex = summary.map { String(format: "%02x", $0) }.joined()
        try fx.exec("""
            ALTER TABLE message ADD COLUMN is_sent INTEGER;
            ALTER TABLE message ADD COLUMN date_edited INTEGER;
            ALTER TABLE message ADD COLUMN date_retracted INTEGER;
            ALTER TABLE message ADD COLUMN message_summary_info BLOB;
            UPDATE message SET is_from_me=1,is_sent=1,date_edited=0,date_retracted=0,message_summary_info=X'\(hex)' WHERE ROWID=60;
            """)
        return fx
    }
    private func command(_ extra: [String] = [], replacement: String = "apple-cli-test replacement") throws -> MessagesEdit {
        try MessagesEdit.parse(["--chat-rowid", "3", "--message-rowid", "60", "--part-index", "0", "--replacement-text", replacement] + extra)
    }
    private var gate: MessagesWriteGuard.Gate { .init(willExecute: false, sandboxActive: false, allowedRecipients: []) }

    @Test func registeredCommandKeepsTextOutputFlagDistinct() throws {
        let parsed = try MessagesCommand.parseAsRoot(["edit", "--chat-rowid", "3", "--message-rowid", "60",
            "--part-index", "0", "--replacement-text", "synthetic replacement", "--dry-run", "--text"])
        let command = try #require(parsed as? MessagesEdit)
        #expect(command.text == "synthetic replacement")
    }

    @Test func oversizedOriginalRefusesBeforeWorkerHandoff() throws {
        for original in [String(repeating: "a", count: 4097), String(repeating: "é", count: 2049)] {
            let fx = try fixture(original: original)
            #expect(throws: (any Error).self) {
                try command().resolve(databasePath: fx.path, gate: gate, now: now)
            }
            let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { _ in
                Issue.record("oversized original reached worker handoff")
                return .childRefusedOrFailed("synthetic-refusal")
            })
            let result = try run(fx, flags: ["--experimental-ui-handoff"], dependencies: deps)
            #expect(result.0["ok"] as? Bool == false)
            let error = try #require(result.0["error"] as? [String: Any])
            #expect((error["message"] as? String)?.contains("4,096-byte") == true)
        }
    }

    @Test func previewResolvesExactPartAndReplacement() throws {
        let fx = try fixture()
        let value = try command().resolve(databasePath: fx.path, gate: gate, now: now)
        #expect(value.snapshot.partText == "apple-cli-test original")
        #expect(value.request.replacement == "apple-cli-test replacement")
        #expect(value.request.messageRowid == 60)
    }

    @Test func refusesAmbiguityExpiryAndUnauthorizedSandboxEdits() throws {
        let fx = try fixture()
        #expect(throws: (any Error).self) {
            try command(["--message-guid", "synthetic-edit"]).resolve(databasePath: fx.path, gate: gate, now: now)
        }
        #expect(throws: (any Error).self) {
            try command().resolve(databasePath: fx.path, gate: gate, now: now.addingTimeInterval(900))
        }
        let allowed = MessagesWriteGuard.Gate(willExecute: false, sandboxActive: true, allowedRecipients: ["+12125550100"])
        _ = try command().resolve(databasePath: fx.path, gate: allowed, now: now)
        #expect(throws: (any Error).self) {
            try command(replacement: "removed label").resolve(databasePath: fx.path, gate: allowed, now: now)
        }
        let denied = MessagesWriteGuard.Gate(willExecute: false, sandboxActive: true, allowedRecipients: ["+12125550109"])
        #expect(throws: (any Error).self) {
            try command().resolve(databasePath: fx.path, gate: denied, now: now)
        }
    }

    private func run(_ fx: ChatFixture, flags: [String], dependencies: MessagesCommandDependencies) throws -> ([String: Any], Int32?) {
        let stdout = MemoryOutputSink(), stderr = MemoryOutputSink()
        var code: Int32?
        do {
            try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                try command(flags).run(dependencies: dependencies, databasePath: fx.path, now: { now })
            }
        } catch let exit as ExitCode { code = exit.rawValue }
        return (try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any]), code)
    }

    @Test func dryRunPreviewsWithoutWorkerAndExecutionRequiresOptIn() throws {
        let fx = try fixture()
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { _ in
            Issue.record("dry run or missing opt-in launched worker")
            throw WorkerProtocolError.malformedFrame
        })
        let preview = try run(fx, flags: ["--dry-run", "--execute"], dependencies: deps)
        #expect(preview.1 == nil)
        #expect(preview.0["ok"] as? Bool == true)
        let data = try #require(preview.0["data"] as? [String: Any])
        #expect(data["dry_run"] as? Bool == true)
        #expect(data["previous_text"] as? String == "apple-cli-test original")
        #expect(data["replacement_text"] as? String == "apple-cli-test replacement")
        let refused = try run(fx, flags: [], dependencies: deps)
        #expect(refused.1 != nil)
        #expect(refused.0["ok"] as? Bool == false)
    }

    @Test func workerAcknowledgementAloneDoesNotProvePersistedEdit() throws {
        let fx = try fixture()
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            #expect(try action.preflight(resolved, context) == .requiresMutation)
            for detail in [nil, "edit-persisted-verified"] as [String?] {
                let id = UUID()
                let response = WorkerResponse(schemaVersion: 1, operationID: id, nonce: id, category: .ack, detail: detail)
                #expect(try action.verify(resolved, response, context) == nil)
            }
            return .verificationFailed
        })
        let result = try run(fx, flags: ["--experimental-ui-handoff"], dependencies: deps)
        #expect(result.1 != nil)
        #expect(result.0["ok"] as? Bool == false)
    }

    @Test func uncertainChildAndProtocolFailuresExplainRecovery() throws {
        let fx = try fixture()
        let outcomes: [WorkerObservedOutcome] = [
            .childRefusedOrFailed("edit-unverified"),
            .protocolViolation("synthetic-protocol-failure")
        ]
        for outcome in outcomes {
            let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { _ in outcome })
            let result = try run(fx, flags: ["--experimental-ui-handoff"], dependencies: deps)
            #expect(result.1 != nil)
            #expect(result.0["ok"] as? Bool == false)
            let error = try #require(result.0["error"] as? [String: Any])
            let message = try #require(error["message"] as? String)
            #expect(message.contains("may have occurred"))
            #expect(message.contains("automation status"))
            #expect(message.contains("recover before retrying"))
            #expect(message.contains("Detail:"))
        }
    }

    @Test func verifiedPersistedTransitionProducesExecutedResult() throws {
        let fx = try fixture(), path = fx.path
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            #expect(try action.preflight(resolved, context) == .requiresMutation)
            try persistSyntheticEdit(path: path)
            let id = UUID()
            let response = WorkerResponse(schemaVersion: 1, operationID: id, nonce: id,
                category: .ack, detail: "edit-persisted-verified")
            let cancelled = WorkerObservedContext(deadline: action.deadline, isCancelled: { true })
            #expect(try action.verify(resolved, response, cancelled) == nil)
            let expired = WorkerObservedContext(deadline: .millisecondsFromNow(0), isCancelled: { false })
            #expect(try action.verify(resolved, response, expired) == nil)
            let verification = try #require(try action.verify(resolved, response, context))
            return .observedState(operationID: id, verification: verification)
        })
        let result = try run(fx, flags: ["--experimental-ui-handoff"], dependencies: deps)
        #expect(result.1 == nil)
        #expect(result.0["ok"] as? Bool == true)
        let data = try #require(result.0["data"] as? [String: Any])
        #expect(data["executed"] as? Bool == true)
        #expect(data["dry_run"] as? Bool == false)
        #expect(data["operation_id"] as? String != nil)
    }

}


private func persistSyntheticEdit(path: String) throws {
    let old = "apple-cli-test original", new = "apple-cli-test replacement"
    let events: [[String: Any]] = [old, new].map {
        ["d": 800_000_001, "t": NSArchiver.archivedData(withRootObject: NSAttributedString(string: $0))]
    }
    let summary: [String: Any] = ["ep": [0], "otr": ["0": ["lo": 0, "le": old.utf16.count]], "ec": ["0": events]]
    let summaryBytes = try PropertyListSerialization.data(fromPropertyList: summary, format: .binary, options: 0)
    let body = NSMutableAttributedString(string: new)
    body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0),
        range: NSRange(location: 0, length: body.length))
    let bodyBytes = NSArchiver.archivedData(withRootObject: body)
    func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    var database: OpaquePointer?
    let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { sqlite3_close(database) }
    try #require(opened == SQLITE_OK)
    let sql = "UPDATE message SET attributedBody=X'\(hex(bodyBytes))', date_edited=800000001, message_summary_info=X'\(hex(summaryBytes))' WHERE ROWID=60"
    try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
}
