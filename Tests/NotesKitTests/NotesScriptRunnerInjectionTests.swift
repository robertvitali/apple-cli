import Foundation
import Testing
@testable import NotesKit
@testable import AppleKit

/// Pins the safety guarantee behind `NotesScript`'s retry loop (`NotesScript.swift` ~L88-118):
/// READ scripts attempt up to 2× (one retry on a transient stderr); MUTATION scripts attempt
/// EXACTLY ONCE — a non-idempotent write must never be re-run, because the retryable stderr
/// patterns (timeout/busy/lost-connection) can fire AFTER Notes.app already applied the change.
/// Before `AppleScriptRunning` (the injection seam this file exercises), `NotesScript.runner` was
/// a hardcoded `AppleScriptRunner()`, so this loop could only be exercised against a live
/// Notes.app — no revert-red coverage existed for a future mutation call site that forgot to pass
/// `maxAttempts: NotesScript.maxMutationAttempts`. Pure — no live Notes.app, no network.
final class FakeRunner: AppleScriptRunning {
    private(set) var invocationCount = 0
    private let failCount: Int
    private let failureStderr: String
    private let successValue: String

    /// Fails with `failureStderr` on the first `failCount` invocations, then returns
    /// `successValue`. `failCount: 0` always succeeds.
    init(failCount: Int, failureStderr: String, successValue: String = "ok") {
        self.failCount = failCount
        self.failureStderr = failureStderr
        self.successValue = successValue
    }

    func run(_ script: String, arguments: [String]) throws -> String {
        invocationCount += 1
        if invocationCount <= failCount {
            throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: failureStderr)
        }
        return successValue
    }
}

/// A runner that ALWAYS fails with a transient (looks-retryable) stderr. Used at each mutation
/// call site below to prove the site is wired to `maxAttempts: NotesScript.maxMutationAttempts`:
/// if it were NOT (e.g. a future call site left the read-policy default), this fake would make
/// the retry fire and `invocationCount` would read 2, not 1 — that is the revert-red signal.
final class AlwaysFailingRunner: AppleScriptRunning {
    private(set) var invocationCount = 0
    private let failureStderr: String
    init(failureStderr: String = "Notes is busy") { self.failureStderr = failureStderr }
    func run(_ script: String, arguments: [String]) throws -> String {
        invocationCount += 1
        throw AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: failureStderr)
    }
}

@Suite("NotesScript — injected-runner retry policy (READ retries once, MUTATION never retries)")
struct NotesScriptRunnerRetryPolicyTests {

    @Test("READ policy (default maxAttempts) retries once on a transient failure, then succeeds")
    func readRetriesOnceThenSucceeds() throws {
        let fake = FakeRunner(failCount: 1, failureStderr: "AppleEvent timed out", successValue: "ok")
        let out = try NotesScript(runner: fake).run("return \"ok\"", args: [])
        #expect(out == "ok")
        #expect(fake.invocationCount == 2)
    }

    @Test("MUTATION policy (maxAttempts: maxMutationAttempts) never retries a transient failure")
    func mutationNeverRetriesDespiteTransientFailure() {
        // Same failure shape as the read-retry case above (would succeed on a 2nd attempt) —
        // driven through the mutation attempt budget to prove the retry never happens.
        let fake = FakeRunner(failCount: 1, failureStderr: "Notes is busy", successValue: "ok")
        let script = NotesScript(runner: fake)
        #expect(throws: AppleError.self) {
            try script.run("delete note id (item 1 of argv)", args: ["x"],
                           maxAttempts: NotesScript.maxMutationAttempts)
        }
        #expect(fake.invocationCount == 1)
    }

    @Test("a NON-transient failure fast-fails even under the READ policy (no wasted retry)")
    func nonTransientFailureFastFailsUnderReadPolicy() {
        let fake = FakeRunner(failCount: 5, failureStderr: "Notes got an error: Can\u{2019}t get note \"x\". (-1728)",
                              successValue: "ok")
        let script = NotesScript(runner: fake)
        #expect(throws: AppleError.self) {
            try script.run("return body of note (item 1 of argv)", args: ["x"])
        }
        #expect(fake.invocationCount == 1)
    }
}

@Suite("NotesScript — per-call-site pin: every mutation entrypoint attempts exactly once")
struct NotesScriptMutationCallSitePinTests {
    /// A note id matching `isValidNoteId`'s coredata pattern, so batch entrypoints below treat it
    /// as runnable instead of short-circuiting to the "Invalid note ID" branch.
    private let validNoteId = "x-coredata://ABCDEF01-1234-5678-9ABC-DEF012345678/ICNote/p1"

    @Test("createNote never retries")
    func createNoteNeverRetries() {
        let fake = AlwaysFailingRunner()
        let script = NotesScript(runner: fake)
        #expect(throws: AppleError.self) {
            try script.createNote(title: "t", content: "c", folder: nil, account: nil, html: false)
        }
        #expect(fake.invocationCount == 1)
    }

    @Test("updateNoteById never retries")
    func updateNoteByIdNeverRetries() {
        let fake = AlwaysFailingRunner()
        let script = NotesScript(runner: fake)
        #expect(throws: AppleError.self) {
            // html: true so the write never first reads the existing title (a separate call) —
            // isolates this test to the single mutation call site under pin.
            try script.updateNoteById(id: validNoteId, newTitle: nil, newContent: "<p>c</p>", html: true)
        }
        #expect(fake.invocationCount == 1)
    }

    @Test("updateNote (by title) never retries")
    func updateNoteByTitleNeverRetries() {
        let fake = AlwaysFailingRunner()
        let script = NotesScript(runner: fake)
        #expect(throws: AppleError.self) {
            try script.updateNote(title: "t", newTitle: nil, newContent: "<p>c</p>", account: nil, html: true)
        }
        #expect(fake.invocationCount == 1)
    }

    @Test("deleteNoteById never retries")
    func deleteNoteByIdNeverRetries() {
        let fake = AlwaysFailingRunner()
        let script = NotesScript(runner: fake)
        #expect(throws: AppleError.self) {
            try script.deleteNoteById(id: validNoteId)
        }
        #expect(fake.invocationCount == 1)
    }

    @Test("deleteNote (by title) never retries")
    func deleteNoteByTitleNeverRetries() {
        let fake = AlwaysFailingRunner()
        let script = NotesScript(runner: fake)
        #expect(throws: AppleError.self) {
            try script.deleteNote(title: "t", account: nil)
        }
        #expect(fake.invocationCount == 1)
    }

    @Test("moveNoteById never retries")
    func moveNoteByIdNeverRetries() {
        let fake = AlwaysFailingRunner()
        let script = NotesScript(runner: fake)
        #expect(throws: AppleError.self) {
            try script.moveNoteById(id: validNoteId, folder: "Work", account: nil)
        }
        #expect(fake.invocationCount == 1)
    }

    @Test("deleteFolder never retries")
    func deleteFolderNeverRetries() {
        let fake = AlwaysFailingRunner()
        let script = NotesScript(runner: fake)
        #expect(throws: AppleError.self) {
            try script.deleteFolder(name: "Work", account: nil)
        }
        #expect(fake.invocationCount == 1)
    }

    // MARK: batch entrypoints (non-throwing — failure surfaces per-item in the result list)

    @Test("batchDeleteNotes never retries; the AppleScript call attempts exactly once")
    func batchDeleteNeverRetries() {
        let fake = AlwaysFailingRunner()
        let script = NotesScript(runner: fake)
        let results = script.batchDeleteNotes(ids: [validNoteId])
        #expect(results.count == 1)
        #expect(results.first?.success == false)
        #expect(fake.invocationCount == 1)
    }

    @Test("batchMoveNotes never retries; the AppleScript call attempts exactly once")
    func batchMoveNeverRetries() {
        let fake = AlwaysFailingRunner()
        let script = NotesScript(runner: fake)
        let results = script.batchMoveNotes(ids: [validNoteId], folder: "Work", account: nil)
        #expect(results.count == 1)
        #expect(results.first?.success == false)
        #expect(fake.invocationCount == 1)
    }

    // NOTE: `createFolder(name:account:)` is deliberately NOT pinned here. It interleaves READ
    // existence-checks (default retry-once policy, swallowed via `try?`) with MUTATION creation
    // calls (`maxAttempts: maxMutationAttempts`) across a per-path-segment loop, so a single
    // "invoked exactly once" assertion can't express its contract the way the single-call-site
    // entrypoints above do. Its mutation calls already pass `maxAttempts: Self.maxMutationAttempts`
    // (see `NotesScript.swift`), and the shared retry-mechanics pinned in
    // `NotesScriptRunnerRetryPolicyTests` above cover the policies it composes.
}
