import Foundation
import Testing
import ArgumentParser
@testable import NotesKit
@testable import AppleKit

// Shared fakes for the Notes command-layer suites.
//
// Between them they neutralize BOTH boundaries a Notes command can reach:
//
//   * Notes.app, via `AppleScriptRunning` — `FakeNotesRunner` records the script SOURCE it was
//     handed alongside the argv, which is what makes the injection invariant assertable at all.
//     An argv-only assertion is positive-only ("the hostile value appears at arguments[N]") and
//     cannot tell argv-passing apart from argv-passing PLUS interpolation into the source.
//   * `NoteStore.sqlite`, via `NotesStoreReading` — `StubNotesStore` answers from in-memory
//     values, so no test in this target opens the operator's real Notes database.
//
// The process ENVIRONMENT is neutralized differently, and deliberately not with a lock: every
// write test drives the command through a `NotesWriteEnv` naming test-owned variables that
// nothing else reads, and pins the sandbox label explicitly. swift-testing runs suites in
// PARALLEL over one process environment, so a suite that read the real `APPLE_TEST_MODE` /
// `APPLE_DRY_RUN` / `APPLE_TEST_SANDBOX` would race every other suite that writes them; the seam
// removes the shared state instead of serializing around it. See `pinnedWriteEnv` below.

// MARK: - AppleScript boundary

/// Records every `(script, argv)` pair and answers from a scripted queue or a handler.
///
/// `@unchecked Sendable` confinement argument: no field is synchronized, which is safe only
/// because a fake is built inside one test and never escapes it. swift-testing runs a single test
/// body on one task, so there is no concurrent access. Sharing one across concurrent work would
/// break that; don't.
final class FakeNotesRunner: AppleScriptRunning, @unchecked Sendable {
    /// What happens once the scripted results run out.
    ///
    /// `.fail` (the default) THROWS a named error rather than returning `""`. The empty string is
    /// a silent trap on wrappers that treat "" as a legitimate value — `getNoteContent` maps it to
    /// a `not_found`, `listAccounts` maps it to "no accounts" — so a forgotten stub would assert
    /// against a fabricated answer instead of failing on the missing stub.
    ///
    /// `.empty` is for the wrappers that legitimately probe until empty: `createFolder` walks each
    /// path segment with a `try?` existence check, and `healthCheck`/`doctor` swallow failures by
    /// design.
    enum Exhaustion { case fail, empty }

    var results: [String] = []
    var whenExhausted: Exhaustion = .fail
    /// Consulted BEFORE the queue. Return nil to fall through to `results`; throw to simulate an
    /// osascript failure for one specific script. Receives the script source and the argv, so a
    /// multi-call wrapper can be answered by what it actually asked for rather than by call order.
    var handler: ((String, [String]) throws -> String?)?

    private(set) var scripts: [String] = []
    private(set) var arguments: [[String]] = []

    var invocationCount: Int { scripts.count }
    var neverCalled: Bool { scripts.isEmpty }
    /// Every argv value the runner was ever handed, flattened — the "did the user's text travel as
    /// an argument" side of the injection invariant.
    var allArguments: [String] { arguments.flatMap { $0 } }

    init(results: [String] = [], whenExhausted: Exhaustion = .fail) {
        self.results = results
        self.whenExhausted = whenExhausted
    }

    func run(_ script: String, arguments args: [String]) throws -> String {
        scripts.append(script)
        arguments.append(args)
        if let handler, let out = try handler(script, args) { return out }
        if !results.isEmpty { return results.removeFirst() }
        switch whenExhausted {
        case .empty: return ""
        case .fail:
            throw AppleError.upstream(
                "FakeNotesRunner: no scripted result left for call #\(scripts.count) — stub one, or "
                + "set `whenExhausted = .empty` if this wrapper legitimately probes until empty.")
        }
    }
}

/// The FAIL-CLOSED runner: every call throws. Pass it wherever Notes.app must NOT be reached — a
/// dry-run preview, a validation refusal, a gate that should fire before any script runs. If a
/// refactor moves an AppleScript call above the guard, this goes red instead of mutating the
/// operator's Notes library.
///
/// `@unchecked Sendable`: same single-test confinement argument as `FakeNotesRunner`.
final class ThrowingNotesRunner: AppleScriptRunning, @unchecked Sendable {
    private(set) var attempts: [[String]] = []
    var neverCalled: Bool { attempts.isEmpty }

    func run(_ script: String, arguments: [String]) throws -> String {
        attempts.append(arguments)
        throw AppleError.upstream("ThrowingNotesRunner: this code path must not reach Notes.app")
    }
}

// MARK: - NoteStore.sqlite boundary

/// In-memory `NotesStoreReading`. Every answer is a stored value, so no test that uses it opens a
/// SQLite file of any kind — least of all the operator's.
///
/// `@unchecked Sendable`: same single-test confinement argument as `FakeNotesRunner`.
final class StubNotesStore: NotesStoreReading, @unchecked Sendable {
    var metadataOutcome = NotesStore.MetadataOutcome(metadata: NotesMetadata(), error: nil, message: nil)
    var checklistOutcome = NotesStore.ChecklistOutcome(items: [], error: nil, message: nil)
    var link: String?
    var sync = NotesSyncStatus()
    var storeExists = true
    var fda = true

    private(set) var metadataQueries: [String] = []
    private(set) var checklistQueries: [String] = []
    private(set) var linkQueries: [String] = []

    func metadata(noteId: String) -> NotesStore.MetadataOutcome {
        metadataQueries.append(noteId)
        return metadataOutcome
    }
    func checklistItems(noteId: String) -> NotesStore.ChecklistOutcome {
        checklistQueries.append(noteId)
        return checklistOutcome
    }
    func noteLink(noteId: String) -> String? {
        linkQueries.append(noteId)
        return link
    }
    func syncStatus() -> NotesSyncStatus { sync }
    var dbExists: Bool { storeExists }
    func hasFDA() -> Bool { fda }

    /// A store that reports no checklist data — the shape most command tests want, because it
    /// keeps `get-markdown` enrichment out of the assertion.
    static func quiet() -> StubNotesStore {
        let s = StubNotesStore()
        s.checklistOutcome = NotesStore.ChecklistOutcome(
            items: nil, error: .noChecklists, message: "This note does not contain any checklist items.")
        return s
    }
}

/// A `NotesScript` with BOTH boundaries neutralized: the caller's fake runner for Notes.app, and a
/// `StubNotesStore.quiet()` for `NoteStore.sqlite`.
///
/// One shared definition rather than a private copy per suite: `NotesScript.init` requires `store:`
/// (see its doc), so every command suite needs this pairing, and six byte-identical private copies
/// meant six places to update if the "quiet" default ever changes. `.quiet()` is the right default
/// for a command test because it keeps `get-markdown`'s checklist enrichment out of the assertion;
/// a suite that needs a different store builds its `NotesScript` inline.
func quietScript(_ runner: AppleScriptRunning) -> NotesScript {
    NotesScript(runner: runner, store: StubNotesStore.quiet())
}

// MARK: - Write-gate environment

/// A `NotesWriteEnv` naming variables NOTHING else in the process reads, with the sandbox label
/// pinned to the canonical prefix.
///
/// The unique names are the point: they cannot be set by the operator's shell or by a concurrent
/// suite's `setenv` window, so `willExecute` and `sandboxActive` are decided purely by the flags
/// the test passes. `sandboxPrefix` is pinned for the same reason — `TestMode.sandboxPrefix` reads
/// `APPLE_TEST_SANDBOX`, which other suites in this process do write.
func pinnedWriteEnv(_ label: String = "default") -> NotesWriteEnv {
    NotesWriteEnv(testModeVar: "APPLE_NOTESKIT_TESTONLY_TEST_MODE_\(label)",
                  dryRunVar: "APPLE_NOTESKIT_TESTONLY_DRY_RUN_\(label)",
                  sandboxPrefix: TestMode.canonicalSandboxPrefix)
}

// MARK: - AppleScript-injection invariant

/// A value shaped to break out of an AppleScript string literal, carrying `marker` as a token that
/// survives HTML-escaping and path normalization unchanged.
///
/// The breakout characters are what makes the payload hostile; the marker is what makes the
/// invariant ASSERTABLE. An escaped interpolation would mangle the quotes and ampersands but would
/// still leave the marker verbatim in the script source, so marker-absence is the strong form of
/// "this value never reached the source" — stronger than looking for `do shell script`, which an
/// escaping bug could plausibly disguise.
func hostilePayload(_ marker: String) -> String {
    "apple-cli-test\" & (do shell script \"echo \(marker)\") & \""
}

/// The invariant this port exists to hold, in one call: the user's text reached osascript as an
/// ARGUMENT and appears nowhere in any script SOURCE the runner was handed.
///
/// `FakeNotesRunner` records both halves; asserting only the argv half is positive-only and cannot
/// tell argv-passing apart from argv-passing PLUS interpolation into the source.
func expectArgvOnly(_ runner: FakeNotesRunner, _ marker: String, _ what: String) {
    #expect(runner.allArguments.contains { $0.contains(marker) },
            "\(what): the value must travel to osascript as an argument")
    #expect(runner.scripts.allSatisfy { !$0.contains(marker) },
            "\(what): the value must never appear in the script source")
}

// MARK: - Envelope capture

/// stdout/stderr sinks plus the stdout sink, so a test can drive a command and read its envelope.
func notesStreams() -> (CLIStreams, MemoryOutputSink) {
    let stdout = MemoryOutputSink()
    return (CLIStreams(stdout: stdout, stderr: MemoryOutputSink()), stdout)
}

/// Run `body` with output captured, and decode the JSON envelope it wrote.
func captureNotesEnvelope(_ body: () throws -> Void) throws -> [String: Any] {
    let (streams, stdout) = notesStreams()
    try Output.withStreams(streams) { try body() }
    let object = try JSONSerialization.jsonObject(with: stdout.data)
    return try #require(object as? [String: Any])
}

/// Run `body` expecting it to FAIL, and return `(exitCode, error-object, whole envelope)`.
///
/// `runGuarded` turns a thrown `AppleError` into an error envelope on stdout plus an `ExitCode`,
/// so both halves of the contract — the wire shape and the process's exit status — are asserted
/// from one call. Asserting only the message would miss the half agents actually branch on.
func captureNotesFailure(_ body: () throws -> Void) throws -> (code: Int32, error: [String: Any], envelope: [String: Any]) {
    let (streams, stdout) = notesStreams()
    var thrown: Error?
    Output.withStreams(streams) {
        do { try body() } catch { thrown = error }
    }
    let exit = try #require(thrown as? ExitCode, "expected the command to exit non-zero")
    let object = try JSONSerialization.jsonObject(with: stdout.data)
    let envelope = try #require(object as? [String: Any])
    let error = try #require(envelope["error"] as? [String: Any], "expected an error envelope")
    return (exit.rawValue, error, envelope)
}

/// The `data` object of a success envelope, with `ok: true` and the tool name asserted.
func notesData(_ envelope: [String: Any]) throws -> [String: Any] {
    #expect(envelope["ok"] as? Bool == true)
    #expect(envelope["tool"] as? String == "notes")
    return try #require(envelope["data"] as? [String: Any])
}

// MARK: - AppleScript wire fixtures

/// The separators `NotesScript` splits on, so fixtures are built from the PRODUCER's constants
/// rather than from retyped escape sequences.
let US = NotesScript.US
let RS = NotesScript.RS

/// One `y-mo-d-h-mi-s` date in the numeric shape `NotesScript.dateParts` emits.
let fixtureDate = "2026-1-15-9-30-0"

/// A 6-field note-properties row: title, id, created, modified, shared, password-protected.
func noteRow(title: String, id: String, shared: Bool = false, passwordProtected: Bool = false) -> String {
    [title, id, fixtureDate, fixtureDate, String(shared), String(passwordProtected)].joined(separator: US)
}

/// A CoreData note id that satisfies `NotesScript.isValidNoteId`, so batch entrypoints treat it as
/// runnable instead of short-circuiting to the invalid-id branch.
func fixtureNoteID(_ pk: Int) -> String {
    "x-coredata://11111111-2222-3333-4444-555555555555/ICNote/p\(pk)"
}
