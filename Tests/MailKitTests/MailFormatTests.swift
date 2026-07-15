import Testing
@testable import MailKit

// Pure-function tests for the Mail domain — no TCC, no live data (synthetic rows only).

@Suite("MailFormat")
struct MailFormatTests {
    @Test func isoFromUnixIsUTC() {
        // 1767323045 = 2026-01-02T03:04:05Z
        #expect(MailFormat.iso(fromUnix: 1767323045) == "2026-01-02T03:04:05Z")
        #expect(MailFormat.iso(fromUnix: nil) == nil)
        #expect(MailFormat.iso(fromUnix: 0) == nil)
    }

    @Test func isoDateBoundsRoundTrip() {
        // 2026-01-02T00:00:00Z = 1767312000 (anchored to the known 16:00:45Z = 1767323045).
        #expect(MailFormat.unix(fromISODate: "2026-07-14") == 1767312000)          // 00:00:00Z
        #expect(MailFormat.unix(fromISODate: "2026-07-14", endOfDay: true) == 1767398399) // 23:59:59Z
        #expect(MailFormat.unix(fromISODate: "not-a-date") == nil)
    }

    @Test func isoDateRejectsOutOfRange() {
        // Lenient Calendar would roll these over; strict validation must reject them.
        #expect(MailFormat.unix(fromISODate: "2026-13-45") == nil)   // month 13, day 45
        #expect(MailFormat.unix(fromISODate: "2026-02-30") == nil)   // Feb 30 (round-trip check)
        #expect(MailFormat.unix(fromISODate: "2026-00-10") == nil)   // month 0
        #expect(MailFormat.unix(fromISODate: "26-07-14") == nil)     // 2-digit year
    }

    @Test func personFormatting() {
        #expect(MailFormat.person(name: "Ada Lovelace", address: "ada@x.io") == "Ada Lovelace <ada@x.io>")
        #expect(MailFormat.person(name: nil, address: "ada@x.io") == "ada@x.io")
        #expect(MailFormat.person(name: "", address: "ada@x.io") == "ada@x.io")
        #expect(MailFormat.person(name: "Ada", address: nil) == "Ada")
    }

    @Test func domainExtraction() {
        #expect(MailFormat.domain(ofAddress: "a@Example.COM") == "example.com")
        #expect(MailFormat.domain(ofAddress: "noatsign") == nil)
    }

    @Test func angleBracketStripping() {
        #expect(MailFormat.stripAngleBrackets("<abc@host>") == "abc@host")
        #expect(MailFormat.stripAngleBrackets("abc@host") == "abc@host")
        #expect(MailFormat.stripAngleBrackets("") == nil)
        #expect(MailFormat.stripAngleBrackets(nil) == nil)
    }

    @Test func mailLinkMatchesMCPB() {
        // MCP B leaves @ unencoded, wraps in %3C … %3E.
        #expect(MailFormat.mailLink(internetMessageID: "abc@host.local")
                == "message://%3Cabc@host.local%3E")
        #expect(MailFormat.mailLink(internetMessageID: nil) == nil)
    }
}

@Suite("MailFlagColor")
struct MailFlagColorTests {
    @Test func canonicalNames() {
        #expect(MailFlagColor.red.name == "red")
        #expect(MailFlagColor.purple.name == "purple")
        #expect(MailFlagColor(rawValue: 5) == .purple)
    }

    @Test func readNameOnlyWhenFlagged() {
        #expect(MailFlagColor.readName(flagged: true, flagColor: 0) == "red")
        #expect(MailFlagColor.readName(flagged: true, flagColor: 5) == "purple")
        #expect(MailFlagColor.readName(flagged: false, flagColor: 5) == nil) // not flagged → no color
        #expect(MailFlagColor.readName(flagged: true, flagColor: nil) == nil)
    }

    @Test func tokenParsing() {
        #expect(MailFlagColor.fromToken("RED") == .red)
        #expect(MailFlagColor.fromToken("grey") == .gray)
        #expect(MailFlagColor.fromToken("none") == nil) // none == unflag
        #expect(MailFlagColor.acceptedTokens.count == 8)
    }
}

@Suite("MailboxURL")
struct MailboxURLTests {
    @Test func parsesImapWithNestedDecodedPath() {
        let u = MailboxURL("imap://ABCDEF01-1234-5678-9ABC-DEF012345678/%5BGmail%5D/All%20Mail")
        #expect(u?.scheme == "imap")
        #expect(u?.accountID == "ABCDEF01-1234-5678-9ABC-DEF012345678")
        #expect(u?.path == "[Gmail]/All Mail")
        #expect(u?.leaf == "All Mail")
    }

    @Test func parsesLocalAndInbox() {
        #expect(MailboxURL("imap://UUID/INBOX")?.path == "INBOX")
        #expect(MailboxURL("local://UUID/Recovered%20Messages%20(iCloud)")?.path == "Recovered Messages (iCloud)")
    }

    @Test func rejectsNonURL() {
        #expect(MailboxURL("not a url") == nil)
    }
}

@Suite("EnvelopeIndex.mailboxPredicate")
struct MailboxPredicateTests {
    @Test func directOnly() {
        #expect(EnvelopeIndex.mailboxPredicate(direct: [4, 42], label: []) == "(m.mailbox IN (4,42))")
    }
    @Test func labelOnly() {
        #expect(EnvelopeIndex.mailboxPredicate(direct: [], label: [20])
                == "(m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (20)))")
    }
    @Test func both() {
        let p = EnvelopeIndex.mailboxPredicate(direct: [4], label: [20])
        #expect(p.contains("m.mailbox IN (4)"))
        #expect(p.contains(" OR "))
    }
    @Test func emptyMatchesNothing() {
        #expect(EnvelopeIndex.mailboxPredicate(direct: [], label: []) == "0")
    }
}
