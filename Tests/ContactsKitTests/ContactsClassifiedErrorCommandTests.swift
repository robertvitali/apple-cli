import Foundation
import Testing
import ArgumentParser
@testable import ContactsKit
@testable import AppleKit
import TestSupport

@Suite("Contacts classified AppleScript command errors")
struct ContactsClassifiedErrorCommandTests {
    @Test("every script command preserves not_found without exposing surrounding stderr")
    func notFound() throws {
        for diagnostic in ["execution error: Invalid index. (-1719)",
                           "Contacts got an error: Can't get person 1",
                           "Contacts got an error: Can’t get person 1"] {
            try checkCommands(diagnostic: diagnostic, notFound: true)
        }
    }

    @Test("every script command preserves its generic failure message without exposing stderr")
    func genericFailure() throws {
        try checkCommands(diagnostic: "synthetic unrecognized automation failure", notFound: false)
    }

    @Test("script commands preserve marked output-limit errors and identical unmarked errors")
    func outputLimitErrorsAtCommandBoundary() throws {
        let cases: [(error: AppleError, type: String, exit: Int32, message: String)] = [
            (.outputLimitEnvironmentInvalid(), AppleErrorType.validation, AppleExit.usage,
             "APPLE_SCRIPT_MAX_OUTPUT_BYTES must be a positive decimal byte count"),
            (.outputLimitExplicitInvalid(), AppleErrorType.validation, AppleExit.usage,
             "maximumOutputBytes must be a positive byte count"),
            (.outputLimitExceeded(maximumOutputBytes: 17), AppleErrorType.upstream, AppleExit.upstream,
             "osascript output exceeded the configured limit of 17 bytes; no partial result returned. "
             + "The operation may have completed; verify its state before retrying."),
        ]
        try TestEnvironment.withoutWriteModeOverrides {
            let commands: [(arguments: [String], run: (ContactsStore) throws -> Void)] = [
                (["c1"], { store in
                    try NoteGetCommand.parse(["c1"]).run(storeFactory: { store })
                }),
                (["c1", "synthetic note"], { store in
                    try NoteSetCommand.parse(["c1", "--note", "synthetic note"])
                        .run(storeFactory: { store })
                }),
                (["c1", "g1"], { store in
                    try GroupsRemoveCommand.parse(["c1", "g1"]).run(storeFactory: { store })
                }),
            ]
            for item in cases {
                for marked in [true, false] {
                    // The public initializer cannot manufacture provenance from identical text.
                    let injected = marked ? item.error
                        : AppleError(type: item.error.type, message: item.error.message,
                                     exitCode: item.error.exitCode)
                    #expect(AppleScriptRunner.isOutputLimitError(injected) == marked)
                    for command in commands {
                        let backend = FakeContactsBackend()
                        backend.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
                        backend.groupLookup = [fakeGroup(name: "apple-cli-test group")]
                        backend.scriptError = injected
                        let stdout = MemoryOutputSink()
                        let stderr = MemoryOutputSink()
                        var exit: Int32?
                        do {
                            try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                                try command.run(ContactsStore(backend: backend))
                            }
                        } catch let code as ExitCode {
                            exit = code.rawValue
                        }
                        #expect(backend.scriptCalls.count == 1)
                        #expect(backend.scriptCalls.first?.arguments == command.arguments)
                        #expect(backend.executed.isEmpty)
                        #expect(exit == item.exit)
                        let envelope = try contactsEnvelope(stdout)
                        #expect(Set(envelope.keys) == Set(["schema_version", "tool", "ok", "error"]))
                        #expect(envelope["schema_version"] as? Int == 1)
                        #expect(envelope["tool"] as? String == "contacts")
                        #expect(envelope["ok"] as? Bool == false)
                        let error = try #require(envelope["error"] as? [String: Any])
                        #expect(Set(error.keys) == Set(["type", "message"]))
                        #expect(error["type"] as? String == item.type)
                        #expect(error["message"] as? String == item.message)
                        #expect(stderr.data.isEmpty)
                    }
                }
            }
        }
    }


    private func checkCommands(diagnostic: String, notFound: Bool) throws {
        try TestEnvironment.withoutWriteModeOverrides {
            let prefix = "apple-cli-test-stderr-prefix"
            let suffix = "apple-cli-test-stderr-suffix"
            let rawStderr = "\(prefix)\n\(diagnostic)\n\(suffix)"
            let commands: [(operation: String, notFoundMessage: String,
                            run: (ContactsStore) throws -> Void)] = [
                ("read_note", "Contact not found: 'c1'", { store in
                    try NoteGetCommand.parse(["c1"]).run(storeFactory: { store })
                }),
                ("write_note", "Contact not found: 'c1'", { store in
                    try NoteSetCommand.parse(["c1", "--note", "synthetic note"])
                        .run(storeFactory: { store })
                }),
                ("remove_contact_from_group", "Contact or group not found (contact='c1', group='g1')", { store in
                    try GroupsRemoveCommand.parse(["c1", "g1"]).run(storeFactory: { store })
                }),
            ]
            for command in commands {
                let backend = FakeContactsBackend()
                backend.contactsByIdentifier["c1"] = fakeContact(given: "apple-cli-test Jane", family: "Doe")
                backend.groupLookup = [fakeGroup(name: "apple-cli-test group")]
                backend.scriptError = AppleScriptRunner.RunError.scriptFailed(status: 2, stderr: rawStderr)
                let stdout = MemoryOutputSink()
                let stderr = MemoryOutputSink()
                var exit: Int32?
                do {
                    try Output.withStreams(CLIStreams(stdout: stdout, stderr: stderr)) {
                        try command.run(ContactsStore(backend: backend))
                    }
                } catch let code as ExitCode {
                    exit = code.rawValue
                }
                #expect(backend.scriptCalls.count == 1)
                #expect(exit == (notFound ? AppleExit.notFound : AppleExit.unknown))
                let envelope = try contactsEnvelope(stdout)
                #expect(envelope["ok"] as? Bool == false)
                #expect(envelope["tool"] as? String == "contacts")
                let error = try #require(envelope["error"] as? [String: Any])
                #expect(error["type"] as? String == (notFound ? AppleErrorType.notFound : AppleErrorType.unknown))
                let expectedMessage = notFound ? command.notFoundMessage
                    : "\(command.operation) failed: Contacts automation via osascript failed. Ensure Contacts.app is "
                        + "available and Automation access to Contacts is granted (System Settings → Privacy "
                        + "& Security → Automation)."
                #expect(error["message"] as? String == expectedMessage)
                let output = String(decoding: stdout.data, as: UTF8.self)
                #expect(!output.contains(prefix))
                #expect(!output.contains(suffix))
                #expect(!output.contains(diagnostic))
                #expect(stderr.data.isEmpty)
            }
        }
    }
}
