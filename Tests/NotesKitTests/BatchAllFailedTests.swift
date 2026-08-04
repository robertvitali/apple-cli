import Testing
import Foundation
import AppleKit
@testable import NotesKit

/// `batch-delete` / `batch-move` when NOTHING succeeded (NOTES-L3).
///
/// The oracle's two batch handlers both end:
///
/// ```js
/// return succeeded > 0
///   ? successResponse(lines.join("\n"), { ok: failed === 0, succeeded, failed, results })
///   : errorResponse(lines.join("\n"));
/// ```
///
/// Three-way, not two-way. We already matched all-succeeded and PARTIAL — the payload's `ok` was
/// correctly `failed == 0`. The third case was wrong: a batch where every id failed still emitted a
/// success envelope and exit 0, so an agent checking the envelope's `ok` (the documented signal for
/// "did this work") was told a delete had worked when nothing was deleted.
///
/// RESULTS BUILT VIA `mapBatchStatus`, NOT HAND-WRITTEN STRINGS. Review caught the first version
/// hard-coding `"Note not found"`, which coupled the test to a literal instead of to the code that
/// produces it — reword the producer and the test keeps passing while the behaviour changes. Going
/// through the real mapping means these cases stay honest.
@Suite("batch delete/move — wholly-failed batch is an error")
struct BatchAllFailedTests {

    private func item(_ id: String, _ status: String, op: String = "delete") -> BatchItemResult {
        NotesScript.mapBatchStatus(id, status, op: op)
    }
    /// The whole-script `catch` path: every item stamped with one flattened `AppleError` message.
    private func flattened(_ id: String, _ msg: String) -> BatchItemResult {
        BatchItemResult(id: id, success: false, error: msg)
    }

    @Test("every id failed → throws, and always as one type")
    func whollyFailedThrows() {
        // Same failure, four different reasons. ALL must produce the same type: the oracle
        // collapses them into one generic error, and an earlier version of this code re-derived a
        // type per-reason by substring, which inverted on nearly every real path.
        let cases: [[BatchItemResult]] = [
            [item("p1", "missing"), item("p2", "missing")],
            [item("p1", "missing"), item("p2", "pw")],
            [item("p1", "fail"), item("p2", "fail")],
            [flattened("p1", NotesScript.BatchFailure.invalidId),
             flattened("p2", NotesScript.BatchFailure.invalidId)],
            // A TCC denial flattened onto every item. Under the old substring rule this was typed
            // `unknown`/70; a genuine AppleScript not-found ("Notes could not find the requested
            // item…") was too, despite containing no literal "not found".
            [flattened("p1", "Notes could not find the requested item."),
             flattened("p2", "Notes could not find the requested item.")],
        ]
        for results in cases {
            do {
                try requireAnyBatchSuccess(results, verb: "delete")
                Issue.record("should have thrown for \(results.map(\.error))")
            } catch let e as AppleError {
                #expect(e.type == AppleErrorType.upstream)
                #expect(e.exitCode == AppleExit.upstream)
            } catch { Issue.record("wrong error type: \(error)") }
        }
    }

    @Test("the message keeps the oracle's shape and every per-item reason")
    func messageShape() {
        do {
            try requireAnyBatchSuccess([item("x-coredata://A/ICNote/p1", "missing"),
                                        item("x-coredata://A/ICNote/p2", "pw")], verb: "delete")
            Issue.record("should have thrown")
        } catch let e as AppleError {
            #expect(e.message.hasPrefix("Batch delete: 0 succeeded, 2 failed"))
            #expect(e.message.contains("Failures:"))
            // Both reasons survive verbatim — this is the ONLY place they now exist, since an
            // AppleError carries no structured results (and neither does the oracle's errorResponse).
            #expect(e.message.contains("x-coredata://A/ICNote/p1: \(NotesScript.BatchFailure.notFound)"))
            #expect(e.message.contains("x-coredata://A/ICNote/p2: \(NotesScript.BatchFailure.passwordProtected)"))
        } catch { Issue.record("wrong error type: \(error)") }
    }

    /// The oracle's move summary names the destination:
    /// `Batch move to "${folder}": ${succeeded} succeeded, ${failed} failed`. The first version of
    /// this fix dropped the folder, which review caught.
    @Test("batch-move names the destination folder, like the oracle")
    func moveMessageNamesFolder() {
        do {
            try requireAnyBatchSuccess([item("p1", "missing", op: "move")], verb: "move",
                                       folder: "apple-cli-test-dest")
            Issue.record("should have thrown")
        } catch let e as AppleError {
            #expect(e.message.hasPrefix("Batch move to \"apple-cli-test-dest\": 0 succeeded, 1 failed"))
        } catch { Issue.record("wrong error type: \(error)") }
    }

    /// THE REGRESSION DIRECTION THAT MATTERS. A partial batch is a SUCCESS in the oracle
    /// (`successResponse` with `ok:false` in the payload). If the throw fired here we would have
    /// turned "3 of 4 deleted" into a hard failure and lost the per-item results — worse than the
    /// bug being fixed.
    @Test("one success among failures still succeeds")
    func partialBatchDoesNotThrow() throws {
        try requireAnyBatchSuccess([item("p1", "ok"), item("p2", "missing")], verb: "delete")
        try requireAnyBatchSuccess([item("p1", "missing"), item("p2", "ok")], verb: "delete")
        try requireAnyBatchSuccess([item("a", "fail"), item("b", "pw"), item("c", "ok")],
                                   verb: "move", folder: "d")
    }

    @Test("an all-succeeded batch does not throw")
    func allSucceededDoesNotThrow() throws {
        try requireAnyBatchSuccess([item("p1", "ok"), item("p2", "ok")], verb: "delete")
    }

    /// Unreachable from the commands (both reject empty `--ids` with a validation error first,
    /// matching the oracle's `errorResponse("No note IDs provided")`), but `allSatisfy` is vacuously
    /// true on an empty array, so without the emptiness guard this helper would throw on it.
    @Test("empty results do not throw (vacuous-allSatisfy guard)")
    func emptyDoesNotThrow() throws {
        try requireAnyBatchSuccess([], verb: "delete")
    }
}
