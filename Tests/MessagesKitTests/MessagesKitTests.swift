import Testing
import Foundation
@testable import MessagesKit
import AppleKit
import TestSupport

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

    /// The result grammar is `success:<service>:<filesSent>` /
    /// `error:<filesSent>:<failedFile>:<bodyDelivered>:<text>`. The leading fields are integers,
    /// so an error message carrying colons of its own still parses whole.
    @Test func interpretResults() {
        #expect(Send.interpret("success:iMessage:0")
            == Send.Outcome(ok: true, service: "iMessage", filesSent: 0, failedFile: nil,
                            bodyDelivered: true, error: nil))
        #expect(Send.interpret("success:SMS:2").service == "SMS")
        #expect(Send.interpret("success:SMS:2").filesSent == 2)
        // A group chat reports no service — Messages does not name the chat's own.
        #expect(Send.interpret("success::1").service == nil)
        #expect(Send.interpret("error:0:0:0:boom").ok == false)
        #expect(Send.interpret("error:0:0:0:boom").error == "boom")
        #expect(Send.interpret("error:1:2:1:boom: -1728").error == "boom: -1728")
        #expect(Send.interpret("error:1:2:1:boom").filesSent == 1)
        #expect(Send.interpret("error:1:2:1:boom").failedFile == 2)
        // `failedFile` 0 means "not during a file send", surfaced as nil rather than index 0.
        #expect(Send.interpret("error:0:0:0:boom").failedFile == nil)
    }

    /// THE FACT `filesSent` CANNOT CARRY. The body is not an attachment, so a run that delivered
    /// the body and then failed on attachment 1 reports `filesSent: 0` — and before the body bit
    /// existed, that read as "nothing was delivered". A caller following the retry advice re-sent
    /// the body to a real person.
    @Test func interpretCarriesWhetherTheBodyWasDelivered() {
        #expect(Send.interpret("error:0:1:1:transfer refused").bodyDelivered == true)
        #expect(Send.interpret("error:0:1:1:transfer refused").filesSent == 0)
        #expect(Send.interpret("error:0:1:0:transfer refused").bodyDelivered == false)
        // Reachable without any attachment in flight: body out, then the SMS lookup failed.
        #expect(Send.interpret("error:0:0:1:no SMS account").bodyDelivered == true)
        #expect(Send.interpret("error:0:0:1:no SMS account").failedFile == nil)
    }

    /// FAIL-CLOSED PIN. Anything outside the grammar — including whatever osascript itself prints
    /// when it never reaches a `return` — must read as a FAILURE. On a surface that reaches a real
    /// human, a parser that shrugged and called an unrecognized line a success would report a
    /// delivery that never happened. The superseded four-field error shape is in the list on
    /// purpose: a half-upgraded build must not parse as a success or as a silent zero.
    @Test func interpretRejectsAnythingOutsideTheGrammar() {
        for line in ["success", "success:iMessage", "success:iMessage:x", "error:boom",
                     "error:0:boom", "error:0:0:boom", "error:0:0:x:boom", "", "0:0:0",
                     "succeeded:iMessage:0"] {
            let outcome = Send.interpret(line)
            #expect(outcome.ok == false, "\(line) must not read as a success")
            #expect(outcome.error?.hasPrefix("Unknown result:") == true)
        }
    }

    @Test func scriptsAreArgvDriven() {
        // Security: recipient/body/attachment paths arrive via `on run argv`, never interpolated.
        for service in Send.Service.allCases {
            for includeMessage in [true, false] {
                let script = Send.directScript(service: service, includeMessage: includeMessage)
                #expect(script.contains("on run argv"))
                #expect(script.contains("set targetRecipient to item 1 of argv"))
                #expect(script.contains("set end of fileList to POSIX file (item fileIndex of argv)"))
            }
        }
        #expect(Send.groupScript(includeMessage: true).contains("chat id chatId"))
        #expect(Send.groupScript(includeMessage: false).contains("on run argv"))
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
    ///
    /// Every call passes `allowedRecipients:` EXPLICITLY, so nothing asserted here reads
    /// `APPLE_TEST_RECIPIENTS` — or any other process-global — at all. The parameter used to
    /// default to `nil` and read the variable, which made these assertions depend on the ambient
    /// process environment being empty. An injected seam beats a pinned window wherever one
    /// exists: `MessagesWriteModelV2Tests.pinned` is the fallback for the gates that have no seam,
    /// and this suite needs none precisely because the argument is explicit.
    @Test func allowlistIsSandboxOnlyAndFailsClosedInsideIt() {
        // Unsandboxed: a no-op. A throw here means the v1 gate was silently reinstated, which
        // would make the domain non-parity again.
        #expect(throws: Never.self) {
            try Send.assertAllowedRecipient("2125550142", groupChat: false, sandboxActive: false,
                                            allowedRecipients: [])
        }
        #expect(throws: Never.self) {
            try Send.assertAllowedRecipient("+1 (212) 555-0150", groupChat: false,
                                            sandboxActive: false, allowedRecipients: [])
        }
        // Unsandboxed group send is a no-op too — the group refusal is a SANDBOX restriction, not
        // a capability drop, so an unsandboxed `--group` must still reach the oracle's behavior.
        #expect(throws: Never.self) {
            try Send.assertAllowedRecipient("iMessage;-;chat123456789", groupChat: true,
                                            sandboxActive: false, allowedRecipients: [])
        }
        // Sandboxed with an EMPTY allowlist: every recipient is refused, not every recipient
        // allowed. This is THE fail-closed property — an allowlist that defaults to "permit all"
        // on a send surface would be the worst possible default.
        #expect(throws: (any Error).self) {
            try Send.assertAllowedRecipient("2125550142", groupChat: false, sandboxActive: true,
                                            allowedRecipients: [])
        }
        // A group-chat id does not match a phone/email allowlist entry…
        #expect(throws: (any Error).self) {
            try Send.assertAllowedRecipient("iMessage;-;chat123456789", groupChat: false,
                                            sandboxActive: true, allowedRecipients: [])
        }
        // …but that was never sufficient on its own. With the chat id ITSELF allowlisted, the
        // normalize-then-compare path returns a match (`phonesEquivalent` short-circuits on
        // equal strings), so sandboxed group send is refused STRUCTURALLY instead.
        #expect(throws: (any Error).self) {
            try Send.assertAllowedRecipient("iMessage;-;chat123456789", groupChat: true,
                                            sandboxActive: true,
                                            allowedRecipients: ["iMessage;-;chat123456789"])
        }
        // The allowlisted non-group recipient still passes — the refusals above are about the
        // group flag and an empty list, not a broken comparison.
        #expect(throws: Never.self) {
            try Send.assertAllowedRecipient("2125550142", groupChat: false, sandboxActive: true,
                                            allowedRecipients: ["+1 (212) 555-0142"])
        }
    }
}

// MARK: - Service selection + attachments (CLI extras over the MCP surface)

/// The two send extras port-spec §5 listed as WORTH-INCLUDING: explicit service control and file
/// attachments. Every assertion here is on the PURE builders — the emitted AppleScript source and
/// the path resolver — because nothing else can see them: the script bodies are Swift string
/// literals that `swift build` never parses as AppleScript, and the only tier that would execute
/// them sends to a real human.
@Suite("Send service + attachments")
struct SendServiceAndAttachmentTests {
    @Test func serviceNamesRoundTrip() {
        #expect(Send.Service(rawValue: "auto") == .auto)
        #expect(Send.Service(rawValue: "imessage") == .imessage)
        #expect(Send.Service(rawValue: "sms") == .sms)
        // The validation message, the help text and the manual all derive from this one list, so
        // a fourth service can only be a new case.
        #expect(Send.Service.allNames == "auto, imessage, sms")
        // Anything else is rejected here rather than reaching Messages as a routing surprise.
        for bad in ["iMessage", "SMS", "rcs", "", "auto ", "imessage,sms"] {
            #expect(Send.Service(rawValue: bad) == nil, "\(bad) must not parse as a service")
        }
    }

    /// `service_plan` is what a dry run PROMISES the execute path will do, so each mode must have
    /// its own wording — a shared string would let a preview say "iMessage→SMS auto" for a send
    /// that will never try SMS.
    @Test func servicePlansAreDistinct() {
        #expect(Send.Service.auto.plan == "iMessage→SMS auto")
        #expect(Send.Service.imessage.plan == "iMessage only")
        #expect(Send.Service.sms.plan == "SMS only")
        #expect(Set(Send.Service.allCases.map(\.plan)).count == Send.Service.allCases.count)
    }

    /// `auto` keeps the ported `_send_message_direct` routing verbatim: iMessage first, then the
    /// SMS account, and only for a recipient that contains a digit.
    @Test func autoScriptKeepsTheiMessageThenSMSFallback() {
        let script = Send.directScript(service: .auto, includeMessage: true)
        #expect(script.contains("set targetService to 1st service whose service type = iMessage"))
        #expect(script.contains("set smsService to first account whose service type = SMS and enabled is true"))
        #expect(script.contains("targetRecipient contains \"0\""))
        #expect(script.contains("targetRecipient contains \"9\""))
        #expect(script.contains("SMS not available for email addresses"))
        #expect(script.contains("return \"success:iMessage:\" & filesSent"))
        #expect(script.contains("return \"success:SMS:\" & filesSent"))
    }

    /// EXPLICIT MEANS EXPLICIT. `--service imessage` must not silently reach SMS and
    /// `--service sms` must not silently reach iMessage — a fallback the caller ruled out is the
    /// one thing these modes exist to prevent, and it would be invisible from the outside.
    @Test func singleServiceScriptsHaveNoFallback() {
        let iMessageOnly = Send.directScript(service: .imessage, includeMessage: true)
        #expect(iMessageOnly.contains("set targetService to 1st service whose service type = iMessage"))
        #expect(!iMessageOnly.contains("service type = SMS"))
        #expect(!iMessageOnly.contains("success:SMS"))

        let smsOnly = Send.directScript(service: .sms, includeMessage: true)
        #expect(smsOnly.contains("set smsService to first account whose service type = SMS and enabled is true"))
        #expect(!smsOnly.contains("service type = iMessage"))
        #expect(!smsOnly.contains("success:iMessage"))
    }

    /// The `auto` fallback may only re-run a batch of which NOTHING was delivered. Without that
    /// guard, an iMessage run that placed the body and one attachment before failing would be
    /// replayed whole over SMS and the recipient would get both twice. The condition is DERIVED
    /// from the two counters the result grammar already carries, rather than kept as a third latch
    /// that could disagree with them.
    @Test func autoScriptRefusesToFallBackAfterAnythingWasDelivered() {
        let script = Send.directScript(service: .auto, includeMessage: true)
        #expect(script.contains("set bodyDelivered to 0"))
        #expect(script.contains("if not (bodyDelivered is 0 and filesSent is 0) then"))
        #expect(script.contains("iMessage send failed after part of it was already delivered"))
    }

    /// A file-only send carries NO body argument, so the script must neither read argv item 2 as
    /// a body nor emit a `send messageText` — and the attachment loop has to start one item
    /// earlier. Getting this wrong sends the first attachment path as a text message.
    @Test func bodylessScriptsReadNoMessageAndStartFilesEarlier() {
        for service in Send.Service.allCases {
            let withBody = Send.directScript(service: service, includeMessage: true)
            let bodyless = Send.directScript(service: service, includeMessage: false)
            #expect(withBody.contains("set messageText to item 2 of argv"))
            #expect(withBody.contains("repeat with fileIndex from 3 to (count of argv)"))
            #expect(!bodyless.contains("messageText"))
            #expect(bodyless.contains("repeat with fileIndex from 2 to (count of argv)"))
        }
        #expect(!Send.groupScript(includeMessage: false).contains("messageText"))
        #expect(Send.groupScript(includeMessage: true).contains("send messageText to targetChat"))
    }

    /// Order is part of the contract: the body goes out first, then each attachment in the order
    /// the operator listed them.
    @Test func everyScriptSendsTheBodyBeforeTheAttachments() {
        var scripts = Send.Service.allCases.map { Send.directScript(service: $0, includeMessage: true) }
        scripts.append(Send.groupScript(includeMessage: true))
        for script in scripts {
            guard let body = script.range(of: "send messageText to"),
                  let files = script.range(of: "repeat with fileIndex from 1 to (count of fileList)")
            else {
                Issue.record("script is missing the body or the attachment loop")
                continue
            }
            #expect(body.lowerBound < files.lowerBound)
        }
    }

    /// `POSIX file` is coerced OUTSIDE the `tell application "Messages"` block. Inside a tell it
    /// can resolve against the target application's terminology instead of AppleScript's own.
    @Test func attachmentPathsAreCoercedOutsideTheTellBlock() {
        for script in [Send.directScript(service: .auto, includeMessage: true),
                       Send.groupScript(includeMessage: true)] {
            guard let coercion = script.range(of: "POSIX file (item fileIndex of argv)"),
                  let tell = script.range(of: "tell application \"Messages\"")
            else {
                Issue.record("script is missing the POSIX coercion or the tell block")
                continue
            }
            #expect(coercion.lowerBound < tell.lowerBound)
        }
    }

    /// The `auto` fallback runs after the iMessage half died, possibly mid-batch, and the SMS
    /// ACCOUNT LOOKUP can fail on its own (no enabled SMS account). Its error handler reports
    /// `currentFile`, so unless the counter is cleared first it still names the attachment the
    /// iMessage half was on — telling the caller "send failed on attachment 1" for a run that
    /// transferred nothing at all. Asserted as "the reset lies between the fallback's entry and
    /// the account lookup", which is the invariant, not the line number.
    @Test func autoFallbackClearsTheInFlightAttachmentBeforeResolvingSMS() {
        for includeMessage in [true, false] {
            let script = Send.directScript(service: .auto, includeMessage: includeMessage)
            guard let fallback = script.range(of: "on error iMessageErr"),
                  let lookup = script.range(of: "set smsService to first account")
            else {
                Issue.record("auto script is missing the fallback or the SMS account lookup")
                continue
            }
            #expect(script[fallback.upperBound..<lookup.lowerBound].contains("set currentFile to 0"))
        }
        // …and the line that reset reaches: nothing transferred reads as no failed attachment,
        // never as attachment 0 or attachment 1.
        let outcome = Send.interpret("error:0:0:0:Both iMessage and SMS failed - iMessage: x SMS: y")
        #expect(outcome.ok == false)
        #expect(outcome.filesSent == 0)
        #expect(outcome.failedFile == nil)
        #expect(outcome.bodyDelivered == false)
        #expect(outcome.error == "Both iMessage and SMS failed - iMessage: x SMS: y")
    }

    /// ROUTING PIN (option (a)). The ported `_send_message_direct` nested two `try`s: the iMessage
    /// SERVICE lookup in the outer one, whose handler returns an error and attempts no SMS, and
    /// only the participant lookup + delivery in the inner one that falls back. Flattening them
    /// makes a Mac signed out of iMessage send a real SMS where the oracle sent nothing — a silent
    /// routing change under a flag whose whole point is to leave the default alone. Substring
    /// presence cannot see nesting, so this asserts the ORDERING that encodes it.
    @Test func autoKeepsTheServiceLookupOutsideTheFallbackBearingTry() {
        for includeMessage in [true, false] {
            let script = Send.directScript(service: .auto, includeMessage: includeMessage)
            guard let service = script.range(of: "set targetService to"),
                  let buddy = script.range(of: "set targetBuddy to"),
                  let fallback = script.range(of: "on error iMessageErr"),
                  let general = script.range(of: "on error generalErr")
            else {
                Issue.record("auto script is missing the two-tier service/participant structure")
                continue
            }
            // The service lookup precedes the participant lookup…
            #expect(service.upperBound < buddy.lowerBound)
            // …with EXACTLY ONE `try` opening between them: the inner, fallback-bearing one. Two
            // would mean the lookup had been pushed inside it.
            let between = script[service.upperBound..<buddy.lowerBound]
            #expect(between.components(separatedBy: "try").count - 1 == 1)
            // And the outer handler — the one that reaches no SMS — closes after the inner one.
            #expect(fallback.lowerBound < general.lowerBound)
        }
        // The single-service arms need no outer tier: there is no fallback to keep out of.
        for service in [Send.Service.imessage, .sms] {
            #expect(!Send.directScript(service: service, includeMessage: true)
                .contains("on error generalErr"))
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
///
/// Each pin below resolves the gate from the REAL process environment, where an operator's
/// `APPLE_TEST_MODE` / `APPLE_DRY_RUN` export — or a concurrent suite's own window — would flip the
/// verdict. Every one therefore runs inside `pinned`, which forces those variables absent for its
/// duration, so each verdict is a property of the FLAGS alone. `.serialized` keeps the suite from
/// queueing on itself while `TestEnvironment`'s process-wide lock orders it against other suites.
@Suite("Messages write-model v2 posture", .serialized)
struct MessagesWriteModelV2Tests {
    func opts(_ args: [String]) throws -> GlobalOptions { try GlobalOptions.parse(args) }

    /// The window every pin below rests on: `TestEnvironment.writeModeVariables` — the three
    /// sandbox-engaging variables plus `APPLE_DRY_RUN` — forced absent for its duration. Routing
    /// through `TestEnvironment` rather than a local save/restore is what serializes the window
    /// against every other suite mutating the same process-global table.
    @discardableResult
    func pinned<T>(_ body: () throws -> T) rethrows -> T {
        try TestEnvironment.withoutWriteModeOverrides(body)
    }

    // The operator-shell detector — "did the shell running the tests export a write-posture
    // variable?" — asserts a property of the PROCESS, not of Messages, so it lives once in
    // `AppleKitTests/AmbientEnvironmentCanaryTests.swift`. The pins above are what make this suite
    // independent of that answer.

    @Test("DEFAULT PIN: a flagless send EXECUTES and is unsandboxed")
    func defaultsToExecute() throws {
        try pinned {
            let gate = try MessagesWriteGuard.resolve(opts([]))
            #expect(gate.willExecute == true)
            #expect(gate.sandboxActive == false)
        }
    }

    @Test("--dry-run previews; --execute is redundant; --dry-run wins over --execute")
    func dryRunPrecedence() throws {
        // Resolved OUTSIDE the `#expect`s: the macro wraps its argument in a call the closure's
        // throwing-ness cannot be inferred through, so `try` has to sit in a plain statement.
        let (preview, execute, both) = try pinned {
            (try MessagesWriteGuard.resolve(opts(["--dry-run"])),
             try MessagesWriteGuard.resolve(opts(["--execute"])),
             try MessagesWriteGuard.resolve(opts(["--dry-run", "--execute"])))
        }
        #expect(preview.willExecute == false)
        #expect(execute.willExecute == true)
        #expect(both.willExecute == false)
    }

    @Test("--test-mode alone engages the sandbox without forcing a preview")
    func flagEngagesSandbox() throws {
        try pinned {
            let gate = try MessagesWriteGuard.resolve(opts(["--test-mode"]))
            #expect(gate.sandboxActive == true)
            #expect(gate.willExecute == true)
        }
    }

    /// The Gate's `allowedRecipients` is what the send guard compares against, and the hermetic
    /// test gate bypasses `resolve` entirely — so without this, a `resolve` that captured the
    /// wrong source (a hardcoded `[]`, the sandbox PREFIX, the wrong variable) would pass the
    /// whole suite. Blast radius is fail-closed, but a silently-empty allowlist would make every
    /// sandboxed send refuse for a reason the operator cannot see.
    @Test("resolve threads the injected allowlist reader into the Gate verbatim")
    func capturesInjectedAllowlist() throws {
        // Pinned like every other resolution here: `allowedRecipients` is injected, but `resolve`
        // still reads `APPLE_DRY_RUN` on the way, and `TestMode`'s reader is fail-LOUD — a
        // non-truthy value (`APPLE_DRY_RUN=junk`) makes it throw before the allowlist is captured.
        let (injected, gate, emptied) = try pinned { () -> ([String], MessagesWriteGuard.Gate, [String]) in
            let injected = ["+1 (212) 555-0100", "alice@example.com"]
            return (injected,
                    try MessagesWriteGuard.resolve(opts([]), allowedRecipients: { injected }),
                    try MessagesWriteGuard.resolve(opts(["--test-mode"]),
                                                   allowedRecipients: { [] }).allowedRecipients)
        }
        #expect(gate.allowedRecipients == injected)
        // Entries are captured verbatim; normalization happens in the guard, not the gate.
        #expect(emptied == [])
    }

    /// Pins the PRODUCTION binding: `.live.resolveGate` — the only `resolveGate` an `apple
    /// messages send` invocation can ever reach — must BE `MessagesWriteGuard.resolve` with its
    /// default allowlist reader, not a hermetic stand-in, a hardcoded posture, or a different
    /// guard. Compares two live resolutions rather than asserting values: both sides read the same
    /// process state at the same moment, so the equality is a statement about the BINDING and not
    /// about any particular posture. Sweeping the flag combinations is what makes it non-vacuous —
    /// a constant-returning or flag-ignoring binding disagrees on at least one row even in a
    /// totally empty environment.
    ///
    /// It runs inside `pinned` all the same. Equality is robust to the environment, but REACHING it
    /// is not: `resolve` reads `APPLE_DRY_RUN` through `TestMode`'s fail-loud reader, so an
    /// operator's `APPLE_DRY_RUN=junk` (or another suite's window closing mid-sweep) makes the call
    /// THROW and the comparison never happens. Observed as an intermittent failure of exactly this
    /// test under an exported `APPLE_DRY_RUN=junk`.
    /// The `APPLE_TEST_RECIPIENTS` sweep is what keeps the "with its DEFAULT allowlist reader"
    /// half of that claim verifiable. Pinned absent, every row's allowlist is empty on both sides
    /// and a stand-in that read some other variable — or none — would agree throughout; the
    /// non-nil row is where such a stand-in diverges, because only a reader of THIS variable
    /// reproduces these entries. Nested inside `pinned` so the pin remains the baseline and the
    /// inner window restores to "absent", not to whatever the operator exported.
    @Test("`.live` resolves the write posture through MessagesWriteGuard.resolve")
    func liveDependenciesResolveThroughTheProductionGuard() throws {
        try pinned {
            for recipients: String? in [nil, "+1 555-0100,alice@example.com"] {
                try TestEnvironment.with(["APPLE_TEST_RECIPIENTS": recipients]) {
                    for argv in [[], ["--dry-run"], ["--execute"], ["--test-mode"],
                                 ["--test-mode", "--dry-run"], ["--test-mode", "--execute"]] {
                        let global = try opts(argv)
                        #expect(try MessagesCommandDependencies.live.resolveGate(global)
                                == MessagesWriteGuard.resolve(global),
                                """
                                live resolveGate diverged from MessagesWriteGuard.resolve for \
                                \(argv) with APPLE_TEST_RECIPIENTS=\(recipients ?? "<unset>")
                                """)
                    }
                }
            }
        }
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
            handle: "+12125550100", service: "iMessage", body: "hi", group_name: nil,
            has_attachments: true,
            attachments: [ChatDB.Attachment(rowid: 9, guid: "a9", filename: "~/x/photo.png",
                path: "/tmp/apple-cli-photo.png", exists: false, mime_type: "image/png",
                uti: "public.png", transfer_name: "photo.png", total_bytes: 3,
                is_sticker: false, hide_attachment: false)])
        let data = try Output.encodeSuccess(tool: "messages", data: [msg])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"schema_version\""))
        #expect(json.contains("\"tool\" : \"messages\""))
        #expect(json.contains("\"ok\" : true"))
        #expect(json.contains("\"is_from_me\""))
        #expect(json.contains("\"date_local\""))
        #expect(json.contains("\"has_attachments\""))
        // Attachment metadata rides the same envelope with verbatim snake_case wire keys.
        #expect(json.contains("\"attachments\""))
        #expect(json.contains("\"transfer_name\""))
        #expect(json.contains("\"mime_type\""))
        #expect(json.contains("\"total_bytes\""))
    }

    @Test func scoredMessageEncodesAttachmentShape() throws {
        let msg = ChatDB.ScoredMessage(rowid: 2, date: Date(timeIntervalSince1970: 1_700_000_001),
            date_local: "2023-11-14 15:13:21", timestamp: 12346, is_from_me: false,
            sender: "Alice", handle: "+12125550101", service: "SMS", body: "see file",
            group_name: nil, has_attachments: true,
            attachments: [ChatDB.Attachment(rowid: 10, guid: "a10",
                filename: "~/Library/Messages/Attachments/zz/photo.png",
                path: "/tmp/apple-cli-home/Library/Messages/Attachments/zz/photo.png",
                exists: nil, mime_type: "image/png", uti: "public.png",
                transfer_name: "photo.png", total_bytes: 12, is_sticker: true,
                hide_attachment: false)],
            score: 1.0)
        let data = try Output.encodeSuccess(tool: "messages", data: [msg])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"score\""))
        #expect(json.contains("\"attachments\""))
        #expect(json.contains("\"has_attachments\""))
        #expect(json.contains("\"is_sticker\""))
        #expect(json.contains("\"hide_attachment\""))
        #expect(json.contains("\"exists\" : null"))
    }

    @Test func attachmentJSONIncludesNullKeysForMissingMetadata() throws {
        let msg = ChatDB.Message(rowid: 3, date: Date(timeIntervalSince1970: 1_700_000_002),
            date_local: "2023-11-14 15:13:22", timestamp: 12347, is_from_me: false,
            sender: "Alice", handle: nil, service: nil, body: "file", group_name: nil,
            has_attachments: true,
            attachments: [ChatDB.Attachment(rowid: 11, guid: nil, filename: nil, path: nil,
                exists: nil, mime_type: nil, uti: nil, transfer_name: nil, total_bytes: nil,
                is_sticker: nil, hide_attachment: nil)])
        let data = try Output.encodeSuccess(tool: "messages", data: [msg])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(object["data"] as? [[String: Any]])
        let first = try #require(rows.first)
        let attachments = try #require(first["attachments"] as? [[String: Any]])
        let attachment = try #require(attachments.first)
        for key in ["guid", "filename", "path", "exists", "mime_type", "uti", "transfer_name",
                    "total_bytes", "is_sticker", "hide_attachment"] {
            #expect(attachment.keys.contains(key))
            #expect(attachment[key] is NSNull)
        }
    }
}

/// `--text` is not the versioned contract, but an attachment-only message has an EMPTY body,
/// and without an annotation it renders as a bare "Sender: ". That is the same shape as the
/// `[] ` group-name defect this file already carries a fix for, so pin it here too.
@Suite("Text rendering of attachments")
struct AttachmentSuffixTests {
    private func att(_ name: String?, filename: String? = "~/x/f.bin") -> ChatDB.Attachment {
        ChatDB.Attachment(rowid: 1, guid: nil, filename: filename, path: "/x/f.bin",
                          exists: false, mime_type: nil, uti: nil, transfer_name: name,
                          total_bytes: nil, is_sticker: nil, hide_attachment: nil)
    }

    @Test func emptyBodyGetsNoLeadingSpaceButIsNeverBlank() {
        #expect(attachmentSuffix([att("photo.png")], hasAttachments: true, body: "")
                == "[1 attachment: photo.png]")
    }

    @Test func nonEmptyBodyIsSeparatedBySpaceAndPluralised() {
        #expect(attachmentSuffix([att("a.png"), att("b.mov")], hasAttachments: true, body: "look")
                == " [2 attachments: a.png, b.mov]")
    }

    @Test func fallsBackToFilenameWhenTransferNameIsMissing() {
        #expect(attachmentSuffix([att(nil)], hasAttachments: true, body: "")
                == "[1 attachment: f.bin]")
    }

    @Test func fallsBackToFilenameWhenTransferNameIsEmpty() {
        #expect(attachmentSuffix([att("")], hasAttachments: true, body: "")
                == "[1 attachment: f.bin]")
    }

    @Test func filenameFallbackUsesBasenameOnly() {
        #expect(attachmentSuffix([att(nil, filename: "/tmp/private/path/file.pdf")],
                                 hasAttachments: true, body: "")
                == "[1 attachment: file.pdf]")
    }

    @Test func collapsesControlCharactersInAttachmentNames() {
        #expect(attachmentSuffix([att("scan\ncopy\tone.png")], hasAttachments: true, body: "")
                == "[1 attachment: scan copy one.png]")
    }

    @Test func collapsesBidiFormatControlsInAttachmentNames() {
        #expect(attachmentSuffix([att("safe\u{202E}gnp.exe")], hasAttachments: true, body: "")
                == "[1 attachment: safe gnp.exe]")
    }

    @Test func collapsesZeroWidthFormatControlsInAttachmentNames() {
        #expect(attachmentSuffix([att("photo\u{200D}.png")], hasAttachments: true, body: "")
                == "[1 attachment: photo .png]")
    }

    @Test func missingNamesFallBackToGenericAttachmentLabel() {
        #expect(attachmentSuffix([att(nil, filename: nil)], hasAttachments: true, body: "")
                == "[1 attachment: attachment]")
    }

    /// `cache_has_attachments` set but the join returned nothing: still say something.
    @Test func flagWithoutJoinedRowsStillAnnotates() {
        #expect(attachmentSuffix([], hasAttachments: true, body: "") == "[attachment]")
    }

    @Test func noAttachmentAddsNothing() {
        #expect(attachmentSuffix([], hasAttachments: false, body: "hi") == "")
    }
}
