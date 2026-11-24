import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleKit
@testable import MessagesKit

@Suite struct MessagesAttachmentCommandExecutionTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        let body = NSMutableAttributedString(string: "\u{fffc}")
        body.addAttribute(NSAttributedString.Key("__kIMMessagePartAttributeName"), value: NSNumber(value: 0), range: NSRange(location: 0, length: 1))
        body.addAttribute(NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"), value: "a10", range: NSRange(location: 0, length: 1))
        try fx.insertMessage(rowid: 60, guid: "synthetic-attachment-message", attributedBody: NSArchiver.archivedData(withRootObject: body),
            chatRowid: 3, date: fx.base, cacheHasAttachments: true)
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,10); ALTER TABLE attachment ADD COLUMN transfer_state; UPDATE attachment SET transfer_state=5 WHERE ROWID=10")
        return fx
    }
    private func dependencies(_ fx: ChatFixture,
        launch: @escaping @Sendable (WorkerObservedAction) throws -> WorkerObservedOutcome) -> MessagesCommandDependencies {
        let path = fx.path, home = fx.homePath
        return .fixture(makeChatDB: { try ChatDB(path: path, book: $0, homeDirectoryForTilde: home) }, launchObservedWorker: launch)
    }
    private func run(_ fx: ChatFixture, flags: [String], dependencies: MessagesCommandDependencies) throws -> (String, Int32?) {
        let stdout = MemoryOutputSink(), stderr = MemoryOutputSink()
        var code: Int32?
        do {
            try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                try MessagesAttachmentRetrieve.parse(["--chat-rowid", "3", "--message-rowid", "60", "--part-index", "0"] + flags)
                    .run(dependencies: dependencies, databasePath: fx.path, confirmDownload: { data, _, context in
                        let payload = try JSONDecoder().decode(MessagesAttachmentRetrievalRequest.self, from: data)
                        let observation = MessagesAttachmentDownloadObservation(payload: payload, databasePath: fx.path,
                                                                               homeDirectory: fx.homePath)
                        return try observation.read(context.deadline, verification: true,
                                                    diagnostic: MessagesAttachmentDiagnostic()).outcome == .downloaded
                    })
            }
        } catch let exit as ExitCode { code = exit.rawValue }
        return (String(decoding: stdout.data, as: UTF8.self), code)
    }

    private func decodedData(_ output: String) throws -> [String: Any] {
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(envelope["ok"] as? Bool == true)
        return try #require(envelope["data"] as? [String: Any])
    }

    @Test func dryRunWinsAndOptInIsRequiredBeforeLaunch() throws {
        let fx = try fixture()
        let deps = dependencies(fx) { _ in
            Issue.record("preview or missing opt-in launched a worker")
            throw WorkerProtocolError.malformedFrame
        }
        let preview = try run(fx, flags: ["--dry-run", "--execute"], dependencies: deps)
        #expect(preview.1 == nil)
        #expect(try decodedData(preview.0)["dry_run"] as? Bool == true)
        let refused = try run(fx, flags: [], dependencies: deps)
        #expect(refused.1 != nil)
        #expect(refused.0.contains("experimental-ui-handoff"))
    }

    @Test func retrievalChecksExpectedAttachmentBeforeLaunchingWorker() throws {
        let fx = try fixture()
        let deps = dependencies(fx) { _ in
            Issue.record("a preview or mismatched identity reached the worker")
            throw WorkerProtocolError.malformedFrame
        }
        let matching = ["--expected-attachment-guid", "a10"]
        let preview = try run(fx, flags: matching + ["--dry-run"], dependencies: deps)
        #expect(preview.1 == nil)
        #expect(try decodedData(preview.0)["dry_run"] as? Bool == true)

        for expected in ["original-transfer", "A10", "a10 ", ""] {
            let flags = ["--expected-attachment-guid", expected]
            for mode in [["--dry-run"], ["--execute", "--experimental-ui-handoff"]] {
                let refused = try run(fx, flags: flags + mode, dependencies: deps)
                #expect(refused.1 == AppleExit.usage)
                #expect(refused.0.contains("expected attachment GUID"))
            }
        }
        // A second option cannot replace a stale guard supplied by the caller.
        let conflict = try run(fx, flags: ["--expected-attachment-guid", "stale"] + matching
                               + ["--dry-run"], dependencies: deps)
        #expect(conflict.1 == AppleExit.usage)
    }

    @Test func expectedAttachmentGUIDUsesExactUTF8() throws {
        let fx = try fixture()
        let stored = "a\u{301}"
        let body = NSAttributedString(string: "\u{fffc}", attributes: [
            NSAttributedString.Key("__kIMMessagePartAttributeName"): NSNumber(value: 0),
            NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"): stored,
        ])
        let archive = NSArchiver.archivedData(withRootObject: body).map { String(format: "%02x", $0) }.joined()
        try fx.exec("""
            UPDATE message SET attributedBody=X'\(archive)' WHERE ROWID=60;
            UPDATE attachment SET guid=CAST(X'61CC81' AS TEXT) WHERE ROWID=10;
            """)
        let deps = dependencies(fx) { _ in
            Issue.record("GUID preview launched a worker")
            throw WorkerProtocolError.malformedFrame
        }
        let equal = try run(fx, flags: ["--dry-run", "--expected-attachment-guid", stored], dependencies: deps)
        #expect(equal.1 == nil)
        let composed = try run(fx, flags: ["--dry-run", "--expected-attachment-guid", "\u{e1}"], dependencies: deps)
        #expect(composed.1 == AppleExit.usage)
        #expect(composed.0.contains("expected attachment GUID"))
    }

    @Test func verifierRejectsGenericACKFailureAndExpiredContext() throws {
        let fx = try fixture()
        let deps = dependencies(fx) { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            #expect(try action.preflight(resolved, context) == .requiresMutation)
            let id = UUID()
            for detail in [nil, "ok", "attachment-retrieval-failed"] as [String?] {
                let response = WorkerResponse(schemaVersion: 1, operationID: id, nonce: id, category: .ack, detail: detail)
                #expect(try action.verify(resolved, response, context) == nil)
            }
            for detail in ["attachment-retrieval-downloaded-verified", "attachment-retrieval-already-downloaded-verified"] {
                let response = WorkerResponse(schemaVersion: 1, operationID: id, nonce: id, category: .ack, detail: detail)
                #expect(try action.verify(resolved, response, context) != nil)
                let cancelled = WorkerObservedContext(deadline: action.deadline, isCancelled: { true })
                #expect(try action.verify(resolved, response, cancelled) == nil)
                let failed = WorkerResponse(schemaVersion: 1, operationID: id, nonce: id, category: .failed, detail: detail)
                #expect(try action.verify(resolved, failed, context) == nil)
            }
            return .verificationFailed
        }
        let result = try run(fx, flags: ["--experimental-ui-handoff"], dependencies: deps)
        #expect(result.1 != nil)
        #expect(result.0.contains("recover before retrying"))
    }

    @Test(arguments: ["pending", "unknown", "missing-file", "new-member", "different-message", "participant", "different-native-part"],
          ["attachment-retrieval-downloaded-verified", "attachment-retrieval-already-downloaded-verified"])
    func staleWorkerSuccessCannotVerifyAttachment(_ change: String, _ detail: String) throws {
        let fx = try fixture()
        let path = fx.path, localFile = fx.presentAttachmentPath
        let deps = dependencies(fx) { action in
            let resolved = try action.resolve()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            #expect(try action.preflight(resolved, context) == .requiresMutation)
            let response = WorkerResponse(schemaVersion: 1, operationID: UUID(), nonce: UUID(), category: .ack, detail: detail)
            let statement: String
            switch change {
            case "missing-file":
                try FileManager.default.moveItem(atPath: localFile, toPath: localFile + ".moved")
                statement = "SELECT 1"
            case "pending": statement = "UPDATE attachment SET transfer_state=4 WHERE ROWID=10"
            case "unknown": statement = "UPDATE attachment SET transfer_state=NULL WHERE ROWID=10"
            case "new-member": statement = "INSERT INTO message_attachment_join VALUES(60,11)"
            case "different-message": statement = "UPDATE message SET guid='different' WHERE ROWID=60"
            case "participant": statement = "UPDATE handle SET id='+12125550101' WHERE ROWID=1"
            default: statement = "UPDATE message SET attributedBody=NULL WHERE ROWID=60"
            }
            var db: OpaquePointer?
            try #require(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            defer { sqlite3_close(db) }
            try #require(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK)
            #expect(try action.verify(resolved, response, context) == nil)
            return .verificationFailed
        }
        let result = try run(fx, flags: ["--experimental-ui-handoff"], dependencies: deps)
        #expect(result.1 != nil)
    }

    @Test func verifiedResultIsExplicitlyExecuted() throws {
        let fx = try fixture()
        let deps = dependencies(fx) { action in
            let resolved = try action.resolve(), id = UUID()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            #expect(try action.preflight(resolved, context) == .requiresMutation)
            let response = WorkerResponse(schemaVersion: 1, operationID: id, nonce: id,
                category: .ack, detail: "attachment-retrieval-already-downloaded-verified")
            let verification = try #require(try action.verify(resolved, response, context))
            return .observedState(operationID: id, verification: verification)
        }
        let result = try run(fx, flags: ["--experimental-ui-handoff"], dependencies: deps)
        #expect(result.1 == nil)
        #expect(try decodedData(result.0)["dry_run"] as? Bool == false)
        #expect(try decodedData(result.0)["executed"] as? Bool == true)
    }
    @Test func diagnosticCanReportFailureButCannotVerifySuccess() throws {
        let fx = try fixture()
        let detail = "attachment-unverified:press:other"
        let deps = dependencies(fx) { action in
            let resolved = try action.resolve(), id = UUID()
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            for category in [WorkerResponseCategory.ack, .failed, .refused] {
                let response = WorkerResponse(schemaVersion: 1, operationID: id, nonce: id,
                    category: category, detail: detail)
                #expect(try action.verify(resolved, response, context) == nil)
            }
            return .childRefusedOrFailed(detail)
        }
        let result = try run(fx, flags: ["--experimental-ui-handoff"], dependencies: deps)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(result.0.utf8)) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(envelope["ok"] as? Bool == false)
        #expect(error["type"] as? String == "upstream_error")
        #expect(error["message"] as? String == detail)
        #expect(result.1 == 69)
    }

}

extension MessagesAttachmentCommandExecutionTests {
    @Test(arguments: WorkerAttachmentStatus.allCases)
    func statusEmitsOnlyExactTargetAndWorkerState(_ state: WorkerAttachmentStatus) throws {
        let fx = try fixture()
        let command = try #require(try MessagesCommand.parseAsRoot(["attachment", "status", "--dry-run",
            "--chat-rowid", "3", "--message-rowid", "60", "--part-index", "0",
            "--expected-attachment-guid", "a10"]) as? MessagesAttachmentStatus)
        let out = MemoryOutputSink()
        var calls = 0
        try Output.withStreams(CLIStreams(stdout: out, stderr: MemoryOutputSink())) {
            try command.run(databasePath: fx.path) { bytes, deadline in
                calls += 1
                let payload = try JSONDecoder().decode(MessagesAttachmentRetrievalRequest.self, from: bytes)
                #expect(payload.selectedAttachmentGUID == "a10")
                #expect(!deadline.expired)
                return state
            }
        }
        let data = try decodedData(String(decoding: out.data, as: UTF8.self))
        #expect(calls == 1)
        #expect(Set(data.keys) == ["chat_rowid", "message_rowid", "native_part", "state"])
        #expect(data["chat_rowid"] as? Int == 3)
        #expect(data["message_rowid"] as? Int == 60)
        #expect(data["native_part"] as? Int == 0)
        #expect(data["state"] as? String == state.rawValue)
    }

    @Test func staleStatusTargetEmitsErrorBeforeWorker() throws {
        let fx = try fixture()
        let command = try MessagesAttachmentStatus.parse(["--chat-rowid", "3", "--message-rowid", "60",
            "--part-index", "0", "--expected-attachment-guid", "stale-private-fixture", "--dry-run"])
        let out = MemoryOutputSink()
        #expect(throws: ExitCode.self) {
            try Output.withStreams(CLIStreams(stdout: out, stderr: MemoryOutputSink())) {
                try command.run(databasePath: fx.path) { _, _ in
                    Issue.record("Stale target reached the status worker")
                    return .pending
                }
            }
        }
        let envelope = try #require(JSONSerialization.jsonObject(with: out.data) as? [String: Any])
        #expect(envelope["ok"] as? Bool == false)
        #expect(envelope["data"] == nil)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["message"] as? String == "the selected part does not match the expected attachment GUID")
        #expect(!String(decoding: out.data, as: UTF8.self).contains("stale-private-fixture"))
    }
}
