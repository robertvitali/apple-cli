import Foundation
import Testing
import ArgumentParser
@testable import NotesKit
@testable import AppleKit

/// Characterizes every ordered `.scriptFailed` outcome through an actual read command. The
/// script runner and store are injected; no Apple process or personal store is accessed.
///
/// The three quoted names come from the synthetic diagnostic, not verified command arguments.
/// This matrix proves exclusion of surrounding diagnostics while preserving existing messages;
/// it does not establish caller provenance or a length bound for captured names. Launch failures
/// intentionally retain their diagnostic and are outside this `.scriptFailed` matrix.
@Suite("Notes command diagnostics — mapped script failures exclude surrounding stderr")
struct NotesDiagnosticCommandTests {
    struct Diagnostic: Sendable, CustomStringConvertible {
        let key: String
        let stderr: String
        let code: Int32
        let type: String
        let message: String
        var description: String { key }
    }

    static let cases: [Diagnostic] = [
        Diagnostic(
            key: "authorization", stderr: "Notes got an error: Not authorized to send Apple events to Notes.",
            code: AppleExit.permissionDenied, type: AppleErrorType.permissionDenied,
            message: "Notes automation not authorized. Grant access in System Settings > "
                + "Privacy & Security > Automation, then retry."),
        Diagnostic(
            key: "timeout", stderr: "Notes got an error: AppleEvent timed out. (-1712)",
            code: AppleExit.upstream, type: AppleErrorType.upstream,
            message: "Notes.app timed out. It may be unresponsive or busy syncing; try again."),
        Diagnostic(
            key: "application", stderr: "Notes got an error: Application isn’t running. (-600)",
            code: AppleExit.upstream, type: AppleErrorType.upstream,
            message: "Notes.app is not responding. Try opening Notes.app manually."),
        Diagnostic(
            key: "connection", stderr: "Notes got an error: The connection is invalid.",
            code: AppleExit.upstream, type: AppleErrorType.upstream,
            message: "Lost connection to Notes.app. The app may have crashed or been restarted."),
        Diagnostic(
            key: "note-name", stderr: "Notes got an error: Can’t get note \"Synthetic MiXeD Note\". (-1728)",
            code: AppleExit.notFound, type: AppleErrorType.notFound,
            message: "Note \"Synthetic MiXeD Note\" not found. Verify the title is exact (case-sensitive)."),
        Diagnostic(
            key: "note-id", stderr: "Notes got an error: Can’t get note id \"synthetic-note-id\". (-1728)",
            code: AppleExit.notFound, type: AppleErrorType.notFound,
            message: "Note not found. The note may have been deleted or the ID is invalid."),
        Diagnostic(
            key: "folder-name", stderr: "Notes got an error: Can’t get folder \"Synthetic MiXeD Folder\". (-1728)",
            code: AppleExit.notFound, type: AppleErrorType.notFound,
            message: "Folder \"Synthetic MiXeD Folder\" not found. Use list-folders to see available folders."),
        Diagnostic(
            key: "account-name", stderr: "Notes got an error: Can’t get account \"Synthetic MiXeD Account\". (-1728)",
            code: AppleExit.notFound, type: AppleErrorType.notFound,
            message: "Account \"Synthetic MiXeD Account\" not found. Use list-accounts to see available accounts."),
        Diagnostic(
            key: "already-exists", stderr: "Notes got an error: A synthetic folder already exists. (-48)",
            code: AppleExit.usage, type: AppleErrorType.validation,
            message: "A folder with that name already exists."),
        Diagnostic(
            key: "cannot-delete", stderr: "Notes got an error: Cannot delete the synthetic item.",
            code: AppleExit.upstream, type: AppleErrorType.upstream,
            message: "Cannot delete. The item may be locked or in use."),
        Diagnostic(
            key: "password", stderr: "Notes got an error: This note is password protected.",
            code: AppleExit.usage, type: AppleErrorType.validation,
            message: "Note is password-protected. Unlock it in Notes.app first."),
        Diagnostic(
            key: "changed-listing", stderr: "Notes got an error: Notes changed during listing.",
            code: AppleExit.upstream, type: AppleErrorType.upstream,
            message: "Notes changed during listing (an iCloud sync may have landed mid-read). "
                + "The operation is retried automatically; run it again if this persists."),
        Diagnostic(
            key: "syntax", stderr: "Notes got an error: Syntax error: expected end of line.",
            code: AppleExit.upstream, type: AppleErrorType.upstream,
            message: "Internal error. Please report this issue."),
        Diagnostic(
            key: "generic-not-found", stderr: "Notes got an error: Synthetic specifier failure. (-1728)",
            code: AppleExit.notFound, type: AppleErrorType.notFound,
            message: "Notes could not find the requested item (verify the id/title/folder)."),
        Diagnostic(
            key: "unmapped", stderr: "Notes got an error: Synthetic diagnostic code 12345.",
            code: AppleExit.upstream, type: AppleErrorType.upstream,
            message: "Notes.app returned an error."),
    ]

    @Test("each mapping keeps its contract and excludes surrounding diagnostics", arguments: NotesDiagnosticCommandTests.cases)
    func scriptFailureEnvelope(_ diagnostic: Diagnostic) throws {
        // Markers contain no mapper trigger words or quotes. The quoted names remain inside the
        // diagnostic; only these surrounding markers must be excluded from every output field.
        let prefix = "ZXQ_BEGIN_7319"
        let suffix = "ZXQ_END_8427"
        let rawStderr = prefix + "\n" + diagnostic.stderr + "\n" + suffix
        let runner = FakeNotesRunner()
        runner.handler = { _, _ in
            throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: rawStderr)
        }
        let command = try AccountsCmd.parse([])
        let stdout = MemoryOutputSink()
        let stderr = MemoryOutputSink()
        let streams = CLIStreams(stdout: stdout, stderr: stderr)
        var thrown: Error?
        Output.withStreams(streams) {
            do {
                try command.run(scriptFactory: { quietScript(runner) })
            } catch {
                thrown = error
            }
        }

        let exit = try #require(thrown as? ExitCode)
        #expect(exit.rawValue == diagnostic.code)
        let object = try JSONSerialization.jsonObject(with: stdout.data)
        let envelope = try #require(object as? [String: Any])
        #expect(envelope["tool"] as? String == "notes")
        #expect(envelope["ok"] as? Bool == false)
        #expect(envelope["data"] == nil)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["type"] as? String == diagnostic.type)
        #expect(error["message"] as? String == diagnostic.message)

        let output = String(decoding: stdout.data, as: UTF8.self)
        #expect(!output.contains(prefix))
        #expect(!output.contains(suffix))
        #expect(stderr.data.isEmpty)
        #expect(runner.invocationCount > 0)
        #expect(runner.allArguments.isEmpty,
                "quoted diagnostic names are preserved without pretending they came from caller argv")
    }
}
