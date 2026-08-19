import Foundation
import Testing
@testable import NotesKit
@testable import AppleKit

/// notes-#8 (transient-failure retry) + notes-#9 (richer entity-specific error mapping), pinned
/// against apple-notes-mcp@2.7.5 (`build/index.js`: `RETRYABLE_ERROR_PATTERNS` / `isRetryableError`
/// and the `ERROR_MAPPINGS` table). Pure — no live Notes.app.
@Suite("NotesScript — transient-retry predicate (notes-#8)")
struct NotesScriptRetryTests {

    /// The six oracle `RETRYABLE_ERROR_PATTERNS`, each with a representative osascript stderr line.
    /// If any pattern is dropped from `retryableErrorPatterns`, its case here flips to false and the
    /// test goes red.
    @Test("every oracle transient pattern is recognised as retryable")
    func transientPatternsRetry() {
        #expect(NotesScript.isRetryable("Notes got an error: AppleEvent timed out. (-1712)"))
        #expect(NotesScript.isRetryable("time out"))            // /timed? out/ — the `d?` is optional
        #expect(NotesScript.isRetryable("Notes.app is not responding"))
        #expect(NotesScript.isRetryable("The connection is invalid."))   // /connection.*invalid/
        #expect(NotesScript.isRetryable("Lost connection to the Notes process."))
        #expect(NotesScript.isRetryable("Notes is busy syncing right now"))
        #expect(NotesScript.isRetryable("Notes changed during listing"))
    }

    /// Genuine errors are deliberately ABSENT from the retry set (a non-idempotent write must never
    /// be re-run on a real failure; a not-found/validation error would just waste a round-trip).
    @Test("genuine errors are NOT retryable")
    func genuineErrorsDoNotRetry() {
        #expect(!NotesScript.isRetryable("Notes got an error: Can’t get note id \"x-coredata://1\". (-1728)"))
        #expect(!NotesScript.isRetryable("Note is password protected"))
        #expect(!NotesScript.isRetryable("Not authorized to send Apple events to Notes."))
        #expect(!NotesScript.isRetryable("A folder with that name already exists."))
        #expect(!NotesScript.isRetryable("syntax error: Expected end of line."))
        #expect(!NotesScript.isRetryable("Can’t get folder \"Work\"."))
        #expect(!NotesScript.isRetryable(""))
    }

    /// The `RunError` overload: `.launchFailed` is never transient (osascript could not start);
    /// `.scriptFailed` defers to the stderr predicate.
    @Test("RunError overload: launchFailed never retries; scriptFailed defers to stderr")
    func runErrorOverload() {
        #expect(!NotesScript.isRetryable(AppleScriptRunner.RunError.launchFailed("busy timed out")))
        #expect(NotesScript.isRetryable(AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "Notes is busy")))
        #expect(!NotesScript.isRetryable(AppleScriptRunner.RunError.scriptFailed(status: 1, stderr: "Can’t get note id \"z\".")))
    }

    /// Read vs mutation attempt-budget: reads retry once (2 attempts total), mutations never retry.
    @Test("attempt-budget constants mirror the oracle (2 reads / 1 mutation, 1000ms base)")
    func attemptBudgetConstants() {
        #expect(NotesScript.maxReadAttempts == 2)
        #expect(NotesScript.maxMutationAttempts == 1)
        #expect(NotesScript.retryDelayMs == 1000)
    }
}

@Suite("NotesScript — entity-specific error mapping (notes-#9)")
struct NotesScriptErrorMappingTests {

    /// Build a `.scriptFailed` and map it. Notes.app emits a CURLY apostrophe in `Can’t get …`;
    /// the fixtures use it deliberately so the U+2019→U+0027 normalisation stays covered (NOTES-M3).
    private func map(_ stderr: String) -> AppleError {
        NotesScript.mapError(.scriptFailed(status: 1, stderr: stderr))
    }

    @Test("note-not-found by name echoes the exact (original-case) title, type not_found/65")
    func noteByName() {
        let e = map("Notes got an error: Can’t get note \"My Note\". (-1728)")
        #expect(e.message == "Note \"My Note\" not found. Verify the title is exact (case-sensitive).")
        #expect(e.type == AppleErrorType.notFound)
        #expect(e.exitCode == AppleExit.notFound)
    }

    @Test("note-not-found by id, type not_found/65")
    func noteById() {
        let e = map("Notes got an error: Can’t get note id \"x-coredata://ABC/ICNote/p5\". (-1728)")
        #expect(e.message == "Note not found. The note may have been deleted or the ID is invalid.")
        #expect(e.type == AppleErrorType.notFound)
        #expect(e.exitCode == AppleExit.notFound)
    }

    @Test("folder-not-found by name echoes the folder, type not_found/65")
    func folderByName() {
        let e = map("Notes got an error: Can’t get folder \"Work\". (-1728)")
        #expect(e.message == "Folder \"Work\" not found. Use list-folders to see available folders.")
        #expect(e.type == AppleErrorType.notFound)
        #expect(e.exitCode == AppleExit.notFound)
    }

    @Test("account-not-found by name echoes the account, type not_found/65")
    func accountByName() {
        let e = map("Notes got an error: Can’t get account \"Gmail\". (-1728)")
        #expect(e.message == "Account \"Gmail\" not found. Use list-accounts to see available accounts.")
        #expect(e.type == AppleErrorType.notFound)
        #expect(e.exitCode == AppleExit.notFound)
    }

    @Test("application-not-running maps to a distinct upstream/69 message")
    func applicationNotRunning() {
        let e = map("Notes got an error: Application isn’t running. (-600)")
        #expect(e.message == "Notes.app is not responding. Try opening Notes.app manually.")
        #expect(e.type == AppleErrorType.upstream)
        #expect(e.exitCode == AppleExit.upstream)
    }

    @Test("lost/invalid connection maps to a distinct upstream/69 message")
    func lostConnection() {
        let e1 = map("The connection is invalid. (-609)")
        #expect(e1.message == "Lost connection to Notes.app. The app may have crashed or been restarted.")
        #expect(e1.type == AppleErrorType.upstream)
        let e2 = map("Lost connection to Notes")
        #expect(e2.message == "Lost connection to Notes.app. The app may have crashed or been restarted.")
    }

    @Test("cannot-delete (locked/in-use) maps to a distinct message, unchanged upstream/69")
    func cannotDelete() {
        let e = map("Notes got an error: Can’t delete folder \"Locked\". (-10006)")
        #expect(e.message == "Cannot delete. The item may be locked or in use.")
        #expect(e.type == AppleErrorType.upstream)
        #expect(e.exitCode == AppleExit.upstream)
    }

    @Test("changed-during-listing keeps the retryable phrase, upstream/69")
    func changedDuringListing() {
        let e = map("Notes changed during listing")
        #expect(e.message == "Notes changed during listing (an iCloud sync may have landed mid-read). "
            + "The operation is retried automatically; run it again if this persists.")
        #expect(e.type == AppleErrorType.upstream)
        // The mapped message MUST still be recognised as transient (the oracle relies on this).
        #expect(NotesScript.isRetryable(e.message))
    }

    @Test("syntax/script error maps to internal-error, upstream/69")
    func syntaxError() {
        let e = map("syntax error: Expected end of line but found identifier. (-2741)")
        #expect(e.message == "Internal error. Please report this issue.")
        #expect(e.type == AppleErrorType.upstream)
        #expect(e.exitCode == AppleExit.upstream)
    }

    // MARK: — pre-existing buckets keep their exit code + type (message-richness-only guarantee)

    @Test("password-protected unchanged: validation/64")
    func passwordProtected() {
        let e = map("This note is password protected")
        #expect(e.message == "Note is password-protected. Unlock it in Notes.app first.")
        #expect(e.type == AppleErrorType.validation)
        #expect(e.exitCode == AppleExit.usage)
    }

    @Test("folder-already-exists unchanged: validation/64")
    func alreadyExists() {
        let e = map("A folder with that name already exists.")
        #expect(e.message == "A folder with that name already exists.")
        #expect(e.type == AppleErrorType.validation)
        #expect(e.exitCode == AppleExit.usage)
    }

    @Test("permission unchanged: authorization_denied/77")
    func permission() {
        let e = map("Not authorized to send Apple events to Notes.")
        #expect(e.type == AppleErrorType.permissionDenied)
        #expect(e.exitCode == AppleExit.permissionDenied)
    }

    @Test("timeout unchanged: upstream/69")
    func timeout() {
        let e = map("Notes got an error: AppleEvent timed out. (-1712)")
        #expect(e.message == "Notes.app timed out. It may be unresponsive or busy syncing; try again.")
        #expect(e.type == AppleErrorType.upstream)
        #expect(e.exitCode == AppleExit.upstream)
    }

    @Test("generic can't-get still classifies not_found/65 (catch-all after the specific cases)")
    func genericNotFound() {
        let e = map("Notes got an error: Can’t get some other specifier. (-1728)")
        #expect(e.message == "Notes could not find the requested item (verify the id/title/folder).")
        #expect(e.type == AppleErrorType.notFound)
        #expect(e.exitCode == AppleExit.notFound)
    }

    @Test("truly unmapped error falls through to the generic upstream/69 message")
    func unmappedFallback() {
        // Deliberately avoids the word "unexpected" — the oracle's `/syntax error|expected/i` token
        // (faithfully ported) matches the "expected" substring inside it, so it would hit the
        // syntax bucket, not the final fallback. This case has no known marker at all.
        let e = map("Some totally unknown failure with no known marker")
        #expect(e.message == "Notes.app returned an error.")
        #expect(e.type == AppleErrorType.upstream)
        #expect(e.exitCode == AppleExit.upstream)
    }

    @Test("launchFailed maps to upstream with the osascript prefix")
    func launchFailed() {
        let e = NotesScript.mapError(.launchFailed("No such file"))
        #expect(e.message == "osascript launch failed: No such file")
        #expect(e.type == AppleErrorType.upstream)
    }
}
