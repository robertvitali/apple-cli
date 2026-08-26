import Testing
import Foundation
import TestSupport
@testable import MailKit

/// Q11-C pins (gap17/gap15/extra15): reply delivery modes + the threaded HTML pasteboard
/// flow, plus the script-assembly seam that silently broke every native reply/forward.
@Suite("Native compose modes (Q11-C)")
struct NativeComposeModeTests {
    static let US = String(UnicodeScalar(31))
    static let RS = String(UnicodeScalar(30))

    private let scratch = ScratchDirs("mail-native-compose")

    private static func trimmedLines(_ source: String) -> [String] {
        source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: parser — drafted / opened outcomes

    @Test func parserMapsDraftedAndOpened() {
        #expect(MailScript.parseNativeCompose("drafted\(Self.US)4711\(Self.US)me@self.test")
            == .drafted(newMessageID: "4711", recipients: ["me@self.test"]))
        #expect(MailScript.parseNativeCompose("opened\(Self.US)4712\(Self.US)a@x.test\(Self.RS)b@x.test")
            == .opened(newMessageID: "4712", recipients: ["a@x.test", "b@x.test"]))
        // Missing the id field → NOT a silent success: falls through to the fail-closed
        // unrecognized branch (same rule as the batch-2 pins on truncated "ok" rows).
        if case .refused = MailScript.parseNativeCompose("drafted") {} else {
            Issue.record("bare 'drafted' must fall through to the fail-closed refusal")
        }
        if case .refused = MailScript.parseNativeCompose("opened") {} else {
            Issue.record("bare 'opened' must fall through to the fail-closed refusal")
        }
    }

    // MARK: script-assembly seam — the missing-newline join

    /// REGRESSION (measured via osacompile): since the guardAndSendTail extraction, the
    /// `""" + guardAndSendTail` concatenation dropped the newline between the fragment's
    /// closing `end try` and the tail's first `set` — Swift multiline literals do not carry
    /// a trailing newline before the closing delimiter — producing a single merged line
    /// (`end try                set AppleScript's …`) that is INVALID AppleScript. Every
    /// native reply/forward since then failed at script compile. The join now inserts an
    /// explicit "\n"; this pin holds the seam: no line in any assembled compose script may
    /// carry anything after `end try`.
    @Test func assembledScriptsKeepEveryEndTryOnItsOwnLine() {
        for (name, src) in [("replyHtml", MailScript.nativeReplyHtmlScriptSource),
                            ("forward", MailScript.nativeForwardScriptSource)] {
            for line in src.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains("end try") {
                #expect(line.trimmingCharacters(in: .whitespaces) == "end try",
                        "\(name): merged seam line: \(line)")
            }
        }
    }

    // MARK: mode plumbing

    /// D3 gui-send incident: the unique-window condition is polled for exactly 30 seconds. The
    /// nonce check itself must be enclosed by that one bounded loop, never an unbounded retry.
    @Test func guiSendPollIsExactlyBoundedAndChecksMailFocus() throws {
        let script = MailScript.sendHtmlGuiScriptSource
        let lines = Self.trimmedLines(script)
        let pollStart = try #require(lines.firstIndex(of: "repeat 60 times"))
        let pollEnd = try #require(lines[(pollStart + 1)...].firstIndex(of: "end repeat"))
        let poll = Array(lines[pollStart...pollEnd])
        let repeatLines = poll.filter { $0 == "repeat" || $0.hasPrefix("repeat ") }
        #expect(repeatLines == ["repeat 60 times"],
                "the nonce poll must contain no nested or unbounded repeat")

        let match = try #require(poll.firstIndex(of:
            "if frontmost and (exists front window) and ((name of front window) contains nonce) then"))
        let exit = try #require(poll.firstIndex(of: "exit repeat"))
        let delay = try #require(poll.firstIndex(of: "delay 0.5"))
        #expect(match < exit)
        #expect(exit < delay)
        #expect(poll.filter { $0 == "delay 0.5" }.count == 1)

        let advertisedSeconds = 60.0 * 0.5
        #expect(MailScript.sendHtmlGuiError(for: "wrong-window").message
            .contains("\(Int(advertisedSeconds)) seconds"))
    }

    /// A match is only provisional: after the proven 2.5-second settle, re-check focus + nonce before
    /// Tab/Cmd-A, repeat the same check immediately before paste, and check focus again before Send.
    @Test func guiSendRechecksFocusBeforeEveryDestructiveStage() throws {
        let script = MailScript.sendHtmlGuiScriptSource
        let matched = try #require(script.range(of: "if windowMatched then"))
        let settle = try #require(script.range(of: "delay 2.5", range: matched.upperBound..<script.endIndex))
        let readyCheck = try #require(script.range(of:
            "if frontmost and (exists front window) and ((name of front window) contains nonce) then",
            range: settle.upperBound..<script.endIndex))
        let tab = try #require(script.range(of: "key code 48", range: readyCheck.upperBound..<script.endIndex))
        let beforeReady = Self.trimmedLines(String(script[matched.upperBound..<readyCheck.lowerBound]))
            .filter { !$0.hasPrefix("--") }
        #expect(!beforeReady.contains { $0.hasPrefix("key code") })
        #expect(!beforeReady.contains { $0.hasPrefix("keystroke") })

        let select = try #require(script.range(of: "keystroke \"a\" using command down",
                                               range: tab.upperBound..<script.endIndex))
        let pasteCheck = try #require(script.range(of:
            "if frontmost and (exists front window) and ((name of front window) contains nonce) then",
            range: select.upperBound..<script.endIndex))
        let paste = try #require(script.range(of: "keystroke \"v\" using command down",
                                              range: pasteCheck.upperBound..<script.endIndex))
        #expect(script[pasteCheck.upperBound..<paste.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let subjectVerified = try #require(script.range(of:
            "if (subject of newMsg) is theSubject then set subjectRestored to true",
            range: paste.upperBound..<script.endIndex))
        let sendFocus = try #require(script.range(of: "if frontmost then",
                                                  range: subjectVerified.upperBound..<script.endIndex))
        let send = try #require(script.range(of: "keystroke \"d\" using {command down, shift down}",
                                             range: sendFocus.upperBound..<script.endIndex))
        let sendGateEnd = try #require(script.range(of: "end if", range: send.upperBound..<script.endIndex))
        #expect(script[send.upperBound..<sendGateEnd.lowerBound].contains("set sendOK to true"))
        #expect(script[sendFocus.lowerBound..<sendGateEnd.upperBound].contains("set focusLost to true"))

        let focusCleanup = try #require(script.range(of: "if focusLost then",
                                                     range: sendGateEnd.upperBound..<script.endIndex))
        let restore = try #require(script.range(of: "set subject of newMsg to theSubject",
                                                range: focusCleanup.upperBound..<script.endIndex))
        _ = try #require(script.range(of: "return \"focus-lost\"",
                                      range: restore.upperBound..<script.endIndex))
        let allLines = Self.trimmedLines(script)
        let uiInit = try #require(allLines.firstIndex(of: "set uiFailed to false"))
        let uiTry = try #require(allLines[(uiInit + 1)...].firstIndex(of: "try"))
        let systemEvents = try #require(allLines[(uiTry + 1)...]
            .firstIndex(of: "tell application \"System Events\""))
        let pasteboardWrite = try #require(allLines[(systemEvents + 1)...]
            .firstIndex(of: "pb's setData:htmlData forType:(current application's NSPasteboardTypeHTML)"))
        let uiCatch = try #require(allLines[(pasteboardWrite + 1)...].firstIndex(of: "on error"))
        let uiFlag = try #require(allLines[(uiCatch + 1)...].firstIndex(of: "set uiFailed to true"))
        #expect(uiInit < uiTry)
        #expect(uiTry < systemEvents)
        #expect(systemEvents < pasteboardWrite)
        #expect(pasteboardWrite < uiCatch)
        #expect(uiCatch < uiFlag)
        let uiRestore = try #require(script.range(of: "if uiFailed then",
                                                  range: matched.lowerBound..<script.endIndex))
        _ = try #require(script.range(of: "return \"ui-error\"",
                                      range: uiRestore.upperBound..<script.endIndex))
    }

    /// The operator's clipboard stays untouched while Mail is allowed to take up to 30 seconds.
    /// Once touched, cleanup restores the snapshot only if no one changed the clipboard meanwhile.
    @Test func guiSendDefersAndConditionallyRestoresPasteboard() throws {
        let script = MailScript.sendHtmlGuiScriptSource
        let poll = try #require(script.range(of: "repeat 60 times"))
        let pollEnd = try #require(script.range(of: "end repeat", range: poll.upperBound..<script.endIndex))
        let beforePoll = script[..<poll.lowerBound]
        #expect(!beforePoll.contains("set oldClip to pb's stringForType:"))
        #expect(!beforePoll.contains("pb's clearContents()"))
        #expect(!beforePoll.contains("pb's setData:htmlData forType:"))
        let capture = try #require(script.range(of: "set oldClip to pb's stringForType:",
                                                range: pollEnd.upperBound..<script.endIndex))
        let touched = try #require(script.range(of: "set pasteboardTouched to true",
                                                range: capture.upperBound..<script.endIndex))
        let clear = try #require(script.range(of: "pb's clearContents()",
                                              range: touched.upperBound..<script.endIndex))
        let setData = try #require(script.range(of: "pb's setData:htmlData forType:",
                                                range: clear.upperBound..<script.endIndex))
        let snapshot = try #require(script.range(of:
            "set pasteboardChangeCount to (pb's changeCount()) as integer",
            range: setData.upperBound..<script.endIndex))
        let paste = try #require(script.range(of: "keystroke \"v\" using command down",
                                              range: snapshot.upperBound..<script.endIndex))
        #expect(script.contains("set pasteboardTouched to false"))

        let cleanup = try #require(script.range(of: "if pasteboardTouched then",
                                                range: paste.upperBound..<script.endIndex))
        let unchanged = try #require(script.range(of:
            "if ((pb's changeCount()) as integer) is pasteboardChangeCount then",
            range: cleanup.upperBound..<script.endIndex))
        let cleanupClear = try #require(script.range(of: "pb's clearContents()",
                                                     range: unchanged.upperBound..<script.endIndex))
        _ = try #require(script.range(of: "pb's setString:oldClip",
                                      range: cleanupClear.upperBound..<script.endIndex))
        let lines = Self.trimmedLines(script)
        #expect(lines.filter { $0 == "pb's clearContents()" }.count == 2)
        #expect(lines.filter { $0.hasPrefix("pb's setString:oldClip") }.count == 1)
    }

    /// A refusal sentinel is an expected fail-closed outcome, not an osascript execution fault.
    /// It must therefore retain the typed upstream error envelope instead of escaping as unknown.
    @Test func guiSendRefusalSentinelsMapToUpstreamErrors() {
        let script = MailScript.sendHtmlGuiScriptSource
        #expect(script.contains("return \"wrong-window\""))
        #expect(script.contains("return \"subject-restore-failed\""))
        #expect(script.contains("return \"focus-lost\""))
        #expect(script.contains("return \"ui-error\""))

        for sentinel in ["wrong-window", "subject-restore-failed", "focus-lost", "ui-error"] {
            let error = MailScript.sendHtmlGuiError(for: sentinel)
            #expect(error.type == "upstream_error")
            #expect(error.exitCode == 69)
        }
        #expect(MailScript.sendHtmlGuiError(for: "subject-restore-failed").message
            .contains("[apple-cli-…]"))
        let unexpected = "unexpected-private-sentinel"
        let unexpectedError = MailScript.sendHtmlGuiError(for: unexpected)
        #expect(unexpectedError.type == "unknown")
        #expect(unexpectedError.exitCode == 70)
        #expect(!unexpectedError.message.contains(unexpected))

        let focusReturn = script.range(of: "return \"focus-lost\"")
        let sentReturn = script.range(of: "return \"sent\"")
        let uiReturn = script.range(of: "return \"ui-error\"")
        let matchedReturn = script.range(of: "else if windowMatched then")
        #expect(focusReturn != nil)
        #expect(sentReturn != nil)
        #expect(uiReturn != nil)
        #expect(matchedReturn != nil)
        if let focusReturn, let sentReturn, let uiReturn, let matchedReturn {
            #expect(sentReturn.lowerBound < uiReturn.lowerBound,
                    "a reported send must outrank a later caught UI error")
            #expect(uiReturn.lowerBound < matchedReturn.lowerBound,
                    "ui-error must precede the broader windowMatched refusal arm")
            #expect(focusReturn.lowerBound < matchedReturn.lowerBound,
                    "focus-lost must precede the broader windowMatched refusal arm")
        }
    }

    /// D8 item 5: forward has no mode surface (pins "send") and now inserts its --body prepend via
    /// the oracle's NSPasteboard paste — reading the fragment PATH from argv, NEVER `set content`
    /// (which flattened Mail's forwarded HTML original). An empty fragment path ⇒ no paste.
    @Test func forwardPreambleIsWiredForThePasteFlow() {
        let fwd = MailScript.nativeForwardScriptSource
        #expect(fwd.contains("set theMode to \"send\""))
        #expect(fwd.contains("set htmlPasteRaw to item 3 of argv"))
        // The prepend now travels through the same pasteboard machinery as the HTML reply.
        #expect(fwd.contains("use framework \"Foundation\""))
        #expect(fwd.contains("use framework \"AppKit\""))
        #expect(fwd.contains("NSPasteboardTypeHTML"))
        #expect(fwd.contains("keystroke \"v\" using command down"))
        // The forwarded original's HTML layer is preserved — nothing clobbers `content`.
        #expect(!fwd.contains("set content of m"))
    }

    /// The shared tail branches AFTER the allowlist audit: paste (HTML path), then the
    /// RE-VERIFY (after the paste's multi-second delays — review: they would otherwise
    /// widen the very staleness window the re-verify closes), then draft/open/send — so
    /// every mode passes the SAME guard (ordering pinned by index, not just presence).
    @Test func tailAuditsBeforeAnyDeliveryBranch() throws {
        // The forward script embeds the same shared `guardAndSendTail`, so it pins the ordering
        // independently of the HTML reply (which the paste-specific test below also covers).
        let src = MailScript.nativeForwardScriptSource
        let audit = try #require(src.range(of: "auditedAddrs(m, allowList)"))
        let paste = try #require(src.range(of: "my pasteHtmlIntoWindow(m, htmlPasteRaw)"))
        let reverify = try #require(src.range(of: "collectAddrs(m)"))
        let draftBranch = try #require(src.range(of: "if theMode is \"draft\" then"))
        let openBranch = try #require(src.range(of: "if theMode is \"open\" then"))
        let ladder = try #require(src.range(of: "if theMode is not \"send\" then"))
        let send = try #require(src.range(of: "(send m)"))
        #expect(audit.lowerBound < paste.lowerBound)
        #expect(paste.lowerBound < reverify.lowerBound)
        #expect(reverify.lowerBound < draftBranch.lowerBound)
        #expect(draftBranch.lowerBound < openBranch.lowerBound)
        // Fail-closed mode ladder (review): send is OPT-IN — an unrecognized mode refuses
        // and discards BEFORE the send verb, instead of falling through to it.
        #expect(openBranch.lowerBound < ladder.lowerBound)
        #expect(ladder.lowerBound < send.lowerBound)
        // draft saves via the MEASURED verb pair — reveal the (windowless-composed) window
        // ONLY inside the post-audit draft branch, `save m`, then a close WITHOUT
        // re-saving (a saving-yes close aimed at the message was a silent discard,
        // measured on the live store); and the drafted/opened rows return BEFORE `send m`.
        let reveal = try #require(src.range(of: "set visible of m to true"))
        let saveVerb = try #require(src.range(of: "tell application \"Mail\" to save m"))
        #expect(draftBranch.lowerBound < reveal.lowerBound)
        #expect(reveal.lowerBound < saveVerb.lowerBound)
        #expect(src.contains("close m saving no"))
        #expect(!src.contains("close m saving yes"))
        #expect(src.range(of: "return \"drafted\"")!.lowerBound < send.lowerBound)
        #expect(src.range(of: "return \"opened\"")!.lowerBound < send.lowerBound)
    }

    // MARK: threaded HTML reply (gap15/extra15)

    /// The pasteboard script is the oracle's flow: AppleScriptObjC pasteboard paste into
    /// Mail's native reply window — and NEVER `set content of m`, which clobbers the HTML
    /// layer of Mail's own quoted original (oracle B's engineering comment,
    /// compose.py:601-605, is the whole reason this path exists).
    @Test func htmlReplyScriptPastesAndNeverSetsContent() throws {
        let src = MailScript.nativeReplyHtmlScriptSource
        #expect(src.contains("use framework \"Foundation\""))
        #expect(src.contains("use framework \"AppKit\""))
        #expect(src.contains("NSPasteboardTypeHTML"))
        #expect(!src.contains("set content of m"))
        // Fragment travels by file PATH (argv 12) and is read via NSString — never a
        // shell hop, never interpolated into script source.
        #expect(src.contains("set htmlPasteRaw to item 12 of argv"))
        #expect(src.contains("stringWithContentsOfFile:htmlPath"))
        #expect(!src.contains("do shell script \"cat"))
        // Clipboard is restored after the paste (string layer, best-effort).
        let paste = try #require(src.range(of: "keystroke \"v\" using command down"))
        let restore = try #require(src.range(of: "pb's setString:oldClip"))
        #expect(paste.lowerBound < restore.lowerBound)
        // The paste happens inside the shared tail AFTER the first allowlist audit (a
        // refused reply is discarded unpasted) and BEFORE the re-verify + delivery
        // branches, so a draft files the pasted body and a send sends it with a fresh
        // recipient read AFTER the paste's delays.
        let pasteCall = try #require(src.range(of: "my pasteHtmlIntoWindow(m, htmlPasteRaw)"))
        let audit = try #require(src.range(of: "auditedAddrs(m, allowList)"))
        let reverify = try #require(src.range(of: "collectAddrs(m)"))
        let draftBranch = try #require(src.range(of: "if theMode is \"draft\" then"))
        #expect(audit.lowerBound < pasteCall.lowerBound)
        #expect(pasteCall.lowerBound < reverify.lowerBound)
        #expect(reverify.lowerBound < draftBranch.lowerBound)
        // Composed WINDOWLESS (server-auto-save hardening); the paste handler reveals the
        // window itself, post-audit.
        #expect(src.contains("reply msg opening window false reply to all true"))
        #expect(src.contains("reply msg opening window false reply to all false"))
        // Review H1 (measured): `(missing value) as text` coerces WITHOUT erroring — the
        // read must be tested explicitly so an unreadable fragment refuses instead of
        // pasting (and possibly sending) the literal text "missing value".
        #expect(src.contains("if rawHtml is missing value then error"))
        // Review HIGH (window binding): the blind Cmd-V must land ONLY in the window this
        // call created — nonce-tag the subject, bind the FRONT window on the nonce,
        // restore the subject, refuse unbound; and the keystroke error path restores the
        // clipboard before re-raising.
        let nonce = try #require(src.range(of: "set subject of theMsg to realSubject & \" \" & theNonce"))
        let bind = try #require(src.range(of: "contains theNonce"))
        let restoreSubj = try #require(src.range(of: "set subject of theMsg to realSubject\n"))
        let refuse = try #require(src.range(of: "if not bound then"))
        let key = try #require(src.range(of: "keystroke \"v\" using command down"))
        #expect(nonce.lowerBound < bind.lowerBound)
        #expect(bind.lowerBound < restoreSubj.lowerBound)
        #expect(restoreSubj.lowerBound < refuse.lowerBound)
        #expect(refuse.lowerBound < key.lowerBound)
        // Paste READBACK: the length assertion runs between the keystroke and the shared
        // tail's delivery branches (an unlanded paste must refuse, not send empty).
        #expect(src.contains("paste verification failed"))
        // Clipboard hygiene: the restore helper clears UNCONDITIONALLY (no string flavor
        // to restore still must not leave the email HTML on the pasteboard).
        let handler = try #require(src.range(of: "on restoreClipboard(pb, oldClip)"))
        let clear = try #require(src.range(of: "pb's clearContents()", range: handler.upperBound..<src.endIndex))
        let cond = try #require(src.range(of: "if oldClip is not missing value then", range: handler.upperBound..<src.endIndex))
        #expect(clear.lowerBound < cond.lowerBound)
    }

    /// The four-way routing partition (review M6 — the previous inline version of this
    /// partition shipped a real bug: `--mode draft --html` opened a compose window for a
    /// caller who asked for a draft): exactly ONE path is chosen when executing, none in
    /// preview, across every mode × html × guiSend combination.
    @Test func replyRoutingPartitionIsTotalAndExclusive() {
        for mode in ["send", "draft", "open"] {
            for hasHtml in [false, true] {
                for guiSend in [false, true] where !guiSend || hasHtml {   // guard rejects gui-send without html
                    let r = ReplyRouting.decide(willExecute: true, hasHtml: hasHtml, guiSend: guiSend, mode: mode)
                    #expect([r.nativeHtml, r.openHtml].filter { $0 }.count == 1,
                            "mode=\(mode) html=\(hasHtml) gui=\(guiSend)")
                    let p = ReplyRouting.decide(willExecute: false, hasHtml: hasHtml, guiSend: guiSend, mode: mode)
                    #expect(p == (false, false))
                }
            }
        }
        // D8 item 5: plain → pasteboard for EVERY mode (preserving Mail's HTML quote — the former
        // `set content` `native` path is gone); html+gui → pasteboard; html draft/open →
        // pasteboard; html send w/o gui → the unthreaded no-Accessibility .eml window.
        #expect(ReplyRouting.decide(willExecute: true, hasHtml: false, guiSend: false, mode: "send") == (true, false))
        #expect(ReplyRouting.decide(willExecute: true, hasHtml: false, guiSend: false, mode: "draft") == (true, false))
        #expect(ReplyRouting.decide(willExecute: true, hasHtml: false, guiSend: false, mode: "open") == (true, false))
        #expect(ReplyRouting.decide(willExecute: true, hasHtml: true, guiSend: true, mode: "send") == (true, false))
        #expect(ReplyRouting.decide(willExecute: true, hasHtml: true, guiSend: false, mode: "draft") == (true, false))
        #expect(ReplyRouting.decide(willExecute: true, hasHtml: true, guiSend: false, mode: "open") == (true, false))
        #expect(ReplyRouting.decide(willExecute: true, hasHtml: true, guiSend: false, mode: "send") == (false, true))
    }

    /// The positional argv contract both reply wrappers share (review M6): the scripts read
    /// `item N of argv` positionally — items 3–11 from this array, item 12 the fragment path
    /// appended by nativeReplyHtml — so the ORDER here is the wire contract; a silent swap
    /// ships green everywhere else and fails only against live Mail.
    @Test func replyExtrasOrderIsTheArgvContract() {
        let US = String(UnicodeScalar(31))
        let got = MailScript.replyExtras(body: "B", replyAll: true, sender: "s@x.test",
                                         selfAllowlist: ["a@x.test", "b@x.test"],
                                         attachmentPaths: ["/tmp/a", "/tmp/b"],
                                         cc: ["c@x.test"], bcc: ["d@x.test"],
                                         mailboxHint: "INBOX", mode: "draft")
        #expect(got == ["B", "1", "s@x.test", "a@x.test\(US)b@x.test", "/tmp/a\(US)/tmp/b",
                        "c@x.test", "d@x.test", "INBOX", "draft"])
        // argv positions: [id, account] prefix + these = mode lands at item 11, matching the
        // scripts' `set theMode to item 11 of argv` (pinned above); the html wrapper appends
        // the fragment path as item 12 (`set htmlPasteRaw to item 12 of argv`).
        #expect(got.count + 2 == 11)
    }

    /// Every assembled compose script must actually COMPILE — the seam pin catches the
    /// `end try` merge specifically; this catches the whole class (any two statements
    /// merged at a concatenation seam, anywhere) with the real compiler (review L8).
    @Test func assembledScriptsOsacompile() throws {
        let osacompile = "/usr/bin/osacompile"
        guard FileManager.default.isExecutableFile(atPath: osacompile) else { return }
        for (name, src) in [("replyHtml", MailScript.nativeReplyHtmlScriptSource),
                            ("forward", MailScript.nativeForwardScriptSource),
                            ("saveDraft", MailScript.saveOpenDraftScriptSource),
                            ("sendHtmlGui", MailScript.sendHtmlGuiScriptSource)] {
            let dir = try scratch.directory()
            let srcFile = dir.appendingPathComponent("\(name).applescript")
            try src.write(to: srcFile, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: osacompile)
            proc.arguments = ["-o", dir.appendingPathComponent("\(name).scpt").path, srcFile.path]
            let errPipe = Pipe(); proc.standardError = errPipe
            try proc.run(); proc.waitUntilExit()
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            #expect(proc.terminationStatus == 0, "\(name) failed osacompile: \(err)")
        }
    }
}
