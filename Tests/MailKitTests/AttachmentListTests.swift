import Testing
import Foundation
import AppleKit
@testable import MailKit

/// Q11-A pins: oracle-A attachment metadata rows (gap1), the oracle-B grouped subject shape
/// (gap6), and the thread truncation signal (gap5). Everything here is pure — no Mail, no TCC —
/// because the bats equivalents run against the live store and skip on CI.
@Suite("Attachment list parity (Q11-A)")
struct AttachmentListTests {

    private struct ProbeTimeout: Error {}

    private static let RS = String(UnicodeScalar(30)!)
    private static let US = String(UnicodeScalar(31)!)

    @Test func liveLookupBoundsBothMessageIDSpellings() throws {
        var calls: [(arguments: [String], timeout: TimeInterval)] = []
        let rows = try MailScript.listAttachments(
            internetMessageID: "message-id@example.com",
            accountName: "Example Account",
            using: { _, arguments, timeout in
                calls.append((arguments, timeout))
                if calls.count == 1 { return "notfound" }
                return "ok" + Self.RS
                    + ["report.pdf", "application/pdf", "7", "1"].joined(separator: Self.US)
                    + Self.RS
            })

        #expect(calls.count == 2)
        #expect(calls.map(\.arguments) == [
            ["<message-id@example.com>", "Example Account"],
            ["message-id@example.com", "Example Account"],
        ])
        #expect(calls.map(\.timeout) == [30, 30])
        #expect(rows?.map(\.name) == ["report.pdf"])
    }

    @Test func liveLookupPropagatesTimeoutForCallerFallback() {
        var calls = 0
        #expect(throws: ProbeTimeout.self) {
            _ = try MailScript.listAttachments(
                internetMessageID: "message-id@example.com",
                accountName: nil,
                using: { _, _, _ in
                    calls += 1
                    throw ProbeTimeout()
                })
        }
        #expect(calls == 1)
    }

    @Test func callerMapsTimeoutToDisclosedIndexFallback() throws {
        let live = AttachmentsList.liveAttachmentMetadataOrNil {
            throw AppleScriptRunner.TimeoutError(seconds: 30)
        }
        let shaped = AttachmentsList.shapeAttachmentRows(
            indexRows: [(name: "report.pdf", attachmentID: "2.7")],
            liveMetas: live,
            rowid: 42)

        #expect(shaped.degraded)
        #expect(shaped.rows.count == 1)
        #expect(shaped.rows[0].name == "report.pdf")
        #expect(shaped.rows[0].attachment_id == "2.7")
        #expect(shaped.rows[0].mime_type == nil)
        #expect(shaped.rows[0].size == nil)
        #expect(shaped.rows[0].downloaded == nil)
        let note = try #require(AttachmentsList.degradedNote(degraded: shaped.degraded, noLive: false))
        #expect(note.contains("live Mail.app enrichment unavailable"))
        #expect(note.contains("Envelope-Index only"))
    }

    // MARK: parseAttachmentList — the fail-closed AppleScript-output boundary

    /// Output not carrying the "ok" sentinel is NOT-LOCATED (→ index fallback), never an empty
    /// success — same rule parseNativeCompose pins for the compose surface. An AppleScript
    /// error string, a permission dialog remnant, or garbage must all map to nil.
    @Test func nonOkOutputIsFallbackNeverEmptySuccess() {
        #expect(MailScript.parseAttachmentList("") == nil)
        #expect(MailScript.parseAttachmentList("garbage") == nil)
        #expect(MailScript.parseAttachmentList("notfound") == nil)
        #expect(MailScript.parseAttachmentList("error: -1728") == nil)
        // "ok" with no rows IS a located message with zero attachments.
        #expect(MailScript.parseAttachmentList("ok" + Self.RS)?.isEmpty == true)
    }

    /// The four oracle-A fields round-trip, and an empty field degrades that FIELD (nil), not
    /// the row — the whole point of the per-property try in the script (measured live: this
    /// store's Mail.app throws "AppleEvent handler failed" on `MIME type of att`, which loses
    /// oracle A the entire message; our row survives with mime_type nil).
    @Test func rowsParseFieldwise() throws {
        let out = "ok" + Self.RS
            + ["report.pdf", "application/pdf", "524288", "0"].joined(separator: Self.US) + Self.RS
            + ["broken.pdf", "", "", ""].joined(separator: Self.US) + Self.RS
            + ["fetched.jpg", "image/jpeg", "319104", "1"].joined(separator: Self.US) + Self.RS
        let rows = try #require(MailScript.parseAttachmentList(out))
        #expect(rows.count == 3)
        #expect(rows[0].name == "report.pdf")
        #expect(rows[0].mimeType == "application/pdf")
        #expect(rows[0].size == 524288)
        #expect(rows[0].downloaded == false)
        #expect(rows[1].mimeType == nil)
        #expect(rows[1].size == nil)
        #expect(rows[1].downloaded == nil)
        #expect(rows[2].downloaded == true)
        // Live order is preserved — it is the positional space `attachments save` addresses.
        #expect(rows.map(\.name) == ["report.pdf", "broken.pdf", "fetched.jpg"])
    }

    /// A malformed row (wrong field count, or a nameless attachment) is skipped, not fatal.
    @Test func malformedRowsAreSkippedNotFatal() throws {
        let out = "ok" + Self.RS
            + "onlyonefield" + Self.RS
            + ["", "application/pdf", "9", "1"].joined(separator: Self.US) + Self.RS
            + ["good.txt", "text/plain", "42", "1"].joined(separator: Self.US) + Self.RS
        let rows = try #require(MailScript.parseAttachmentList(out))
        #expect(rows.map(\.name) == ["good.txt"])
    }

    /// Defense-in-depth behind the script-side RS/US neutralization: a residual control
    /// character in a parsed name is scrubbed to "_", never passed through (it would rewrite
    /// terminal output on --text and could desync any downstream blob) — security-review pin.
    @Test func residualControlCharactersInNamesAreScrubbed() throws {
        let out = "ok" + Self.RS
            + ["bad\u{07}name.pdf", "application/pdf", "9", "1"].joined(separator: Self.US) + Self.RS
        let rows = try #require(MailScript.parseAttachmentList(out))
        #expect(rows.count == 1)
        #expect(rows[0].name == "bad_name.pdf")
    }

    /// AppleScript coerces integers past ±536870911 to reals and stringifies them in exponent
    /// form — the size must survive, not silently drop, for exactly the attachments where a
    /// caller most wants it before downloading (review-caught).
    @Test func exponentFormSizesParse() throws {
        let out = "ok" + Self.RS
            + ["big.mov", "video/quicktime", "6.0E+8", "0"].joined(separator: Self.US) + Self.RS
        let rows = try #require(MailScript.parseAttachmentList(out))
        #expect(rows[0].size == 600_000_000)
    }

    // MARK: AttachmentJoin — name-keyed, never positional

    /// The index (`ORDER BY name`) and Mail's live list were MEASURED disagreeing on 8/8
    /// multi-attachment messages (22/24 ids mis-paired on one real message by the positional
    /// zip this replaces). The join is by name; a duplicated or unknown name is (nil, nil).
    @Test func joinIsByNameNeverPosition() {
        // Index order (alphabetical) deliberately differs from the live order used to query.
        let index: [(name: String, attachmentID: String?)] =
            [("a.jpg", "2.9"), ("b.jpg", "2.1"), ("z.jpg", "2.5")]
        // Live-order name "z.jpg" is index position 2, id 2.5 — a positional join at live
        // position 0 would have said 2.9.
        let z = AttachmentJoin.byName("z.jpg", in: index)
        #expect(z.attachmentID == "2.5")
        #expect(z.saveIndex == 2)
        let a = AttachmentJoin.byName("a.jpg", in: index)
        #expect(a.attachmentID == "2.9")
        #expect(a.saveIndex == 0)
        // Unknown name: unknown beats silently wrong.
        let missing = AttachmentJoin.byName("nope.jpg", in: index)
        #expect(missing.attachmentID == nil)
        #expect(missing.saveIndex == nil)
    }

    @Test func duplicateNamesAreAmbiguousNotArbitrary() {
        let index: [(name: String, attachmentID: String?)] =
            [("dup.jpg", "2.1"), ("dup.jpg", "2.2"), ("only.jpg", "2.3")]
        let dup = AttachmentJoin.byName("dup.jpg", in: index)
        #expect(dup.attachmentID == nil)
        #expect(dup.saveIndex == nil)
        #expect(AttachmentJoin.byName("only.jpg", in: index).saveIndex == 2)
    }

    // MARK: wire shape — gap1 row keys + gap6 grouped subject shape

    private func encode<T: Encodable>(_ v: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(v), as: UTF8.self)
    }

    /// Oracle A's row is {name, mime_type, size, downloaded}; the CLI row must carry all four
    /// (plus its own attachment_id/message_id extras). Reverting the model to the old
    /// {name, attachment_id, size, message_id} makes this fail to compile — and a populated
    /// row must EMIT the three metadata keys.
    @Test func attachmentRowEmitsOracleAKeys() throws {
        let row = MailAttachment(name: "a.pdf", attachment_id: "2.10", mime_type: "application/pdf",
                                 size: 7, downloaded: true, message_id: "1")
        let json = try encode(row)
        #expect(json.contains("\"mime_type\":\"application\\/pdf\""))
        #expect(json.contains("\"size\":7"))
        #expect(json.contains("\"downloaded\":true"))
    }

    /// gap6: the --subject path is oracle B's grouped shape — per-email rows with
    /// subject/sender/date, a ZERO-attachment match included (the old forced
    /// hasAttachment=true made it structurally unreachable), and matched_email_count.
    @Test func subjectPathEmitsGroupedOracleBShape() throws {
        let zeroRow = MailAttachmentEmail(message_id: "2", subject: "re: taxes", sender: "s",
                                          date_received: "2026-01-01T00:00:00", attachment_count: 0,
                                          attachments: [])
        let result = MailAttachmentsResult(
            attachments: [], count: 0, matched_by: "subject_keyword",
            emails: [zeroRow], matched_email_count: 1)
        let json = try encode(result)
        #expect(json.contains("\"matched_email_count\":1"))
        #expect(json.contains("\"attachment_count\":0"))
        #expect(json.contains("\"emails\":["))
    }

    /// The id path keeps the flat pre-Q11 shape on the HAPPY path: emails/matched_email_count
    /// keys are DROPPED, not emitted as null (synthesized encodeIfPresent). The degraded id
    /// path DOES add `note` (that disclosure is the point) — this pins the enriched shape only.
    @Test func idPathKeepsFlatShape() throws {
        let result = MailAttachmentsResult(
            attachments: [], count: 0, matched_by: "message_id")
        let json = try encode(result)
        #expect(!json.contains("emails"))
        #expect(!json.contains("matched_email_count"))
        #expect(!json.contains("note"))
    }

    // MARK: gap5 — per-path thread limit defaults (the DEFAULT-change half, critic H2)

    /// nil on the id path is UNCAPPED (oracle A get_thread has no cap) — reverting to the old
    /// shared `= 50` default flips the first expectation without needing a >50-message live
    /// thread. nil on the subject path stays oracle B's 50; explicit 0 = complete on both.
    @Test func threadLimitDefaultsArePerPath() {
        #expect(ThreadLimits.effective(nil, idPath: true) == Int.max)
        #expect(ThreadLimits.effective(nil, idPath: false) == 50)
        #expect(ThreadLimits.effective(0, idPath: true) == Int.max)
        #expect(ThreadLimits.effective(0, idPath: false) == Int.max)
        #expect(ThreadLimits.effective(7, idPath: true) == 7)
        #expect(ThreadLimits.effective(7, idPath: false) == 7)
    }

    // MARK: gap5 — thread truncation signal

    /// total/has_more emit when set and are DROPPED (not null) when absent, so the pre-Q11
    /// thread envelope is unchanged for consumers that never see truncation.
    @Test func threadResultCarriesTruncationSignal() throws {
        let truncated = MailThreadResult(messages: [], count: 0, matched_by: "message_id",
                                         total: 10, has_more: true)
        let json = try encode(truncated)
        #expect(json.contains("\"total\":10"))
        #expect(json.contains("\"has_more\":true"))
        let bare = MailThreadResult(messages: [], count: 0, matched_by: "message_id")
        let bareJSON = try encode(bare)
        #expect(!bareJSON.contains("total"))
        #expect(!bareJSON.contains("has_more"))
    }
}
