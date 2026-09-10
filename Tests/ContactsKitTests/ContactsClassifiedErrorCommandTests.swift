import Foundation
import Testing
import ArgumentParser
@testable import ContactsKit
import AppleKit
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
