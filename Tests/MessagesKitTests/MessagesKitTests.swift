import Testing
import Foundation
@testable import MessagesKit
import AppleKit

// Reference values were computed from the parity oracle: Python `difflib.
// SequenceMatcher.ratio`, the MCP `fuzzy_match` token rules, and the MCP
// `extract_body_from_attributed` byte format. See docs/port-specs/messages.md.

// MARK: - difflib.SequenceMatcher.ratio (contacts)

@Suite("SequenceMatcher.ratio parity")
struct SequenceRatioTests {
    private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func matchesPythonDifflib() {
        #expect(approx(Fuzzy.sequenceRatio("alex", "alexis"), 0.8))
        #expect(approx(Fuzzy.sequenceRatio("jan", "janine"), 2.0 / 3.0))
        #expect(approx(Fuzzy.sequenceRatio("mike", "michael"), 6.0 / 11.0))
        #expect(approx(Fuzzy.sequenceRatio("jon", "john"), 6.0 / 7.0))
        #expect(approx(Fuzzy.sequenceRatio("cat", "dog"), 0.0))
    }

    @Test func emptyStrings() {
        #expect(approx(Fuzzy.sequenceRatio("", ""), 1.0))
        #expect(approx(Fuzzy.sequenceRatio("abc", ""), 0.0))
    }

    // Multi-block / transposition inputs that exercise the recursive
    // find_longest_match splitting (single-block pairs above don't). Reference
    // values computed from Python difflib.SequenceMatcher.
    @Test func multiBlockMatchesPythonDifflib() {
        #expect(approx(Fuzzy.sequenceRatio("abcabc", "cabcab"), 0.8333333333))
        #expect(approx(Fuzzy.sequenceRatio("ababab", "babab"), 0.9090909091))
        #expect(approx(Fuzzy.sequenceRatio("mcmxyz", "xyzmc"), 0.5454545455))
        #expect(approx(Fuzzy.sequenceRatio("kitten", "sitting"), 0.6153846154))
        #expect(approx(Fuzzy.sequenceRatio("aaa", "aaaa"), 0.8571428571))
    }
}

// MARK: - Contact token scoring (MCP fuzzy_match)

@Suite("Contact fuzzy_match parity")
struct ContactMatchTests {
    private func score(_ q: String, _ name: String) -> Double? {
        Fuzzy.matchContacts(query: q, candidates: [.init(name: name, value: "x")]).first?.score
    }

    @Test func exactTokenScores095() {
        #expect(score("alex", "Alex Smith").map { abs($0 - 0.95) < 1e-9 } == true)
        #expect(score("jane", "Jane Doe").map { abs($0 - 0.95) < 1e-9 } == true)
    }

    @Test func exactFullMatchScores1() {
        #expect(score("john smith", "John Smith").map { abs($0 - 1.0) < 1e-9 } == true)
    }

    @Test func belowThresholdExcluded() {
        // "mike" vs token "michael" = 0.5454… < 0.6 → no match.
        #expect(Fuzzy.matchContacts(query: "mike", candidates: [.init(name: "Michael Brown", value: "x")]).isEmpty)
        // "ale" prefix of "alexander" scores only 0.283; full ratio 0.333 → no match.
        #expect(Fuzzy.matchContacts(query: "ale", candidates: [.init(name: "Alexander Jones", value: "x")]).isEmpty)
        // Unrelated → excluded.
        #expect(Fuzzy.matchContacts(query: "xyz", candidates: [.init(name: "Jane Doe", value: "x")]).isEmpty)
    }

    @Test func prefixScoring() {
        // query "ale" is prefix of single token "alex": 0.85 * (3/4) = 0.6375 ≥ 0.6.
        let s = score("ale", "Alex")
        #expect(s.map { abs($0 - 0.85 * (3.0 / 4.0)) < 1e-9 } == true)
    }

    @Test func nicknameCandidateMatches() {
        // A nickname candidate is searchable (findByName adds it); here direct.
        let s = score("bob", "Bob")
        #expect(s.map { abs($0 - 1.0) < 1e-9 } == true)
    }

    @Test func rankingIsScoreDescending() {
        let candidates: [Fuzzy.ContactCandidate] = [
            .init(name: "Alexander", value: "1"),   // prefix, lower
            .init(name: "Alex", value: "2"),        // exact token 0.95
        ]
        let r = Fuzzy.matchContacts(query: "alex", candidates: candidates)
        #expect(r.count == 2)
        #expect(r[0].value == "2") // exact-token 0.95 ranks first
    }
}

// MARK: - Text normalization

@Suite("Normalization")
struct NormalizationTests {
    @Test func normalizePhoneKeepsDigits() {
        #expect(Fuzzy.normalizePhone("+1 (212) 555-0100") == "12125550100")
        #expect(Fuzzy.normalizePhone("no digits!") == "")
    }

    @Test func cleanNameStripsPunctAndEmoji() {
        #expect(Fuzzy.cleanName("Bob 😀 Smith!!") == "Bob Smith")
        #expect(Fuzzy.cleanName("  multiple   spaces  ") == "multiple spaces")
        #expect(Fuzzy.cleanName("O'Brien-Jones") == "O'Brien-Jones") // apostrophe + hyphen kept
    }

    @Test func fullProcessLowercasesAndSpacesNonAlnum() {
        #expect(Fuzzy.fullProcess("Hello, World!") == "hello  world") // comma+! → spaces (no collapse)
        #expect(Fuzzy.fullProcess("café") == "caf") // non-ascii dropped
    }
}

// MARK: - WRatio (message search) behavioral properties

@Suite("WRatio behavior")
struct WRatioTests {
    @Test func identicalStringsScore100() {
        #expect(Fuzzy.wRatio("hello world", "hello world") == 100.0)
        #expect(Fuzzy.wRatio("ramsay", "ramsay") == 100.0)
    }

    @Test func emptyScoresZero() {
        #expect(Fuzzy.wRatio("", "anything") == 0.0)
        #expect(Fuzzy.wRatio("anything", "") == 0.0)
    }

    @Test func unrelatedScoresLow() {
        #expect(Fuzzy.wRatio("ramsay", "the quick brown fox jumps") < 60.0)
    }

    @Test func matchesLiveOracleRamsayCases() {
        // Live MCP parity (docs the oracle run): both borderline messages score ≥ 60
        // (threshold 0.6) so they are RETURNED, matching the MCP's 4-result set.
        #expect(Fuzzy.wRatio("ramsay", "translate mcp to cli then public repo") >= 60.0)
        #expect(Fuzzy.wRatio("ramsay", "we had squash producer duo dreams") >= 60.0)
    }
}

// MARK: - attributedBody decode (synthetic typedstream blobs)

@Suite("attributedBody decode")
struct AttributedBodyTests {
    // Byte arrays produced by the Python reference `extract_body_from_attributed` format.
    @Test func decodesShortTexts() {
        let hello: [UInt8] = [2, 43, 129, 0, 0, 78, 83, 83, 116, 114, 105, 110, 103, 1, 148, 132, 1, 43, 13,
                              72, 101, 108, 108, 111, 44, 32, 119, 111, 114, 108, 100, 33, 134, 132]
        #expect(AttributedBody.decode(Data(hello)) == "Hello, world!")

        let short: [UInt8] = [2, 43, 129, 0, 0, 78, 83, 83, 116, 114, 105, 110, 103, 1, 148, 132, 1, 43, 5,
                              115, 104, 111, 114, 116, 134, 132]
        #expect(AttributedBody.decode(Data(short)) == "short")

        let hi: [UInt8] = [2, 43, 129, 0, 0, 78, 83, 83, 116, 114, 105, 110, 103, 1, 148, 132, 1, 43, 2,
                           104, 105, 134, 132]
        #expect(AttributedBody.decode(Data(hi)) == "hi")
    }

    @Test func decodesLongTextViaTwoByteLength() {
        // 200 'A's → 0x81 length prefix (200, 0).
        var blob: [UInt8] = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2b, 0x81, 200, 0]
        blob += Array(repeating: UInt8(ascii: "A"), count: 200)
        let decoded = AttributedBody.decode(Data(blob))
        #expect(decoded?.count == 200)
        #expect(decoded == String(repeating: "A", count: 200))
    }

    @Test func noNSStringMarkerReturnsNil() {
        #expect(AttributedBody.decode(Data([0x01, 0x02, 0x03, 0x04])) == nil)
    }

    @Test func truncatedBlobReturnsNil() {
        // Claims length 50 but only a few bytes follow.
        let blob: [UInt8] = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2b, 50, 0x41, 0x42]
        #expect(AttributedBody.decode(Data(blob)) == nil)
    }
}

// MARK: - Apple-epoch time

@Suite("MessageTime")
struct MessageTimeTests {
    @Test func nanosRoundTrip() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ns = MessageTime.thresholdNanos(hoursAgo: 0, now: now)
        let back = MessageTime.date(fromRaw: ns)
        #expect(abs(back.timeIntervalSince1970 - now.timeIntervalSince1970) < 1.0)
    }

    @Test func hoursAgoIsEarlier() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let t0 = MessageTime.thresholdNanos(hoursAgo: 0, now: now)
        let t24 = MessageTime.thresholdNanos(hoursAgo: 24, now: now)
        #expect(t24 < t0)
        #expect(t0 - t24 == Int64(24 * 3600) * 1_000_000_000)
    }

    @Test func legacySecondsTimestampHandled() {
        // A 9-digit value is treated as seconds, not nanoseconds.
        let d = MessageTime.date(fromRaw: 600_000_000)
        // 2001 + ~19 years ≈ 2020; must be after the Apple epoch.
        #expect(d.timeIntervalSince1970 > MessageTime.appleUnixOffset)
    }

    @Test func localStringFormat() {
        let s = MessageTime.localString(from: Date(timeIntervalSince1970: 1_700_000_000))
        // yyyy-MM-dd HH:mm:ss
        #expect(s.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil)
    }
}

// MARK: - Send resolution + script safety

@Suite("Send")
struct SendTests {
    @Test func classifiesPhone() {
        if case let .resolved(handle, _) = Send.resolve(recipient: "+1 (212) 555-0100", groupChat: false, book: AddressBook()) {
            #expect(handle == "12125550100")
        } else { Issue.record("expected resolved phone") }
    }

    @Test func classifiesEmail() {
        if case let .resolved(handle, _) = Send.resolve(recipient: "a@b.com", groupChat: false, book: AddressBook()) {
            #expect(handle == "a@b.com")
        } else { Issue.record("expected resolved email") }
    }

    @Test func groupChatPassesThrough() {
        if case let .resolved(handle, _) = Send.resolve(recipient: "iMessage;+;chat123", groupChat: true, book: AddressBook()) {
            #expect(handle == "iMessage;+;chat123")
        } else { Issue.record("expected resolved group id") }
    }

    @Test func unknownNameNotFound() {
        if case .notFound = Send.resolve(recipient: "Nonexistent Person", groupChat: false, book: AddressBook()) {
        } else { Issue.record("expected notFound for unknown name in empty book") }
    }

    @Test func interpretResults() {
        #expect(Send.interpret("success:iMessage") == (true, "iMessage", nil))
        #expect(Send.interpret("success:SMS").service == "SMS")
        #expect(Send.interpret("error:boom").ok == false)
        #expect(Send.interpret("error:boom").error == "boom")
    }

    @Test func scriptsAreArgvDriven() {
        // Security: recipient/body arrive via `on run argv`, never interpolated.
        #expect(Send.directScript().contains("on run argv"))
        #expect(Send.directScript().contains("item 1 of argv"))
        #expect(Send.groupScript().contains("chat id chatId"))
    }

    // [L3] Allowlist footgun fix: normalize BOTH sides before comparing.
    @Test func normalizeForAllowlist() {
        #expect(Send.normalizeForAllowlist("+1 (212) 555-0142") == "12125550142")
        #expect(Send.normalizeForAllowlist("  Bob@Example.COM ") == "bob@example.com")
    }

    @Test func phonesEquivalentAcrossCountryCode() {
        #expect(Send.phonesEquivalent("12125550142", "2125550142"))  // CC vs no-CC
        #expect(Send.phonesEquivalent("2125550142", "2125550142"))
        #expect(Send.phonesEquivalent("12125550142", "12125550142"))
        #expect(!Send.phonesEquivalent("12125550142", "12125550150"))
        // A digit-normalized handle matches a raw "+1…" allowlist entry once both
        // are run through normalizeForAllowlist.
        let handle = Send.normalizeForAllowlist("2125550142")
        let allow = Send.normalizeForAllowlist("+1-212-555-0142")
        #expect(Send.phonesEquivalent(allow, handle))
    }

    /// v1 asserted "throws when APPLE_TEST_MODE is unset". Write-model v2 INVERTS that: the
    /// allowlist is a sandbox-only restriction, and unsandboxed the CLI sends to anyone exactly as
    /// `tool_send_message` does. The fail-closed property survives where it matters — INSIDE the
    /// sandbox — and that is what is pinned here.
    @Test func allowlistIsSandboxOnlyAndFailsClosedInsideIt() {
        // Unsandboxed: a no-op. A throw here means the v1 gate was silently reinstated, which
        // would make the domain non-parity again.
        #expect(throws: Never.self) {
            try Send.assertAllowedRecipient("2125550142", sandboxActive: false)
        }
        #expect(throws: Never.self) {
            try Send.assertAllowedRecipient("+1 (212) 555-0150", sandboxActive: false)
        }
        // Sandboxed with an EMPTY/unset APPLE_TEST_RECIPIENTS (the state of this test process):
        // every recipient is refused, not every recipient allowed. This is THE fail-closed
        // property — an allowlist that defaults to "permit all" on a send surface would be the
        // worst possible default.
        #expect(throws: (any Error).self) {
            try Send.assertAllowedRecipient("2125550142", sandboxActive: true)
        }
        // A group-chat id can never match a phone/email allowlist entry, so sandboxed group send
        // stays unreachable by construction (HUMAN-DECISIONS.md D4).
        #expect(throws: (any Error).self) {
            try Send.assertAllowedRecipient("iMessage;-;chat123456789", sandboxActive: true)
        }
    }
}

// MARK: - Write-model v2 posture (docs/write-model-v2.md)

/// Pins the v2 DECISION `MessagesWriteGuard.resolve` makes. Nothing else can catch a silent revert:
/// the bats tier cannot assert "a flagless send actually sends" without messaging a real person,
/// and the AppleKit core tier only proves the precedence chain, not that THIS domain opted in.
///
/// Messages is the highest-stakes flip in the rollout — after it, a flagless `apple messages send`
/// reaches a real human — so the default is pinned explicitly rather than left implied.
@Suite("Messages write-model v2 posture")
struct MessagesWriteModelV2Tests {
    func opts(_ args: [String]) throws -> GlobalOptions { try GlobalOptions.parse(args) }

    @Test("the test environment is clean (precondition for every pin below)")
    func cleanEnvironment() {
        let env = ProcessInfo.processInfo.environment
        #expect(env["APPLE_TEST_MODE"] == nil || env["APPLE_TEST_MODE"]!.isEmpty)
        #expect(env["APPLE_DRY_RUN"] == nil || env["APPLE_DRY_RUN"]!.isEmpty)
    }

    @Test("DEFAULT PIN: a flagless send EXECUTES and is unsandboxed")
    func defaultsToExecute() throws {
        let gate = try MessagesWriteGuard.resolve(opts([]))
        #expect(gate.willExecute == true)
        #expect(gate.sandboxActive == false)
    }

    @Test("--dry-run previews; --execute is redundant; --dry-run wins over --execute")
    func dryRunPrecedence() throws {
        #expect(try MessagesWriteGuard.resolve(opts(["--dry-run"])).willExecute == false)
        #expect(try MessagesWriteGuard.resolve(opts(["--execute"])).willExecute == true)
        #expect(try MessagesWriteGuard.resolve(opts(["--dry-run", "--execute"])).willExecute == false)
    }

    @Test("--test-mode alone engages the sandbox without forcing a preview")
    func flagEngagesSandbox() throws {
        let gate = try MessagesWriteGuard.resolve(opts(["--test-mode"]))
        #expect(gate.sandboxActive == true)
        #expect(gate.willExecute == true)
    }
}

// MARK: - Phone format variants

@Suite("phoneFormats")
struct PhoneFormatTests {
    @Test func tenDigitAddsCountryCode() {
        let f = ChatDB.phoneFormats("2125550100")
        #expect(f.contains("2125550100"))
        #expect(f.contains("12125550100"))
        #expect(f.contains("+12125550100"))
    }

    @Test func elevenDigitAddsStripped() {
        let f = ChatDB.phoneFormats("12125550100")
        #expect(f.contains("12125550100"))
        #expect(f.contains("2125550100"))
        #expect(f.contains("+12125550100"))
    }
}

// MARK: - Envelope shape

@Suite("Output envelope")
struct EnvelopeTests {
    @Test func messageEncodesSnakeCaseFields() throws {
        let msg = ChatDB.Message(rowid: 1, date: Date(timeIntervalSince1970: 1_700_000_000),
            date_local: "2023-11-14 15:13:20", timestamp: 12345, is_from_me: true, sender: "You",
            handle: "+12125550100", service: "iMessage", body: "hi", group_name: nil, has_attachments: false)
        let data = try Output.encodeSuccess(tool: "messages", data: [msg])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"schema_version\""))
        #expect(json.contains("\"tool\" : \"messages\""))
        #expect(json.contains("\"ok\" : true"))
        #expect(json.contains("\"is_from_me\""))
        #expect(json.contains("\"date_local\""))
        #expect(json.contains("\"has_attachments\""))
    }
}
