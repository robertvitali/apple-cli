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
            row(2, "friend@x.io", "Friend", "Can you review this?"),              // "?" → HIGH
            row(3, "colleague@x.io", "Colleague", "FYI notes"),                   // NORMAL
            row(4, "boss@x.io", "Boss", "done", read: true),                      // read → skip
        ]
        let items = Analytics.needsResponse(rows, maxResults: 10)
        #expect(items.count == 2)                        // 1 automated + 1 read excluded
        #expect(items.first?.subject == "Can you review this?")
        #expect(items.first?.priority == "HIGH")
    }

    @Test func normalizeSubjectStripsPrefixes() {
        #expect(Analytics.normalizeSubject("Re: Fwd: Budget Plan") == "budget plan")
        #expect(Analytics.normalizeSubject("Fw:  Hello ") == "hello")
    }

    @Test func needsResponsePriorityRanking() {
        let rows = [
            row(1, "a@x.io", "A", "just fyi"),          // score 0
            row(2, "b@x.io", "B", "can you review?"),   // "?" → HIGH
            row(3, "c@x.io", "C", "URGENT please"),     // urgent keyword → NORMAL
        ]
        let items = Analytics.needsResponse(rows, maxResults: 5)
        #expect(items.first?.subject == "can you review?")   // "?" ranks highest
        #expect(items.first?.priority == "HIGH")
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
