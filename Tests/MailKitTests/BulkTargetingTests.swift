import Testing
import Foundation
import AppleKit
@testable import MailKit

/// Q11-D pins (gap23 / extra21 / extra22 / extra23): the pure halves of the bulk-targeting
/// changes. The live halves (inverse seed observable in preview rows, per-op caps, ids-path
/// scope skipping) are pinned in bats against the real store.
@Suite("Bulk targeting (Q11-D)")
struct BulkTargetingTests {

    /// Source pins supplement the injected command tests: those exercise Swift result
    /// classification, while these check the resolver's AppleScript decisions and consumers.
    /// They do not establish live Mail lookup semantics.
    @Test func resolverCarriesTaggedAmbiguityGuards() throws {
        let src = MailScript.mailboxPathResolverSource
        #expect(src.components(separatedBy: #"return {"ambiguous", missing value}"#).count - 1 == 2)
        #expect(src.contains("(count of hits) > 1"))
        #expect(src.contains(#"if (count of segHits) > 1 then return {"ambiguous", missing value}"#))
        #expect(!src.contains("apple-cli-ambiguous-mailbox"))
        #expect(!src.contains("number -10001"))

        // Force the existing top-level preference to resolve inside its try before tagging
        // the mailbox reference. A lazy reference inside a list could hide lookup failure.
        let topLevel = try #require(src.range(of: "set topLevelMailbox to get mailbox pathRaw of acct"))
        let foundTopLevel = try #require(src.range(of: #"return {"found", topLevelMailbox}"#))
        let ambiguous = try #require(src.range(of: #"return {"ambiguous", missing value}"#))
        #expect(topLevel.upperBound <= foundTopLevel.lowerBound)
        #expect(foundTopLevel.upperBound <= ambiguous.lowerBound)

        // An exact flat name, including a slash-containing one, wins before path splitting.
        let exact = try #require(src.range(of: #"if (count of hits) > 0 then return {"found", item 1 of hits}"#))
        let split = try #require(src.range(of: #"set AppleScript's text item delimiters to "/""#))
        #expect(exact.upperBound <= split.lowerBound)
        #expect(src.contains(#"if (count of segHits) is 0 then return {"missing", missing value}"#))
        #expect(src.contains(#"if mbx is missing value then return {"missing", missing value}"#))
        #expect(src.contains(#"return {"found", mbx}"#))
    }

    @Test func bothMoveScriptsReturnAmbiguityBeforeTheirFirstMutation() throws {
        for gmailMode in [false, true] {
            let runner = MailScriptInjectionTests.FakeMailRunner()
            runner.untimedResults = ["ok"]
            let script = MailScript(runner: runner)
            if gmailMode {
                _ = try script.gmailMove(internetMessageID: "message@example.com", accountName: "Example Account", toMailbox: "Parent/Archive")
            } else {
                _ = try script.move(internetMessageID: "message@example.com", accountName: "Example Account", toMailbox: "Parent/Archive")
            }
            let assembled = try #require(runner.allScripts.first)
            let body = try #require(assembled.components(separatedBy: "end run").first)
            let resolve = try #require(body.range(of: "set mailboxResult to my resolveMailboxPath(acctOfMsg, mbxName)"))
            let ambiguity = try #require(body.range(of: #"if (item 1 of mailboxResult) is "ambiguous" then return "apple-cli-ambiguous-mailbox""#))
            let missing = try #require(body.range(of: #"if (item 1 of mailboxResult) is "missing" then return "nodest""#))
            let reference = try #require(body.range(of: "set destMbx to item 2 of mailboxResult"))
            let mutation = try #require(body.range(of: gmailMode ? "duplicate msg to destMbx" : "set mailbox of msg to destMbx"))
            #expect(resolve.upperBound <= ambiguity.lowerBound)
            #expect(ambiguity.upperBound <= missing.lowerBound)
            #expect(missing.upperBound <= reference.lowerBound)
            #expect(reference.upperBound <= mutation.lowerBound)
            if gmailMode {
                let delete = try #require(body.range(of: "delete msg"))
                #expect(mutation.upperBound <= delete.lowerBound)
            }
            #expect(assembled.contains(MailScript.mailboxPathResolverSource))
            #expect(runner.untimedArguments.first?.last == "Parent/Archive")
            #expect(!assembled.contains("Parent/Archive"))
        }
    }

    @Test func replyAndForwardHintsUseOnlyFoundTagsAndKeepTheBlindFallback() throws {
        let runner = MailScriptInjectionTests.FakeMailRunner()
        runner.stdinResults = [
            "ok\(MailScript.US)synthetic-reply\(MailScript.US)to@example.com\(MailScript.RS)",
            "drafted\(MailScript.US)synthetic-forward\(MailScript.US)to@example.com\(MailScript.RS)",
        ]
        let script = MailScript(runner: runner)
        _ = try script.nativeReplyHtml(
            internetMessageID: "message@example.com", accountName: "Example Account", replyAll: false,
            sender: nil, selfAllowlist: ["to@example.com"], mailboxHint: "Parent/Archive",
            mode: "send", htmlFragmentPath: "/tmp/synthetic-reply.html")
        _ = try script.nativeForward(
            internetMessageID: "message@example.com", accountName: "Example Account", htmlFragmentPath: "",
            to: ["to@example.com"], cc: [], bcc: [], sender: nil,
            selfAllowlist: ["to@example.com"], mailboxHint: "Parent/Archive")
        #expect(runner.allScripts.count == 2)
        for assembled in runner.allScripts {
            let start = try #require(assembled.range(of: "on findMsgHinted(targetID, acctName, mbxName)"))
            let end = try #require(assembled.range(of: "end findMsgHinted"))
            let hint = String(assembled[start.lowerBound..<end.upperBound])
            #expect(hint.contains("set mailboxResult to my resolveMailboxPath(a, mbxName)"))
            let lines = hint.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            #expect(lines.contains([
                #"if (item 1 of mailboxResult) is "found" then"#,
                "set mb to item 2 of mailboxResult",
                "set ms to (messages of mb whose message id is targetID)",
                "if (count of ms) > 0 then return item 1 of ms",
                "end if", "end try",
            ].joined(separator: "\n")))
            #expect(lines.contains([
                "end tell", "end if", "return my findMsg(targetID, acctName)",
            ].joined(separator: "\n")))
            #expect(!hint.contains("apple-cli-ambiguous-mailbox"))
            #expect(assembled.contains(MailScript.mailboxPathResolverSource))
        }
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
        let resolution = try AttachmentsSave.resolveLiveAttachmentNames {
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
