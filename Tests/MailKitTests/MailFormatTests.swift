import Testing
import Foundation
@testable import MailKit

// Pure-function tests for the Mail domain — no TCC, no live data (synthetic rows only).

@Suite("MailFormat")
struct MailFormatTests {
    @Test func isoFromUnixIsUTC() {
        // 1767323045 = 2026-01-02T03:04:05Z (invented anchor)
        #expect(MailFormat.iso(fromUnix: 1767323045) == "2026-01-02T03:04:05Z")
        #expect(MailFormat.iso(fromUnix: nil) == nil)
        #expect(MailFormat.iso(fromUnix: 0) == nil)
    }

    @Test func isoDateBoundsRoundTrip() {
        // 2026-01-02T00:00:00Z = 1767312000 (anchored to the invented 03:04:05Z = 1767323045).
        #expect(MailFormat.unix(fromISODate: "2026-01-02") == 1767312000)          // 00:00:00Z
        #expect(MailFormat.unix(fromISODate: "2026-01-02", endOfDay: true) == 1767398399) // 23:59:59Z
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
        #expect(MailFormat.person(name: "Ada Lovelace", address: "ada@example.com") == "Ada Lovelace <ada@example.com>")
        #expect(MailFormat.person(name: nil, address: "ada@example.com") == "ada@example.com")
        #expect(MailFormat.person(name: "", address: "ada@example.com") == "ada@example.com")
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
        #expect(MailFlagColor.readName(flagged: true, flagColor: 0) == "orange") // index 0 = orange (oracle map)
        #expect(MailFlagColor.readName(flagged: true, flagColor: 5) == "purple")
        #expect(MailFlagColor.readName(flagged: false, flagColor: 5) == nil) // not flagged → no color
        #expect(MailFlagColor.readName(flagged: true, flagColor: nil) == nil)
    }

    /// STRICT-SUPERSET PARITY: each color token must map to the SAME `mark flag index` the MCP oracle
    /// (`apple-mail-mcp` `utils.py` `get_flag_index`) writes, so `flag --color X` and rule `flag_color=X`
    /// set the color the oracle would (and the read path names it back the same). Pinned to LITERAL
    /// oracle values — NOT `MailFlagColor.X.rawValue`, which is self-referential and can't catch enum
    /// drift. macOS Mail's real order is non-obvious (orange=0, red=1, and green/blue swapped). If this
    /// fails, the enum drifted from the oracle: fix `MailFlagColor`, not this test.
    @Test func oracleFlagIndexParity() {
        let oracle: [(String, Int)] = [
            ("orange", 0), ("red", 1), ("yellow", 2), ("blue", 3),
            ("green", 4), ("purple", 5), ("gray", 6),
        ]
        for (token, idx) in oracle {
            #expect(MailFlagColor.fromToken(token)?.rawValue == idx, "flag_color=\(token) must map to oracle index \(idx)")
            #expect(MailFlagColor.readName(flagged: true, flagColor: idx) == token, "index \(idx) must read back as \(token)")
        }
        #expect(MailFlagColor.fromToken("none") == nil) // none == unflag, no index
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

/// Oracle B strips reply/forward prefixes from a thread keyword before matching
/// (`tools/search.py` thread_keywords). Without it, `thread --subject "Re: Budget"` matches only
/// the replies and misses the thread's original message — the opposite of what a thread lookup
/// is for.
@Suite("Thread subject prefix stripping")
struct ThreadPrefixTests {
    @Test func stripsTheOraclesPrefixList() {
        #expect(MailFormat.stripThreadPrefixes("Re: Budget") == "Budget")
        #expect(MailFormat.stripThreadPrefixes("RE: Budget") == "Budget")
        #expect(MailFormat.stripThreadPrefixes("Fwd: Budget") == "Budget")
        #expect(MailFormat.stripThreadPrefixes("FW: Budget") == "Budget")
        #expect(MailFormat.stripThreadPrefixes("Fw: Budget") == "Budget")
    }

    /// Real threads stack prefixes; one pass would leave "Fwd: Re: Budget".
    @Test func stripsStackedPrefixesToTheBareSubject() {
        #expect(MailFormat.stripThreadPrefixes("Re: Fwd: Re: Budget") == "Budget")
        #expect(MailFormat.stripThreadPrefixes("  RE:   Fw:  Q3 plan ") == "Q3 plan")
    }

    /// Superset of the oracle, which only matches its fixed-case list.
    @Test func matchingIsCaseInsensitive() {
        #expect(MailFormat.stripThreadPrefixes("re: budget") == "budget")
        #expect(MailFormat.stripThreadPrefixes("fWd: budget") == "budget")
    }

    /// A subject that merely CONTAINS the letters must not be mangled — only a leading prefix
    /// followed by a colon is a thread marker.
    @Test func leavesNonPrefixSubjectsIntact() {
        #expect(MailFormat.stripThreadPrefixes("Budget") == "Budget")
        #expect(MailFormat.stripThreadPrefixes("Regarding: Budget") == "Regarding: Budget")
        #expect(MailFormat.stripThreadPrefixes("Fwd budget") == "Fwd budget")
        #expect(MailFormat.stripThreadPrefixes("Renewal: Q3") == "Renewal: Q3")
        // Degenerate input must terminate, not loop.
        #expect(MailFormat.stripThreadPrefixes("Re:") == "")
        #expect(MailFormat.stripThreadPrefixes("Re: Re: Re:") == "")
        #expect(MailFormat.stripThreadPrefixes("") == "")
    }
}

/// The selection AppleScript emits LOCAL calendar components (numeric, so locale-independent);
/// this converts them to the same UTC `…Z` form `MailFormat.iso` produces for the index path.
/// Without it one `selected` response could carry two different time semantics in
/// `date_received` — index rows in UTC, selection-only rows in naive local — silently off by the
/// machine's UTC offset.
@Suite("Selection date UTC normalization")
struct SelectionDateTests {
    private var ny: TimeZone { TimeZone(identifier: "America/New_York")! }

    @Test func convertsLocalComponentsToUTC() {
        // 2026-01-24 19:08:52 EST (UTC-5) == 2026-01-25T00:08:52Z
        #expect(MailScript.utcFromLocalComponents("2026-01-24T19:08:52", timeZone: ny) == "2026-01-25T00:08:52Z")
        // DST: 2026-07-04 23:30:00 EDT (UTC-4) == 2026-07-05T03:30:00Z
        #expect(MailScript.utcFromLocalComponents("2026-07-04T23:30:00", timeZone: ny) == "2026-07-05T03:30:00Z")
    }

    @Test func aUTCMachineIsAPassThrough() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(MailScript.utcFromLocalComponents("2026-03-01T12:00:00", timeZone: utc) == "2026-03-01T12:00:00Z")
    }

    /// A wrong timestamp is worse than an absent one, so unparseable input yields nil.
    @Test func unparseableInputIsNilNotAGuess() {
        #expect(MailScript.utcFromLocalComponents("", timeZone: ny) == nil)
        #expect(MailScript.utcFromLocalComponents("not a date", timeZone: ny) == nil)
        #expect(MailScript.utcFromLocalComponents("2026-01-24", timeZone: ny) == nil)
    }
}
