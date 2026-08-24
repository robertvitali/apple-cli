import Testing
import Foundation
import AppleKit
@testable import MailKit

/// Q11-G pins (gap2 / gap9 / gap45): the pure halves of the live body search and the oracle
/// export layout. The live halves are pinned in bats against the real store.
@Suite("Search/export parity (Q11-G)")
struct SearchExportParityTests {

    private struct ProbeError: Error {}

    // MARK: gap45 — export file names (oracle layout, verified verbatim from analytics.py)

    @Test func oracleSingleEmailNameIsSubjectOnly() {
        let names = ExportCommand.plannedFiles(layout: "oracle", scope: "single_email",
                                               mailbox: "INBOX", format: "txt",
                                               messages: [(id: "42", subject: "Q3 report/final")])
        // '/'→'-' is the oracle's ONLY substitution; NO id prefix; file sits directly in --dir.
        #expect(names == ["Q3 report-final.txt"])
    }

    @Test func oracleMailboxLayoutNumbersOneBasedInsideExportDir() {
        let names = ExportCommand.plannedFiles(layout: "oracle", scope: "entire_mailbox",
                                               mailbox: "INBOX", format: "html",
                                               messages: [(id: "1", subject: "A"), (id: "2", subject: "B/C")])
        #expect(names == ["INBOX_export/1_A.html", "INBOX_export/2_B-C.html"])
    }

    /// The '/'→'-' pass runs over the MAILBOX segment too — a nested mailbox name must not
    /// become a path that escapes the export directory.
    @Test func nestedMailboxNameCannotEscapeTheExportDir() {
        let names = ExportCommand.plannedFiles(layout: "oracle", scope: "entire_mailbox",
                                               mailbox: "Work/../../etc", format: "txt",
                                               messages: [(id: "1", subject: "S")])
        #expect(names == ["Work-..-..-etc_export/1_S.txt"])
        #expect(!names[0].contains("/../"))
    }

    /// Disclosed CLI deviation: names cap at 150 UTF-8 BYTES before the extension (the oracle
    /// would hit the filesystem's 255-byte component limit and error mid-export). Bytes, not
    /// Characters — 150 CJK graphemes are 450 bytes (the repo's recurring
    /// grapheme-vs-code-unit class, review-caught here too).
    @Test func oracleNamesAreCappedAt150Bytes() {
        let long = String(repeating: "x", count: 400)
        let names = ExportCommand.plannedFiles(layout: "oracle", scope: "single_email",
                                               mailbox: "INBOX", format: "txt",
                                               messages: [(id: "1", subject: long)])
        #expect(names == [String(repeating: "x", count: 150) + ".txt"])
        // 3-byte CJK: 150 bytes = 50 whole characters, never a split scalar.
        let cjk = String(repeating: "語", count: 400)
        let cjkNames = ExportCommand.plannedFiles(layout: "oracle", scope: "single_email",
                                                  mailbox: "INBOX", format: "txt",
                                                  messages: [(id: "1", subject: cjk)])
        #expect(cjkNames == [String(repeating: "語", count: 50) + ".txt"])
        #expect(cjkNames[0].dropLast(4).utf8.count <= 150)
    }

    /// A blank subject must not produce a HIDDEN dotfile (the oracle writes ".txt") or a bare
    /// "1_.txt" — disclosed fallback.
    @Test func emptySubjectFallsBackToUntitled() {
        let single = ExportCommand.plannedFiles(layout: "oracle", scope: "single_email",
                                                mailbox: "INBOX", format: "txt",
                                                messages: [(id: "1", subject: "  ")].map { (id: $0.id, subject: "") })
        #expect(single == ["untitled.txt"])
    }

    @Test func flatLayoutKeepsTheLegacyIdPrefixedNames() {
        let names = ExportCommand.plannedFiles(layout: "flat", scope: "entire_mailbox",
                                               mailbox: "INBOX", format: "txt",
                                               messages: [(id: "7", subject: "Hello/World")])
        #expect(names == ["7-Hello-World.txt"])
    }

    // MARK: gap2 — body-search script structure (executes only against live Mail)

    /// Source-text pins on the oracle-shape invariants. The script only runs against live
    /// Mail.app, and a live execution in the logic tier would scan real mail for minutes.
    @Test func bodySearchScriptCarriesTheOracleShape() {
        let src = MailScript.bodySearchScriptSource
        // argv-fed (never interpolated — the injection class the repo refuses).
        #expect(src.contains("on run argv"))
        // The oracle's SKIP_FOLDERS list, verbatim, gated on the All sweep + the
        // --include-system-folders escape.
        #expect(src.contains(#"{"Trash", "Junk", "Junk Email", "Deleted Items", "Sent", "Sent Items", "Sent Messages", "Drafts", "Spam", "Deleted Messages"}"#))
        #expect(src.contains(#"if mbxName is "All" and includeSystem is not "include" then"#))
        // Early exit at every loop level (account / mailbox / message) — the oracle's
        // collectLimit discipline is what bounds a content scan.
        #expect(src.components(separatedBy: "if collectLimit <= 0 then exit repeat").count - 1 == 3)
        // The body read comes LAST, after every cheap predicate (the oracle reads content
        // unconditionally per message — its timeout cause #2).
        if let att = src.range(of: #"attMode is "no""#), let content = src.range(of: "set msgContent to content of aMessage") {
            #expect(att.upperBound <= content.lowerBound)
        } else {
            Issue.record("expected attachment predicate and content read in the script")
        }
        // Locale-safe date bounds: HOST-computed local components rebuilt field-by-field,
        // with the `set day to 1` rollover guard FIRST — never a locale-dependent
        // `date "<string>"` literal, and never local-1970-epoch arithmetic (measured 4-5h
        // off the index path's instant).
        #expect(src.contains("on datebound(spec)"))
        if let dayGuard = src.range(of: "set day of d to 1"),
           let year = src.range(of: "set year of d to") {
            #expect(dayGuard.upperBound <= year.lowerBound)
        } else {
            Issue.record("expected the day-rollover guard before the year assignment")
        }
        #expect(!src.contains("to date \""))
        #expect(!src.contains("epochBase"))
        // The oracle's own 180-second Apple-event timeout remains inside the script; the CLI
        // adds a 195-second aggregate osascript deadline by default and can explicitly disable it.
        #expect(src.contains("with timeout of 180 seconds"))
        // Security H1: the emitted Message-ID is REMOTE-chosen — the script must neutralize
        // the RS wire delimiter inside it before appending to the RS-joined blob.
        if let neut = src.range(of: "set mid to (message id of aMessage) as string"),
           let emit = src.range(of: "set out to out & mid & RS") {
            #expect(neut.upperBound <= emit.lowerBound)
        } else {
            Issue.record("expected the Message-ID RS-neutralization block before the emit")
        }
    }

    @Test func bodySearchUsesTheOverallRunnerDeadline() throws {
        #expect(MailScript.bodySearchAppleEventTimeoutSeconds == 180)
        #expect(MailScript.bodySearchHostTimeoutSeconds == 195)
        #expect(MailScript.bodySearchHostTimeoutSeconds
                > MailScript.bodySearchAppleEventTimeoutSeconds)

        var observedScript = ""
        var observedArguments: [String] = []
        var observedTimeout: TimeInterval = 0
        var untimedCalls = 0
        let ids = try bodySearch(
            hostTimeout: TimeInterval(MailScript.bodySearchHostTimeoutSeconds),
            timedRun: { script, arguments, timeout in
                observedScript = script
                observedArguments = arguments
                observedTimeout = timeout
                return "message-id@example.com\u{1E}"
            },
            untimedRun: { _, _ in
                untimedCalls += 1
                return ""
            })

        #expect(observedScript.contains("with timeout of 180 seconds"))
        #expect(observedArguments.first == "needle")
        #expect(observedTimeout == TimeInterval(MailScript.bodySearchHostTimeoutSeconds))
        #expect(untimedCalls == 0)
        #expect(ids == ["message-id@example.com"])
    }

    @Test func bodySearchZeroOverrideUsesOnlyTheUntimedRunner() throws {
        var timedCalls = 0
        var untimedCalls = 0
        let ids = try bodySearch(
            hostTimeout: nil,
            timedRun: { _, _, _ in
                timedCalls += 1
                return ""
            },
            untimedRun: { script, arguments in
                untimedCalls += 1
                #expect(script.contains("with timeout of 180 seconds"))
                #expect(arguments.first == "needle")
                return "message-id@example.com\u{1E}"
            })

        #expect(timedCalls == 0)
        #expect(untimedCalls == 1)
        #expect(ids == ["message-id@example.com"])
    }

    @Test func bodySearchDeadlineIsUpstreamAndNeverPartialSuccess() throws {
        let error = #expect(throws: AppleError.self) {
            _ = try bodySearch(
                hostTimeout: 12,
                timedRun: { _, _, timeout in
                    #expect(timeout == 12)
                    throw AppleScriptRunner.TimeoutError(seconds: 12)
                },
                untimedRun: { _, _ in "" })
        }
        let upstream = try #require(error)
        #expect(upstream.type == AppleErrorType.upstream)
        #expect(upstream.exitCode == AppleExit.upstream)
        #expect(upstream.message == "Mail body search exceeded its 12-second aggregate deadline; no partial results returned. Narrow with --mailbox/--account, raise the cap with --body-live-timeout <seconds>, pass 0 for oracle B's unbounded aggregate behavior, or drop --body-live.")
    }

    @Test func bodySearchPreservesNonTimeoutFailures() {
        #expect(throws: ProbeError.self) {
            _ = try bodySearch(
                hostTimeout: 12,
                timedRun: { _, _, _ in throw ProbeError() },
                untimedRun: { _, _ in "" })
        }
    }

    private func bodySearch(
        hostTimeout: TimeInterval?,
        timedRun: (String, [String], TimeInterval) throws -> String,
        untimedRun: (String, [String]) throws -> String
    ) throws -> [String] {
        try MailScript.bodySearch(
            needle: "needle", subjectTerms: ["subject"], sender: nil,
            readStatus: nil, flagged: nil, fromUnix: nil, toUnix: nil,
            hasAttachment: nil, accountName: "Example Account", mailboxName: "INBOX",
            collectLimit: 2, includeSystemFolders: false, hostTimeout: hostTimeout,
            timedRun: timedRun, untimedRun: untimedRun)
    }

    @Test func bodyLiveTimeoutOptionResolvesDefaultCustomAndUnbounded() throws {
        #expect(try SearchCommand.resolveBodyLiveTimeout(raw: nil, bodyLive: true) == 195)
        #expect(try SearchCommand.resolveBodyLiveTimeout(raw: "12.5", bodyLive: true) == 12.5)
        #expect(try SearchCommand.resolveBodyLiveTimeout(raw: "0", bodyLive: true) == nil)
    }

    @Test func bodyLiveTimeoutOptionRejectsInvalidOrInertValues() throws {
        let overMaximum = String(Int(AppleScriptRunner.maximumTimeoutSeconds) + 1)
        for raw in ["-1", "-0", "nan", "inf", overMaximum, "not-a-number"] {
            let error = #expect(throws: AppleError.self) {
                _ = try SearchCommand.resolveBodyLiveTimeout(raw: raw, bodyLive: true)
            }
            let validation = try #require(error)
            #expect(validation.type == AppleErrorType.validation)
            #expect(validation.exitCode == AppleExit.usage)
        }

        #expect(try SearchCommand.resolveBodyLiveTimeout(
            raw: String(Int(AppleScriptRunner.maximumTimeoutSeconds)), bodyLive: true)
            == AppleScriptRunner.maximumTimeoutSeconds)

        let inert = #expect(throws: AppleError.self) {
            _ = try SearchCommand.resolveBodyLiveTimeout(raw: "0", bodyLive: false)
        }
        #expect(try #require(inert).message.contains("requires --body-live"))
    }

    /// gap2 paging core (reviews H2/H3/B2): saturating collect bounds + the oracle's
    /// sort-then-slice page verdict with skip-aware cursor advance.
    @Test func liveBodyPageArithmetic() {
        // Oracle's limit+1 probe; saturates at scanCap for operator-sized inputs and limit 0.
        #expect(LiveBodyPage.collectLimit(offset: 0, limit: 2) == 3)
        #expect(LiveBodyPage.collectLimit(offset: 5, limit: 2) == 8)
        #expect(LiveBodyPage.collectLimit(offset: 0, limit: 0) == LiveBodyPage.scanCap)
        #expect(LiveBodyPage.collectLimit(offset: Int.max - 1, limit: 5) == LiveBodyPage.scanCap)
        #expect(LiveBodyPage.collectLimit(offset: Int.max, limit: Int.max) == LiveBodyPage.scanCap)
        // Oracle probe: 3 resolved with limit 2 → more (len(sorted) > limit); cursor advances
        // by the oracle's client contract (offset+limit) plus skipped slots.
        let p1 = LiveBodyPage.page(resolved: 3, unindexed: 0, offset: 0, limit: 2,
                                   totalIDs: 3, collectLimit: 100)
        #expect(p1.hasMore && p1.nextOffset == 2)
        // H3a: skipped ids consumed scan slots — the cursor must jump them too.
        let p2 = LiveBodyPage.page(resolved: 2, unindexed: 2, offset: 0, limit: 2,
                                   totalIDs: 4, collectLimit: 100)
        #expect(p2.hasMore && p2.nextOffset == 4)
        // H3b: a scan truncated at the collect bound reports has_more even when everything
        // resolved fit the page.
        let p3 = LiveBodyPage.page(resolved: 2, unindexed: 1, offset: 0, limit: 3,
                                   totalIDs: 3, collectLimit: 3)
        #expect(p3.hasMore)
        // Exhausted scan, page not filled: cleanly done.
        let p4 = LiveBodyPage.page(resolved: 2, unindexed: 0, offset: 1, limit: 3,
                                   totalIDs: 3, collectLimit: 100)
        #expect(!p4.hasMore && p4.nextOffset == nil)
        // limit 0 (all): more only when the scan hit the cap; cursor covers the whole window.
        let p5 = LiveBodyPage.page(resolved: 4, unindexed: 1, offset: 0, limit: 0,
                                   totalIDs: 5, collectLimit: 5)
        #expect(p5.hasMore && p5.nextOffset == 5)
        // Extreme offset: no trap, no bogus next_offset.
        let p6 = LiveBodyPage.page(resolved: 0, unindexed: 0, offset: Int.max - 1, limit: 2,
                                   totalIDs: 10, collectLimit: 100)
        #expect(p6.hasMore ? p6.nextOffset == nil || p6.nextOffset! > 0 : p6.nextOffset == nil)
    }

    /// gap9 window core (review H2): the oracle's max_emails counts messages EXAMINED — the
    /// newest `per` rows are windowed FIRST, the unread filter applies INSIDE the window.
    @Test func perAccountWindowCountsExaminedNotReturned() {
        func row(_ id: Int, read: Int) -> [String: String?] { ["rowid": String(id), "read": String(read)] }
        let rows = [row(1, read: 1), row(2, read: 0), row(3, read: 0), row(4, read: 0)]
        // Window of 2 (newest first): one read + one unread → ONE unread row, not two.
        let w = ListCommand.perAccountWindow(rows, per: 2, unreadOnly: true)
        #expect(w.count == 1 && (w[0]["rowid"] ?? nil) == "2")
        // Without the filter, the window itself.
        #expect(ListCommand.perAccountWindow(rows, per: 2, unreadOnly: false).count == 2)
        // per 0 = no per-account cap; filter still applies inside.
        #expect(ListCommand.perAccountWindow(rows, per: 0, unreadOnly: true).count == 3)
    }

    /// Security H1 second layer, pure: a token still carrying a C0/DEL byte after the split is
    /// DROPPED — a forged `a<RS>4233` id must never yield a bare `4233` (which would resolve as
    /// an arbitrary Envelope-Index ROWID and emit an attacker-chosen message as a "match").
    @Test func bodySearchIDParserDropsControlCharacterTokens() {
        let rs = "\u{1E}"
        #expect(MailScript.parseBodySearchIDs("good1@x\(rs)good2@y\(rs)") == ["good1@x", "good2@y"])
        // In-script neutralization turns the forged id into one token with "_": kept, harmless.
        #expect(MailScript.parseBodySearchIDs("a_4233\(rs)") == ["a_4233"])
        // Defense in depth: a token that STILL carries a control byte (e.g. VT) is dropped
        // whole, never split into a forged row.
        #expect(MailScript.parseBodySearchIDs("bad\u{0B}id\(rs)ok@z\(rs)") == ["ok@z"])
        #expect(MailScript.parseBodySearchIDs("") == [])
    }
}
