import Testing
import Foundation
@testable import MailKit

/// Q11-B pins (gap13): oracle B's summary contract — every account keeps a row, an unreadable
/// inbox is the -1 ERROR sentinel (inbox.py `counts[acct_name] = -1`), and the sentinel never
/// poisons the CLI-extra total_unread.
@Suite("Unread summary sentinel (Q11-B)")
struct UnreadSummaryTests {

    private func row(_ a: String, _ n: Int) -> MailScript.UnreadRow {
        MailScript.UnreadRow(account: a, mailbox: "INBOX", unread: n)
    }

    @Test func sentinelRowsSurviveAndDoNotPoisonTotal() {
        let (flat, total) = UnreadSummary.build([row("A", 5), row("B", -1), row("C", 0)])
        #expect(flat == ["A": 5, "B": -1, "C": 0])
        // total sums only readable inboxes: 5 + 0. Before gap13, an unreadable inbox DROPPED
        // the account row entirely (bare `try … end try` with no on-error arm).
        #expect(total == 5)
    }

    @Test func healthyRowsAggregatePerAccount() {
        let (flat, total) = UnreadSummary.build([row("A", 2), row("A", 3)])
        #expect(flat == ["A": 5])
        #expect(total == 5)
    }

    /// STICKY sentinel: a -1 followed by a positive row for the SAME key must stay -1, never
    /// become -1 + n (neither a count nor the sentinel). Unreachable while summary emits one
    /// row per account, but Mail permits duplicate display names — security-review latent case.
    @Test func sentinelIsStickyAgainstLaterSameNameRows() {
        let (flat, total) = UnreadSummary.build([row("A", -1), row("A", 7), row("B", 2)])
        #expect(flat == ["A": -1, "B": 2])
        #expect(total == 2)
    }

    /// The unreadScript's summary branch must carry oracle B's Inbox fallback + -1 arm, and the
    /// nested branch the one-level "Parent/Child" descent — pinned as source text because the
    /// script only executes against live Mail.app (the AppleScript-compile bats covers syntax).
    @Test func unreadScriptCarriesOracleBArms() {
        let src = MailScript.unreadScriptSource
        #expect(src.contains("mailbox \"Inbox\" of a"))          // INBOX/Inbox fallback (gap13)
        #expect(src.contains("US & \"-1\" & RS"))                 // -1 error sentinel (gap13)
        #expect(src.contains("every mailbox of mbx"))            // one-level descent (gap4)
        #expect(src.contains("mn & \"/\" & sn"))                  // "Parent/Child" key shape (gap4)
    }
}
