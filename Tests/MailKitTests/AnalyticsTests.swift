import Testing
@testable import MailKit

@Suite("Analytics")
struct AnalyticsTests {
    private func row(_ rowid: Int, _ addr: String, _ name: String?, _ subject: String,
                     read: Bool = false, flagged: Bool = false, att: Bool = false,
                     date: Int = 1_784_000_000, mailbox: Int = 4) -> Analytics.Row {
        Analytics.Row(rowid: rowid, senderAddress: addr, senderName: name, subject: subject,
                      dateReceived: date, read: read, flagged: flagged, hasAttachment: att, mailboxRowid: mailbox)
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

    @Test func awaitingReplyExcludesNoreplyAndPreSendReplies() {
        // Sent only to a noreply address → excluded when excludeNoreply.
        let toNoreply = [Analytics.SentItem(subject: "Ticket", recipients: ["noreply@svc.com"], dateSent: 100, rowid: 1)]
        #expect(Analytics.awaitingReply(sent: toNoreply, received: [], excludeNoreply: true).isEmpty)
        // A "reply" dated BEFORE the send is not a reply → the sent item is still awaiting.
        let sent = [Analytics.SentItem(subject: "Q3", recipients: ["bob@x.io"], dateSent: 200, rowid: 2)]
        let preSend = [Analytics.ReceivedItem(normalizedSubject: "q3", senderAddress: "bob@x.io", dateReceived: 100)]
        #expect(Analytics.awaitingReply(sent: sent, received: preSend, excludeNoreply: true).count == 1)
    }

    @Test func awaitingReplyFindsUnanswered() {
        let sent = [
            Analytics.SentItem(subject: "Project update", recipients: ["bob@x.io"], dateSent: 100, rowid: 10),
            Analytics.SentItem(subject: "Lunch?", recipients: ["cara@x.io"], dateSent: 200, rowid: 11),
        ]
        let received = [
            // Bob replied (normalized subject matches, later date) → NOT awaiting.
            Analytics.ReceivedItem(normalizedSubject: "project update", senderAddress: "bob@x.io", dateReceived: 150),
        ]
        let awaiting = Analytics.awaitingReply(sent: sent, received: received, excludeNoreply: true)
        #expect(awaiting.count == 1)
        #expect(awaiting.first?.subject == "Lunch?")   // Cara never replied
    }
}

/// MCP B excludes `SKIP_FOLDERS` (constants.py) from broad scans. Counting them made every CLI
/// volume metric disagree with the oracle: on a live account over 7 days the CLI
/// reported total=28 where the oracle reported 17; with this filter it reports 17 — an exact
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
