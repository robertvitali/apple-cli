import ArgumentParser
import Foundation
import SQLite3
import Testing
import os
@testable import AppleKit
@testable import MessagesKit

@Suite("Conversation creation command boundary")
struct MessagesConversationCommandTests {
    private func fixture() throws -> ChatFixture {
        let fx = try ChatFixture()
        try fx.exec("ALTER TABLE message ADD COLUMN is_sent INTEGER;")
        return fx
    }
    private func command(_ flags: [String] = [], recipients: [String] = ["+12125550100"],
                         message: String = "apple-cli-test creation", service: String = "imessage") throws -> MessagesConversationCreate {
        try MessagesConversationCreate.parse(recipients.flatMap { ["--recipient", $0] }
            + ["--message", message, "--service", service] + flags)
    }
    private func run(_ command: MessagesConversationCreate, path: String,
                     dependencies: MessagesCommandDependencies = .fixture(),
                     contacts: @escaping (WorkerObservedContext) throws -> [MessagesConversationRawContacts.Record] = { _ in [] }) throws -> ([String: Any], Int32?) {
        let stdout = MemoryOutputSink(), stderr = MemoryOutputSink()
        var code: Int32?
        do {
            try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                try command.run(dependencies: dependencies, databasePath: path, loadContacts: contacts)
            }
        } catch let exit as ExitCode { code = exit.rawValue }
        return (try #require(JSONSerialization.jsonObject(with: stdout.data) as? [String: Any]), code)
    }

    @Test func initialTextAndExplicitServiceAreRequiredAndTextFlagIsDistinct() throws {
        #expect(throws: (any Error).self) { try MessagesConversationCreate.parse(["--recipient", "+12125550100"]) }
        let parsed = try command(["--text", "--dry-run"])
        #expect(parsed.message == "apple-cli-test creation")
        #expect(parsed.global.text)
    }

    @Test func dryRunIsAdvisoryAndCannotLaunchWorkerOrReadState() throws {
        let fx = try fixture(), before = try Data(contentsOf: URL(fileURLWithPath: fx.path))
        let deps = MessagesCommandDependencies.fixture(messagesAutomationStateRoot: {
            Issue.record("preview accessed journal"); return "/synthetic-unused"
        }, launchObservedWorker: { _ in Issue.record("preview launched worker"); return .timedOut })
        let result = try run(command(["--dry-run", "--execute"]), path: fx.path, dependencies: deps)
        #expect(result.0["ok"] as? Bool == true)
        #expect(result.1 == nil)
        let data = try #require(result.0["data"] as? [String: Any])
        #expect(data["dry_run"] as? Bool == true)
        #expect(data["executed"] as? Bool == false)
        let preview = try #require(data["preview"] as? [String: Any])
        #expect(preview["advisory"] as? Bool == true)
        #expect(preview["initial_send_required"] as? Bool == true)
        #expect(data["created"] == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fx.path)) == before)
    }

    @Test func optInAndPendingGatePrecedeContactsAndDatabaseReads() throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { _ in
            calls.withLock { $0 += 1 }
            return .requestNotSent("pending-operation-exists:synthetic")
        })
        for flags in [[], ["--experimental-ui-handoff"]] {
            let result = try run(command(flags, recipients: ["Alice"]), path: "/synthetic-missing", dependencies: deps,
                contacts: { _ in Issue.record("read before lease resolution"); return [] })
            #expect(result.0["ok"] as? Bool == false)
            #expect(result.1 != nil)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func fabricatedSuccessOrAlreadyStateDoesNotCreateIDs() throws {
        let fx = try fixture()
        for observed in [true, false] {
            let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { _ in
                observed ? .observedState(operationID: UUID(), verification: "synthetic") : .alreadyInDesiredState("synthetic")
            })
            let result = try run(command(["--experimental-ui-handoff"]), path: fx.path, dependencies: deps)
            #expect(result.0["ok"] as? Bool == false)
            #expect(result.1 != nil)
            #expect(result.0["data"] == nil)
        }
    }

    @Test func independentPersistedVerificationProducesExactObservedIdentity() throws {
        let fx = try fixture()
        let path = fx.path
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { action in
            let context = WorkerObservedContext(deadline: action.deadline, isCancelled: { false })
            let resolved = try action.resolve()
            #expect(try action.preflight(resolved, context) == .requiresMutation)
            var db: OpaquePointer?
            #expect(sqlite3_open(path, &db) == SQLITE_OK)
            let opened = try #require(db)
            defer { sqlite3_close(opened) }
            #expect(sqlite3_exec(opened, """
                INSERT INTO message(ROWID,guid,text,is_from_me,is_sent,error,service)
                VALUES(60,'synthetic-created','apple-cli-test creation',1,1,0,'iMessage');
                INSERT INTO chat_message_join VALUES(3,60);
                """, nil, nil, nil) == SQLITE_OK)
            let id = UUID()
            let response = WorkerResponse(schemaVersion: 1, operationID: id, nonce: UUID(), category: .ack,
                                          detail: "conversation-create-persisted-verified")
            let verification = try #require(try action.verify(resolved, response, context))
            return .observedState(operationID: id, verification: verification)
        })
        let result = try run(command(["--experimental-ui-handoff"]), path: fx.path, dependencies: deps)
        #expect(result.0["ok"] as? Bool == true)
        let data = try #require(result.0["data"] as? [String: Any])
        #expect(data["message_rowid"] as? Int == 60)
        #expect(data["chat_rowid"] as? Int == 3)
        #expect(data["conversation_observation"] as? String == "present_at_baseline")
        #expect(data["creation_attribution"] as? String == "unproven")
        #expect(data["verification"] as? String == "Observed one exact sent iMessage with verified conversation membership; creation attribution remains unproven.")
        #expect(data["created"] == nil)
    }

    @Test func unresolvedRecipientsEmitCandidatesWithoutInventingConversation() throws {
        let records: [MessagesConversationRawContacts.Record] = [
            .init(fullName: "Alice Example", nickname: "", rawAddress: "+12125550100"),
            .init(fullName: "Alice Example", nickname: "", rawAddress: "+12125550101")]
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { action in
            do { _ = try action.resolve(); Issue.record("ambiguous plan resolved") } catch { }
            return .requestNotSent("synthetic")
        })
        for flags in [["--dry-run"], ["--experimental-ui-handoff"]] {
            let result = try run(command(flags, recipients: ["Alice Example"]), path: "/synthetic-missing",
                                 dependencies: deps, contacts: { _ in records })
            #expect(result.0["ok"] as? Bool == true)
            let data = try #require(result.0["data"] as? [String: Any])
            #expect(data["executed"] as? Bool == false)
            let unresolved = try #require(data["unresolved_recipients"] as? [[String: Any]])
            #expect(unresolved.count == 1)
            #expect((unresolved[0]["candidates"] as? [[String: Any]])?.count == 2)
            #expect(data["chat_rowid"] == nil)
        }
    }

    @Test func sandboxRefusalsKeepTheirErrorCategoryAfterLeaseResolution() throws {
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { action in
            do { _ = try action.resolve(); Issue.record("sandbox violation resolved") } catch { }
            return .requestNotSent("synthetic")
        })
        for flags in [["--dry-run", "--test-mode"], ["--experimental-ui-handoff", "--test-mode"]] {
            let result = try run(command(flags), path: "/synthetic-missing", dependencies: deps)
            let error = try #require(result.0["error"] as? [String: Any])
            #expect(error["type"] as? String == "safety_violation")
            #expect(error["sandbox"] as? Bool == true)
            #expect(result.1 == 77)
        }
    }

    @Test func errorsDoNotEchoPrivateDependencyDetails() throws {
        let marker = "synthetic-private-path-and-body"
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { _ in
            .childRefusedOrFailed(marker)
        })
        let result = try run(command(["--experimental-ui-handoff"]), path: "/synthetic-missing", dependencies: deps)
        #expect(result.0["ok"] as? Bool == false)
        #expect(!String(describing: result.0).contains(marker))
        let preview = try run(command(["--dry-run"], recipients: ["Alice"]), path: "/synthetic-missing", contacts: { _ in
            throw NSError(domain: marker, code: 1)
        })
        #expect(preview.0["ok"] as? Bool == false)
        #expect(!String(describing: preview.0).contains(marker))
    }
    @Test(arguments: ["+012", "+12125550100 ext 42", "Alice\n", "Alice Example"])
    func recipientValidationMatchesPreviewAndExecution(_ input: String) throws {
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { action in
            do { _ = try action.resolve(); Issue.record("invalid recipient produced a handoff binding") } catch { }
            return .requestNotSent("synthetic-input-refusal")
        })
        for flags in [["--dry-run"], ["--experimental-ui-handoff"]] {
            let result = try run(command(flags, recipients: [input]), path: "/synthetic-unavailable",
                dependencies: deps, contacts: { _ in
                    [.init(fullName: "Alice Example", nickname: "", rawAddress: "+12125550100 ext 42")]
                })
            let error = try #require(result.0["error"] as? [String: Any])
            #expect(error["type"] as? String == "validation_error")
            #expect(result.1 == 64)
        }
    }

    @Test func encodedSizeEligibilityMatchesPreviewAndExecution() throws {
        let fx = try fixture()
        let domain = String(repeating: "b", count: 63) + "." + String(repeating: "c", count: 63)
            + "." + String(repeating: "d", count: 61)
        let recipients = (0..<32).map { String(repeating: "a", count: 60) + String($0) + "@" + domain }
        let deps = MessagesCommandDependencies.fixture(launchObservedWorker: { action in
            do { _ = try action.resolve(); Issue.record("oversized request produced a handoff binding") } catch { }
            return .requestNotSent("synthetic-size-refusal")
        })
        for (addresses, text) in [( ["+12125550100"], String(repeating: String(Unicode.Scalar(UInt8(92))), count: 2048)),
                                   (recipients, "apple-cli-test initial")] {
            for flags in [["--dry-run"], ["--experimental-ui-handoff"]] {
                let result = try run(command(flags, recipients: addresses, message: text),
                                     path: fx.path, dependencies: deps)
                let error = try #require(result.0["error"] as? [String: Any])
                #expect(error["type"] as? String == "validation_error")
                #expect((error["message"] as? String)?.contains("4,096") == true)
                #expect(result.1 == 64)
            }
        }
    }

    @Test func textPreviewShowsProposedSendAndEscapesControls() throws {
        let fx = try fixture(), body = "apple-cli-test inspect\n\u{001b}[31m"
        let stdout = MemoryOutputSink(), stderr = MemoryOutputSink()
        let deps = MessagesCommandDependencies.fixture(messagesAutomationStateRoot: {
            Issue.record("text preview accessed journal"); return "/synthetic-unused"
        }, launchObservedWorker: { _ in
            Issue.record("text preview launched worker"); return .timedOut
        })
        try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
            try command(["--dry-run", "--text"], message: body).run(dependencies: deps,
                databasePath: fx.path, loadContacts: { _ in [] })
        }
        let output = String(decoding: stdout.data, as: UTF8.self)
        #expect(output.contains("+12125550100"))
        #expect(output.contains("iMessage"))
        #expect(output.contains(String(reflecting: body)))
        #expect(output.contains("iMessage;-;+12125550100"))
        #expect(output.contains("3"))
        #expect(!output.contains("\u{001b}"))
    }

}
