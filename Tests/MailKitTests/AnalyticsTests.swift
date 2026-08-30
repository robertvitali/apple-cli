import Testing
@testable import MailKit

@Suite("Analytics")
struct AnalyticsTests {
    private func row(_ rowid: Int, _ addr: String, _ name: String?, _ subject: String,
                     read: Bool = false, flagged: Bool = false, att: Bool = false,
                     date: Int = 1_784_000_000, mailbox: Int = 4) -> Analytics.Row {
        Analytics.Row(rowid: rowid, senderAddress: addr, senderName: name, subject: subject,
                      dateReceived: date, read: read, flagged: flagged, hasAttachment: att,
                      mailboxRowid: mailbox, snippet: nil)
    }

    @Test func topSendersRanksAndPercentages() {
        let rows = [
            row(1, "a@x.io", "Alice", "hi"),
            row(2, "a@x.io", "Alice", "hi2"),
            row(3, "b@y.io", "Bob", "yo"),
            row(4, "c@z.io", "Cara", "sup"),
        ]
        let r = Analytics.topSenders(rows, topN: 2, byDomain: false, account: "iCloud", mailbox: "INBOX", daysBack: 30)
        #expect(r.total_analyzed == 4)
        #expect(r.unique_senders == 3)
        #expect(r.senders.first?.address == "a@x.io")
        #expect(r.senders.first?.count == 2)
        #expect(r.senders.first?.percentage == 50.0)
        #expect(r.senders.count == 2)   // topN cap
    }

    @Test func topSendersByDomain() {
        let rows = [row(1, "a@shop.com", "A", "x"), row(2, "b@shop.com", "B", "y"), row(3, "c@other.com", "C", "z")]
        let r = Analytics.topSenders(rows, topN: 5, byDomain: true, account: "iCloud", mailbox: "INBOX", daysBack: 0)
        #expect(r.senders.first?.sender == "shop.com")
        #expect(r.senders.first?.count == 2)
    }

    @Test func statisticsCounts() {
        let rows = [
            row(1, "a@x.io", "A", "s1", read: true),
            row(2, "b@x.io", "B", "s2", read: false, flagged: true),
            row(3, "c@x.io", "C", "s3", read: false, att: true),
        ]
        let r = Analytics.statistics(rows, scope: "account_overview", account: "iCloud", daysBack: 30) { _ in "INBOX" }
        #expect(r.total == 3)
        #expect(r.unread == 2)
        #expect(r.read == 1)
        #expect(r.flagged == 1)
        #expect(r.with_attachments == 1)
        #expect(r.mailbox_breakdown?.first?.path == "INBOX")
    }

    @Test func needsResponseSkipsAutomatedAndRanksQuestions() {
        let rows = [
            row(1, "noreply@bank.com", "Bank", "Your statement is ready"),        // automated → skip
            row(2, "friend@x.io", "Friend", "Can you review this?"),              // "?" unflagged → MEDIUM
            row(3, "colleague@x.io", "Colleague", "FYI notes"),                   // NORMAL
            row(4, "boss@x.io", "Boss", "done", read: true),                      // read → skip
        ]
        let items = Analytics.needsResponse(rows, maxResults: 10)
        #expect(items.count == 2)                        // 1 automated + 1 read excluded
        #expect(items.first?.subject == "Can you review this?")
        // Oracle B's label for an UNFLAGGED question is MEDIUM, not HIGH — the CLI previously
        // collapsed both into "HIGH" and had no MEDIUM bucket at all.
        #expect(items.first?.priority == "MEDIUM (contains question)")
    }

    @Test func normalizeSubjectStripsPrefixes() {
        #expect(Analytics.normalizeSubject("Re: Fwd: Budget Plan") == "budget plan")
        #expect(Analytics.normalizeSubject("Fw:  Hello ") == "hello")
    }

    @Test func needsResponsePriorityRanking() {
        let rows = [
            row(1, "a@x.io", "A", "just fyi"),          // score 0
            row(2, "b@x.io", "B", "can you review?"),   // "?" unflagged → MEDIUM
            row(3, "c@x.io", "C", "URGENT please"),     // urgent keyword → NORMAL
        ]
        let items = Analytics.needsResponse(rows, maxResults: 5)
        #expect(items.first?.subject == "can you review?")   // "?" ranks highest
        #expect(items.first?.priority == "MEDIUM (contains question)")
        #expect(items.last?.priority == "NORMAL")
    }

    private func rcpt(_ address: String, name: String? = nil) -> Analytics.SentRecipient {
        Analytics.SentRecipient(display: name.map { "\($0) <\(address)>" } ?? address, address: address)
    }

    @Test func awaitingReplyExcludesNoreplyAndPreSendReplies() {
        // Sent only to a noreply address → excluded when excludeNoreply.
        let toNoreply = [Analytics.SentItem(subject: "Ticket", recipients: [rcpt("noreply@svc.com")], dateSent: 100, rowid: 1)]
        #expect(Analytics.awaitingReply(sent: toNoreply, received: [], excludeNoreply: true).isEmpty)
        // A "reply" dated BEFORE the send is not a reply → the sent item is still awaiting.
        let sent = [Analytics.SentItem(subject: "Q3", recipients: [rcpt("bob@x.io")], dateSent: 200, rowid: 2)]
        let preSend = [Analytics.ReceivedItem(normalizedSubject: "q3", senderAddress: "bob@x.io", dateReceived: 100)]
        #expect(Analytics.awaitingReply(sent: sent, received: preSend, excludeNoreply: true).count == 1)
    }

    @Test func awaitingReplyFindsUnanswered() {
        let sent = [
            Analytics.SentItem(subject: "Project update", recipients: [rcpt("bob@x.io")], dateSent: 100, rowid: 10),
            Analytics.SentItem(subject: "Lunch?", recipients: [rcpt("cara@x.io")], dateSent: 200, rowid: 11),
        ]
        let received = [
            // Bob replied (normalized subject matches, later date) → NOT awaiting.
            Analytics.ReceivedItem(normalizedSubject: "project update", senderAddress: "bob@x.io", dateReceived: 150),
        ]
        let awaiting = Analytics.awaitingReply(sent: sent, received: received, excludeNoreply: true)
        #expect(awaiting.count == 1)
        #expect(awaiting.first?.subject == "Lunch?")   // Cara never replied
    }

    /// gap44: the reported recipient is oracle B's `name & " <" & addr & ">"` display string,
    /// not the bare address the matching keys on.
    @Test func awaitingReplyReportsTheDisplayRecipient() {
        let sent = [Analytics.SentItem(subject: "Contract", recipients: [rcpt("cara@x.io", name: "Cara Lee")],
                                       dateSent: 200, rowid: 12)]
        let awaiting = Analytics.awaitingReply(sent: sent, received: [], excludeNoreply: true)
        #expect(awaiting.first?.recipient == "Cara Lee <cara@x.io>")
    }

    /// review H3: selection and ordering are the ORACLE'S two-bucket emit — the collected set
    /// is the NEWEST max qualifying candidates, high bucket (question OR flagged) first in scan
    /// order, then NORMAL in scan order. A NORMAL item never precedes a high-bucket item even
    /// when newer; the old global score-sort put a MEDIUM question above a HIGH flagged item,
    /// contradicting its own labels, and ranked on an urgent-keyword term the oracle lacks.
    @Test func needsResponseUsesTheOraclesTwoBucketOrder() {
        let rows = [
            row(1, "a@x.io", "A", "old flagged", flagged: true, date: 100),
            row(2, "b@x.io", "B", "newer normal fyi", date: 300),
            row(3, "c@x.io", "C", "middle question?", date: 200),
        ]
        let items = Analytics.needsResponse(rows, maxResults: 10)
        // High bucket in date order (question 200 after? no — scan is newest-first: q(200), flagged(100)),
        // then the NEWEST item of all — a NORMAL — comes LAST despite being newest.
        #expect(items.map(\.subject) == ["middle question?", "old flagged", "newer normal fyi"])
        #expect(items.map(\.rank) == [1, 2, 3])
        // An urgent keyword confers NO rank (the oracle has no such term).
        let urgent = [row(4, "d@x.io", "D", "URGENT deadline asap", date: 50),
                      row(5, "e@x.io", "E", "plain note", date: 60)]
        #expect(Analytics.needsResponse(urgent, maxResults: 10).first?.subject == "plain note")
    }

    /// review H3: the cap keeps the NEWEST max qualifying candidates (the oracle exits its
    /// newest-first walk once it has collected max_results), THEN partitions — not the top-max
    /// after a global ranking.
    @Test func needsResponseCapKeepsTheNewestCandidates() {
        let rows = [
            row(1, "a@x.io", "A", "oldest question?", date: 100),
            row(2, "b@x.io", "B", "new normal", date: 300),
            row(3, "c@x.io", "C", "newest normal", date: 400),
        ]
        let items = Analytics.needsResponse(rows, maxResults: 2)
        // The two NEWEST candidates are both normal; the old score-sort would have kept the
        // question instead.
        #expect(items.map(\.subject) == ["newest normal", "new normal"])
        // maxResults 0 → empty, never a trap (review H5 pure half).
        #expect(Analytics.needsResponse(rows, maxResults: 0).isEmpty)
    }

    /// review B1: the awaiting-reply subject test is the oracle's BIDIRECTIONAL containment
    /// (smart_inbox.py:178) shared with needs-response — exact equality was silently stricter
    /// (a reply whose normalized subject gains words was missed).
    @Test func awaitingReplySubjectMatchIsBidirectionalContainment() {
        let sent = [Analytics.SentItem(subject: "Budget", recipients: [rcpt("bob@x.io")], dateSent: 100, rowid: 20)]
        let contained = [Analytics.ReceivedItem(normalizedSubject: "budget plan for q3", senderAddress: "bob@x.io", dateReceived: 150)]
        #expect(Analytics.awaitingReply(sent: sent, received: contained, excludeNoreply: true).isEmpty)
        // Empty normalized subjects never match everything (the CLI's disclosed guard —
        // AppleScript's `contains ""` is true, so ONE empty subject would suppress all).
        let emptyRec = [Analytics.ReceivedItem(normalizedSubject: "", senderAddress: "bob@x.io", dateReceived: 150)]
        #expect(Analytics.awaitingReply(sent: sent, received: emptyRec, excludeNoreply: true).count == 1)
    }

    /// review (missing-pin list): awaitingReply preserves INPUT order — the command feeds
    /// newest-first rows and applies --max AFTER filtering, so order preservation is what makes
    /// that the newest max still-unanswered sends.
    @Test func awaitingReplyPreservesInputOrder() {
        let sent = [
            Analytics.SentItem(subject: "First", recipients: [rcpt("a@x.io")], dateSent: 300, rowid: 31),
            Analytics.SentItem(subject: "Second", recipients: [rcpt("b@x.io")], dateSent: 200, rowid: 32),
            Analytics.SentItem(subject: "Third", recipients: [rcpt("c@x.io")], dateSent: 100, rowid: 33),
        ]
        #expect(Analytics.awaitingReply(sent: sent, received: [], excludeNoreply: true).map(\.subject)
                == ["First", "Second", "Third"])
    }

    /// gap44: exclude-noreply filters recipients on EXACTLY the oracle's four patterns
    /// (smart_inbox.py:92). A recipient the broader SENDER marker list would drop — e.g.
    /// `notifications@` or `postmaster@` — is KEPT, matching the oracle.
    @Test func excludeNoreplyUsesExactlyTheOraclesFourRecipientPatterns() {
        #expect(Analytics.noreplyRecipientPatterns == ["noreply", "no-reply", "do-not-reply", "donotreply"])
        for a in ["noreply@x.io", "no-reply@x.io", "do-not-reply@x.io", "donotreply@x.io"] {
            #expect(Analytics.isNoreplyRecipient(a), "expected \(a) filtered")
        }
        for a in ["notifications@x.io", "postmaster@x.io", "mailer-daemon@x.io", "support@x.io"] {
            #expect(!Analytics.isNoreplyRecipient(a), "expected \(a) kept — sender markers must not leak into the recipient filter")
        }
        let sent = [Analytics.SentItem(subject: "Ping", recipients: [rcpt("notifications@svc.io")], dateSent: 100, rowid: 13)]
        #expect(Analytics.awaitingReply(sent: sent, received: [], excludeNoreply: true).count == 1)
    }
}

/// MCP B excludes `SKIP_FOLDERS` (constants.py) from broad scans. Counting them made every CLI
/// volume metric disagree with the oracle: on a live account over 7 days the CLI
/// reported a higher total than the oracle; with this filter the totals match exactly — an exact
/// live-oracle match on total/unread/read/flagged/with_attachments.
@Suite("SKIP_FOLDERS system-folder exclusion")
struct SkipFoldersTests {
    @Test func matchesTheOraclesFolderList() {
        for leaf in ["Trash", "Junk", "Junk Email", "Deleted Items", "Sent", "Sent Items",
                     "Sent Messages", "Drafts", "Spam", "Deleted Messages"] {
            #expect(Analytics.isSkippedSystemFolder("/Users/x/Library/Mail/V10/ACC/\(leaf).mbox"
                        .replacingOccurrences(of: ".mbox", with: "")),
                    "expected '\(leaf)' to be skipped")
        }
    }

    /// Matching is on the LAST path component, so a nested provider folder still matches...
    @Test func matchesTheLeafOfANestedPath() {
        #expect(Analytics.isSkippedSystemFolder("iCloud/[Gmail]/Trash"))
        #expect(Analytics.isSkippedSystemFolder("Gmail/[Gmail]/Sent Mail") == false) // not in the list
        #expect(Analytics.isSkippedSystemFolder("Work/Archive/Drafts"))
    }

    /// ...and a USER folder whose name merely contains a listed word is NOT skipped — over-broad
    /// matching would silently drop real mail from every metric.
    @Test func doesNotMatchUserFoldersContainingTheWord() {
        #expect(Analytics.isSkippedSystemFolder("INBOX") == false)
        #expect(Analytics.isSkippedSystemFolder("Sent to accountant") == false)
        #expect(Analytics.isSkippedSystemFolder("Trashy newsletters") == false)
        #expect(Analytics.isSkippedSystemFolder("Archive") == false)
        #expect(Analytics.isSkippedSystemFolder("") == false)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(Analytics.isSkippedSystemFolder("acct/TRASH"))
        #expect(Analytics.isSkippedSystemFolder("acct/deleted messages"))
    }
}

/// Needs-response parity with MCP B (`tools/smart_inbox.py` + `constants.py`): the four exact
/// priority labels, the newsletter suppression list, and the already-replied cross-reference.
/// All three were absent, so the CLI surfaced newsletters and already-answered threads as mail
/// awaiting a personal reply, and reported an unflagged question as HIGH.
@Suite("Needs-response oracle parity")
struct NeedsResponseParityTests {
    private func row(_ id: Int, _ addr: String, _ name: String, _ subj: String,
                     flagged: Bool = false, snippet: String? = nil) -> Analytics.Row {
        Analytics.Row(rowid: id, senderAddress: addr, senderName: name, subject: subj,
                      dateReceived: 1_700_000_000 + id, read: false, flagged: flagged,
                      hasAttachment: false, mailboxRowid: 1, snippet: snippet)
    }

    /// gap40: the automated-sender list is EXACTLY oracle B's seven markers (smart_inbox.py:320).
    /// The negative half is the fix: the CLI's earlier 17-marker heuristic dropped `support@` /
    /// `info@` / `alerts@` / bare `notification` senders the oracle KEEPS — real correspondence
    /// silently vanishing from needs-response. (`updates@`/`news@` stay dropped via the separate
    /// newsletter keyword list, matching the oracle's newsletter_condition.)
    @Test func automatedSenderListIsExactlyTheOraclesSeven() {
        #expect(Analytics.oracleAutomatedMarkers == ["noreply", "no-reply", "donotreply", "do-not-reply",
                                                     "notifications@", "mailer-daemon", "postmaster@"])
        for a in ["noreply@bank.com", "no-reply@x.io", "donotreply@x.io", "do-not-reply@x.io",
                  "notifications@github.com", "mailer-daemon@x.io", "postmaster@x.io"] {
            #expect(Analytics.isAutomatedSender(address: a, name: nil), "expected \(a) automated")
        }
        for a in ["support@vendor.com", "info@shop.com", "alerts@bank.com", "friend@x.io"] {
            #expect(!Analytics.isAutomatedSender(address: a, name: nil),
                    "expected \(a) KEPT — the over-broad marker dropped real correspondence")
        }
        // A marker in the display NAME counts too (B matches its combined lowerSender string).
        #expect(Analytics.isAutomatedSender(address: "x@y.io", name: "Mailer-Daemon"))
    }

    /// gap40 end-to-end: a support@ sender now REACHES needs-response (it was silently dropped).
    @Test func supportSendersReachNeedsResponse() {
        let rows = [row(1, "support@vendor.com", "Vendor Support", "Any update on your ticket?")]
        let items = Analytics.needsResponse(rows, maxResults: 5)
        #expect(items.count == 1)
        #expect(items.first?.priority == "MEDIUM (contains question)")
    }

    /// gap40's other half, end-to-end (review H2): an `updates@` sender is STILL dropped — by
    /// the NEWSLETTER keyword filter, exactly as the oracle's newsletter_condition drops it.
    /// This is the pin that locks the two-filter structure: deleting the isNewsletterSender
    /// term from the needsResponse chain would pass every marker-list pin and fail only here.
    @Test func updatesSendersStayDroppedByTheNewsletterFilter() {
        #expect(!Analytics.isAutomatedSender(address: "updates@shop.com", name: nil),
                "updates@ is NOT an automated marker…")
        #expect(Analytics.isNewsletterSender(address: "updates@shop.com", name: nil),
                "…it is a newsletter keyword")
        let rows = [row(1, "updates@shop.com", "Shop", "Big sale this week?")]
        #expect(Analytics.needsResponse(rows, maxResults: 5).isEmpty)
    }

    /// review (missing-pin list): days 0 = all time (oracle's `days_back > 0` conditional).
    @Test func sinceUnixTreatsZeroDaysAsAllTime() {
        #expect(sinceUnix(daysBack: 0) == nil)
        #expect(sinceUnix(daysBack: -3) == nil)
        #expect(sinceUnix(daysBack: 7) != nil)
    }

    /// gap44 seam (review missing-pin list): To recipients come BEFORE CC in the pair list —
    /// `recipients.first` is what awaiting-reply REPORTS, approximating the oracle's
    /// `item 1 of messageRecipients` (To-only). A name-only display with no parseable address
    /// is KEPT with an empty address (review L4), never dropped.
    @Test func sentRecipientPairsAreToBeforeCCAndKeepNameOnly() {
        let pairs = sentRecipientPairs(to: ["Ann <ann@x.io>"], cc: ["Cee <cee@x.io>", "Just A Name"])
        #expect(pairs.map(\.address) == ["ann@x.io", "cee@x.io", ""])
        #expect(pairs.map(\.display) == ["Ann <ann@x.io>", "Cee <cee@x.io>", "Just A Name"])
    }

    /// All four of B's label strings, verbatim.
    @Test func emitsTheOraclesFourPriorityLabels() {
        #expect(Analytics.priorityLabel(flagged: true, hasQuestion: true) == "HIGH (flagged + question)")
        #expect(Analytics.priorityLabel(flagged: true, hasQuestion: false) == "HIGH (flagged)")
        #expect(Analytics.priorityLabel(flagged: false, hasQuestion: true) == "MEDIUM (contains question)")
        #expect(Analytics.priorityLabel(flagged: false, hasQuestion: false) == "NORMAL")
    }

    @Test func dropsNewsletterSendersFromBothOraclePatternLists() {
        // platform patterns
        for a in ["hello@mail.substack.com", "x@beehiiv.com", "a@mailchimp.com", "b@sendgrid.net",
                  "c@convertkit.com", "d@buttondown.email", "e@ghost.io", "f@revue.co", "g@mailgun.org"] {
            #expect(Analytics.isNewsletterSender(address: a, name: nil), "expected \(a) to be a newsletter")
        }
        // keyword patterns
        for a in ["newsletter@x.io", "digest@x.io", "weekly@x.io", "daily@x.io",
                  "bulletin@x.io", "briefing@x.io", "news@x.io", "updates@x.io"] {
            #expect(Analytics.isNewsletterSender(address: a, name: nil), "expected \(a) to be a newsletter")
        }
        #expect(Analytics.isNewsletterSender(address: "friend@example.com", name: "A Friend") == false)
        #expect(Analytics.isNewsletterSender(address: nil, name: nil) == false)
    }

    @Test func newsletterSendersNeverReachTheResults() {
        let rows = [row(1, "hello@substack.com", "Some Writer", "Is this interesting?"),
                    row(2, "friend@x.io", "Friend", "Can you review?")]
        let items = Analytics.needsResponse(rows, maxResults: 10)
        #expect(items.count == 1)
        #expect(items.first?.sender_address == "friend@x.io")
    }

    /// B strips prefixes from the first 200 Sent subjects and drops any candidate matching one
    /// under BIDIRECTIONAL containment — a thread you already answered is not awaiting you.
    @Test func alreadyRepliedThreadsAreSuppressed() {
        #expect(Analytics.alreadyReplied(subject: "Re: Budget plan", sentSubjects: ["Budget plan"]))
        #expect(Analytics.alreadyReplied(subject: "Budget", sentSubjects: ["Re: Budget plan"]))   // other direction
        #expect(Analytics.alreadyReplied(subject: "Unrelated", sentSubjects: ["Budget plan"]) == false)
        #expect(Analytics.alreadyReplied(subject: "Budget", sentSubjects: []) == false)
        // An empty subject must not match everything via containment.
        #expect(Analytics.alreadyReplied(subject: "", sentSubjects: ["anything"]) == false)
        #expect(Analytics.alreadyReplied(subject: "Budget", sentSubjects: [""]) == false)
    }

    @Test func alreadyRepliedCandidatesAreDropped() {
        let rows = [row(1, "a@x.io", "A", "Re: Budget plan"), row(2, "b@x.io", "B", "New topic")]
        let items = Analytics.needsResponse(rows, maxResults: 10, sentSubjects: ["Budget plan"])
        #expect(items.count == 1)
        #expect(items.first?.subject == "New topic")
    }

    /// B looks for "?" in the body, not just the subject; the indexed preview is our stand-in.
    @Test func questionInThePreviewCountsNotJustTheSubject() {
        let r = row(1, "a@x.io", "A", "Quick note", snippet: "Hi — could you confirm the date?")
        #expect(Analytics.needsResponse([r], maxResults: 5).first?.priority == "MEDIUM (contains question)")
    }
}
