import ArgumentParser
import Foundation
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
        try fx.exec("INSERT INTO message_attachment_join VALUES(60,10)")
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
                    .run(dependencies: dependencies, databasePath: fx.path)
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
}
