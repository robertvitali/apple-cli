import Testing
import Foundation
import AppleKit
@testable import MailKit

/// Q11-D pins (gap23 / extra21 / extra22 / extra23): the pure halves of the bulk-targeting
/// changes. The live halves (inverse seed observable in preview rows, per-op caps, ids-path
/// scope skipping) are pinned in bats against the real store.
@Suite("Bulk targeting (Q11-D)")
struct BulkTargetingTests {

    /// extra23: the resolver must carry BOTH ambiguity guards — the flat-name branch and the
    /// per-segment branch — raising the typed sentinel instead of `item 1` arbitrary picks.
    /// Source-text pin: the script only executes against live Mail, and executing a move in
    /// the logic tier would mutate real mail.
    @Test func resolverCarriesAmbiguityGuards() {
        let src = MailScript.mailboxPathResolverSource
        let guards = src.components(separatedBy: "apple-cli-ambiguous-mailbox").count - 1
        #expect(guards == 2)
        #expect(src.contains("(count of hits) > 1"))
        #expect(src.contains("(count of segHits) > 1"))
        // MEASURED top-level preference: `mailbox X of acct` (oracle A's own reference form)
        // resolves top-level-only and errors -1728 on a nested leaf, so on >1 flat hits a
        // top-level match must win BEFORE the sentinel refusal — dropping it would refuse a
        // move the oracle performs.
        #expect(src.contains("return mailbox pathRaw of acct"))
        // Placement (review B3): the segment-loop sentinel must sit OUTSIDE the `try…end try`
        // that wraps the segHits lookup — inside it, the loop's own `on error` handler would
        // swallow the sentinel into `return missing value` ("nodest"), silently disabling the
        // guard. Pin: the segment guard appears AFTER the last `end try` in the source.
        let lastEndTry = src.range(of: "end try", options: .backwards)
        let segGuard = src.range(of: "(count of segHits) > 1")
        #expect(lastEndTry != nil && segGuard != nil
            && lastEndTry!.upperBound <= segGuard!.lowerBound)
    }

    /// extra23: the sentinel classifier — anything else in stderr is NOT ambiguity (a generic
    /// AppleScript failure must keep its upstream error class, never masquerade as validation).
    /// Anchored (security review M1): BOTH the `-10001` sentinel error number AND osascript's
    /// `execution error:` framing are required, so stderr that merely CONTAINS the token
    /// (e.g. an operator-named mailbox echoed inside a different Mail error) never matches.
    @Test func ambiguitySentinelClassification() {
        #expect(MailScript.isAmbiguousMailboxError("execution error: apple-cli-ambiguous-mailbox:3 (-10001)"))
        #expect(!MailScript.isAmbiguousMailboxError("execution error: Mail got an error: AppleEvent timed out. (-1712)"))
        #expect(!MailScript.isAmbiguousMailboxError(""))
        // Token WITHOUT the sentinel's error number (an unrelated error echoing the name).
        #expect(!MailScript.isAmbiguousMailboxError(
            #"execution error: Mail got an error: Can't get mailbox "apple-cli-ambiguous-mailbox:3". (-1728)"#))
        // Token + number but no `execution error:` framing (not an osascript failure line).
        #expect(!MailScript.isAmbiguousMailboxError("apple-cli-ambiguous-mailbox:3 (-10001)"))
    }

    /// extra32: the master-selection decision for `attachments save`, pinned pure. The live
    /// Mail.app enumeration wins whenever the message was LOCATED — including an empty live
    /// list (selection then fails loudly downstream, never silently against the index order) —
    /// and the index-ordered fallback is always isLive=false (the execute path refuses it;
    /// index `ORDER BY name` was measured disagreeing with Mail's live order on 8/8 sampled
    /// multi-attachment messages).
    @Test func attachmentMasterSelection() {
        let idx = ["a.pdf", "b.png"]
        let live = AttachmentsSave.selectAttachmentMaster(indexNames: idx, liveNames: ["b.png", "a.pdf"])
        #expect(live.master == ["b.png", "a.pdf"] && live.isLive)
        let fallback = AttachmentsSave.selectAttachmentMaster(indexNames: idx, liveNames: nil)
        #expect(fallback.master == idx && !fallback.isLive)
        let locatedEmpty = AttachmentsSave.selectAttachmentMaster(indexNames: idx, liveNames: [])
        #expect(locatedEmpty.master.isEmpty && locatedEmpty.isLive)
    }

    @Test func attachmentSaveRefusesTimeoutFallbackOnExecute() throws {
        let resolution = AttachmentsSave.resolveLiveAttachmentNames {
            throw AppleScriptRunner.TimeoutError(seconds: 30)
        }
        #expect(resolution.names == nil)
        #expect(resolution.failure == "Mail.app enumeration failed (osascript timed out after 30s)")
        let fallback = AttachmentsSave.selectAttachmentMaster(
            indexNames: ["report.pdf"], liveNames: resolution.names)
        #expect(fallback.master == ["report.pdf"])
        #expect(!fallback.isLive)
        let previewNote = try #require(AttachmentsSave.previewFallbackNote(
            isLive: fallback.isLive, failure: resolution.failure))
        #expect(previewNote.contains("osascript timed out after 30s"))
        #expect(previewNote.contains("--execute refuses from this fallback"))

        let error = #expect(throws: AppleError.self) {
            try AttachmentsSave.requireLiveAttachmentMasterForExecute(
                fallback.isLive, rowid: 42, failure: resolution.failure)
        }
        let upstream = try #require(error)
        #expect(upstream.type == "upstream_error")
        #expect(upstream.exitCode == 69)
        #expect(upstream.message.contains("osascript timed out after 30s"))
        #expect(upstream.message.contains("refusing to save by index-order positions"))

        #expect(throws: Never.self) {
            try AttachmentsSave.requireLiveAttachmentMasterForExecute(
                true, rowid: 42, failure: nil)
        }
    }

    /// joinNotes: nil-compaction contract for the merged wire `note`.
    @Test func joinNotesCompactsNils() {
        #expect(joinNotes(nil, nil) == nil)
        #expect(joinNotes("a", nil) == "a")
        #expect(joinNotes(nil, "b") == "b")
        #expect(joinNotes("a", "b") == "a | b")
    }
}
