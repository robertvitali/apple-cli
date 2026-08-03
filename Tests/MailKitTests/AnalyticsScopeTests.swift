import Testing
import Foundation
@testable import MailKit

/// `analytics stats` scope semantics, pinned against oracle B (`apple_mail_mcp/tools/analytics.py`).
///
/// The three scopes differ on THREE independent axes — which mailboxes are scanned, whether
/// SKIP_FOLDERS are excluded, and whether `days_back` applies — and the shipped implementation had
/// all three wrong at once, in a single inverted ternary:
///
///     let mbx = (scope == "sender_stats") ? mailbox : "All"     // exactly backwards
///
/// It read as deliberate (it even carried a comment asserting the wrong rule), it compiled, and no
/// test could reach it because it sat behind a live `MailContext`. Hence one test per axis per
/// scope: getting `account_overview` right proves nothing about `mailbox_breakdown`, which differs
/// from it on every axis.
@Suite("analytics stats scope planning (oracle B)")
struct AnalyticsScopeTests {
    func plan(_ scope: String, mailbox: String = "INBOX", days: Int = 30,
              includeSystem: Bool = false) -> Analytics.ScopePlan {
        Analytics.scopePlan(scope: scope, requestedMailbox: mailbox, requestedDays: days,
                            includeSystemFolders: includeSystem)
    }

    // MARK: axis 1 — which mailboxes are scanned

    /// analytics.py:142 — `account_overview` walks `every mailbox of targetAccount`; the `mailbox`
    /// argument is never referenced in that branch.
    @Test("account_overview spans the whole account and IGNORES --mailbox")
    func overviewIgnoresMailbox() {
        #expect(plan("account_overview").mailbox == "All")
        // Even an explicit, non-default mailbox must not narrow it.
        #expect(plan("account_overview", mailbox: "Archive").mailbox == "All")
    }

    /// analytics.py:283 — `sender_stats` also walks every mailbox, filtering with
    /// `sender contains …`. THIS is the one the old code wrongly scoped to `--mailbox`, so it
    /// silently reported INBOX-only numbers as if they were account-wide.
    @Test("sender_stats spans the whole account and IGNORES --mailbox")
    func senderStatsIgnoresMailbox() {
        #expect(plan("sender_stats").mailbox == "All")
        #expect(plan("sender_stats", mailbox: "Archive").mailbox == "All")
    }

    /// analytics.py:351 — `mailbox_breakdown` targets `mailbox "<name>" of targetAccount`,
    /// defaulting to INBOX. The old code forced "All" here, so `--mailbox` was inert: the oracle
    /// capability "break down THIS mailbox" was simply unreachable.
    @Test("mailbox_breakdown HONORS --mailbox and defaults to INBOX")
    func breakdownHonorsMailbox() {
        #expect(plan("mailbox_breakdown").mailbox == "INBOX")
        #expect(plan("mailbox_breakdown", mailbox: "Archive").mailbox == "Archive")
        // The cross-mailbox view stays reachable as a CLI extra — this fix adds the oracle
        // behavior without dropping what was there before.
        #expect(plan("mailbox_breakdown", mailbox: "All").mailbox == "All")
    }

    // MARK: axis 2 — days_back

    @Test("the two broad scopes apply days_back as requested")
    func broadScopesApplyDays() {
        #expect(plan("account_overview", days: 7).daysBack == 7)
        #expect(plan("sender_stats", days: 7).daysBack == 7)
        #expect(plan("account_overview", days: 0).daysBack == 0)
    }

    /// The oracle's breakdown branch has NO `whose date received > targetDate` — it counts
    /// `every message of targetMailbox`. Reporting the requested value while counting all-time
    /// would be a payload the caller cannot detect as wrong, so the plan reports 0.
    @Test("mailbox_breakdown IGNORES days_back and reports the value actually applied")
    func breakdownIgnoresDays() {
        #expect(plan("mailbox_breakdown", days: 30).daysBack == 0)
        #expect(plan("mailbox_breakdown", days: 365).daysBack == 0)
    }

    // MARK: axis 3 — SKIP_FOLDERS exclusion

    /// `skip_folder_checks` is interpolated at exactly two sites, :170 and :314 — the two broad
    /// scans. Nowhere else.
    @Test("the two broad scopes exclude SKIP_FOLDERS by default")
    func broadScopesExcludeSystemFolders() {
        #expect(plan("account_overview").excludeSystemFolders == true)
        #expect(plan("sender_stats").excludeSystemFolders == true)
    }

    /// THE point of keying on the resolved scan scope rather than on `scope`: a caller who names
    /// Trash must get Trash. Filtering it away would return zeroes for a mailbox they explicitly
    /// asked about — a wrong answer dressed as an empty one.
    @Test("a NAMED mailbox is never filtered away, even a system folder")
    func namedSystemFolderSurvives() {
        for name in ["Trash", "Junk", "Sent", "Drafts", "Spam"] {
            #expect(plan("mailbox_breakdown", mailbox: name).excludeSystemFolders == false,
                    "naming \(name) must not filter it out")
        }
    }

    /// `--mailbox All` on breakdown is a CLI extra with no oracle counterpart, so the sensible
    /// default (exclude system folders) applies — and `--include-system-folders` still opts back in.
    @Test("the CLI-extra All breakdown still excludes system folders by default")
    func allBreakdownExcludes() {
        #expect(plan("mailbox_breakdown", mailbox: "All").excludeSystemFolders == true)
    }

    /// `EnvelopeIndex.isAllWildcard` is documented as the single authority on what "All" selects,
    /// specifically so callers cannot desync from it. The first cut re-tested the string with a
    /// case-SENSITIVE `==`, while the resolver compares case-insensitively — so `--mailbox all`
    /// took the resolver's every-mailbox branch while the exclusion silently switched off, sweeping
    /// Trash/Junk/Drafts/Sent into the totals with no `--include-system-folders`. Reproduced live
    /// in review (8 mailboxes and no system folders for `All`; 13 and five system folders for `all`).
    @Test("the All wildcard is recognized case-insensitively, as the resolver does")
    func allWildcardIsCaseInsensitive() {
        for spelling in ["All", "all", "ALL", "aLL"] {
            #expect(plan("mailbox_breakdown", mailbox: spelling).excludeSystemFolders == true,
                    "spelling '\(spelling)' must still exclude system folders")
        }
    }

    /// Oracle: `mailbox_param = escaped_mailbox if mailbox else "INBOX"` (analytics.py:352).
    /// Without this, an empty name matched the account-root entries (whose path is "") and returned
    /// a silently-empty result instead of the INBOX the oracle would have reported.
    @Test("an empty --mailbox falls back to INBOX, as the oracle does")
    func emptyMailboxFallsBackToInbox() {
        #expect(plan("mailbox_breakdown", mailbox: "").mailbox == "INBOX")
        #expect(plan("mailbox_breakdown", mailbox: "   ").mailbox == "INBOX")
    }

    @Test("--include-system-folders disables the exclusion wherever it would apply")
    func includeFlagOptsBackIn() {
        #expect(plan("account_overview", includeSystem: true).excludeSystemFolders == false)
        #expect(plan("sender_stats", includeSystem: true).excludeSystemFolders == false)
        #expect(plan("mailbox_breakdown", mailbox: "All", includeSystem: true)
                    .excludeSystemFolders == false)
    }

    // MARK: breakdown labelling (the payload's only mailbox identifier)

    func row(_ mailboxRowid: Int) -> Analytics.Row {
        Analytics.Row(rowid: mailboxRowid * 100, senderAddress: "a@b.test", senderName: "A",
                      subject: "s", dateReceived: 1, read: false, flagged: false,
                      hasAttachment: false, mailboxRowid: mailboxRowid, snippet: nil)
    }

    /// A named breakdown labels its single entry with the mailbox the CALLER asked for.
    ///
    /// Labelling by the backing store (what the rowid resolves to) is wrong on label-backed
    /// accounts: Gmail's INBOX is a label over `[Gmail]/All Mail`, so `--mailbox INBOX` and
    /// `--mailbox Receipts` both reported `path: "[Gmail]/All Mail"` — right counts, an identifier
    /// naming neither request, and two different queries indistinguishable in the payload.
    /// Leaf-matching can also map one name to several rowids, which split into duplicate entries
    /// under one label. Both collapse to a single correctly-named entry.
    @Test("a named breakdown reports the REQUESTED mailbox, not the backing store's path")
    func namedBreakdownLabelsByRequest() {
        let rows = [row(7), row(7), row(9)]   // two backing rowids, as a Gmail label spread would give
        let r = Analytics.statistics(rows, scope: "mailbox_breakdown", account: "Gmail", daysBack: 0,
                                     namedMailbox: "INBOX") { _ in "[Gmail]/All Mail" }
        #expect(r.mailbox_breakdown?.count == 1)
        #expect(r.mailbox_breakdown?.first?.path == "INBOX")
        #expect(r.mailbox_breakdown?.first?.count == 3)
        #expect(r.mailbox == "INBOX")
    }

    /// The `All` sweep keeps the real per-mailbox fan-out — the fix must not flatten it.
    @Test("an All-scoped breakdown still fans out by real mailbox path")
    func allBreakdownStillFansOut() {
        let rows = [row(7), row(7), row(9)]
        let r = Analytics.statistics(rows, scope: "mailbox_breakdown", account: "iCloud", daysBack: 0,
                                     namedMailbox: nil) { rowid in "Mailbox-\(rowid)" }
        #expect(r.mailbox_breakdown?.count == 2)
        #expect(Set(r.mailbox_breakdown?.map(\.path) ?? []) == ["Mailbox-7", "Mailbox-9"])
        #expect(r.mailbox == "All")
    }

    // MARK: the regression itself

    /// Direct pin on the inverted ternary. `sender_stats` and `mailbox_breakdown` must resolve to
    /// DIFFERENT mailbox scopes, and specifically not each other's — swapping them is precisely
    /// the shipped bug, and a test that only checked one scope would have passed through it.
    @Test("REGRESSION: sender_stats and mailbox_breakdown are not swapped")
    func scopesAreNotSwapped() {
        let sender = plan("sender_stats", mailbox: "Archive")
        let breakdown = plan("mailbox_breakdown", mailbox: "Archive")
        #expect(sender.mailbox == "All" && breakdown.mailbox == "Archive")
        #expect(sender.mailbox != breakdown.mailbox)
        // account_overview must match sender_stats, not breakdown — all three differ from the
        // "one rule for everything" shape the bug collapsed them into.
        #expect(plan("account_overview", mailbox: "Archive").mailbox == sender.mailbox)
    }
}
