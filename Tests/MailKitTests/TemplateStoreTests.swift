import Testing
import Foundation
@testable import MailKit
import AppleKit

@Suite("TemplateStore")
struct TemplateStoreTests {

    private func tempStore() -> TemplateStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-cli-tpl-\(UUID().uuidString)")
        return TemplateStore(homeOverride: dir.path)
    }

    private func rawFile(_ store: TemplateStore, _ name: String) throws -> String {
        try String(contentsOf: store.root.appendingPathComponent("\(name).md"), encoding: .utf8)
    }

    @Test func saveGetListDeleteRoundTrip() throws {
        let store = tempStore()
        #expect(try store.list().isEmpty)
        try store.save(name: "welcome", body: "Hi {recipient_name},\nThanks!", subject: "Hello {recipient_name}")
        let got = try store.get("welcome")
        #expect(got.subject == "Hello {recipient_name}")
        #expect(got.body == "Hi {recipient_name},\nThanks!\n")   // body normalized to end with \n
        let list = try store.list()
        #expect(list.count == 1)
        #expect(list.first?.name == "welcome")
        #expect(list.first?.subject == "Hello {recipient_name}")
        try store.delete("welcome")
        #expect(try store.list().isEmpty)
    }

    @Test func renderFillsPlaceholdersUserVarsWin() throws {
        let store = tempStore()
        try store.save(name: "greet", body: "Hi {recipient_name}, today is {today}.", subject: "Re: {original_subject}")
        let r = try store.render(
            name: "greet",
            autoVars: ["recipient_name": "Ada", "today": "2026-07-15", "original_subject": "Budget"],
            userVars: ["recipient_name": "Ada Lovelace"])   // override wins
        #expect(r.subject == "Re: Budget")
        #expect(r.body == "Hi Ada Lovelace, today is 2026-07-15.\n")
        #expect(r.used_vars == r.variables)   // oracle wire key mirrors the CLI's original name
    }

    // MARK: on-disk format — byte parity with the oracle's save_template OPERATION

    /// The bytes must match what MCP A's `save_template` writes, since both tools share the store.
    /// Note the trailing newline: the oracle normalizes the body (`server.py`), so asserting
    /// against `serialize_template` alone would lock bytes the oracle never actually produces.
    @Test func onDiskFormatMatchesOracle() throws {
        let store = tempStore()
        try store.save(name: "s1", body: "Hello world", subject: "Greetings")
        #expect(try rawFile(store, "s1") == "subject: Greetings\n\nHello world\n")
        try store.save(name: "s2", body: "Body only", subject: nil)
        #expect(try rawFile(store, "s2") == "\nBody only\n")
        // A body that already ends in a newline is not double-normalized.
        try store.save(name: "s3", body: "Ends already\n", subject: nil)
        #expect(try rawFile(store, "s3") == "\nEnds already\n")
    }

    /// The CLI must read files MCP A writes: body-only (leading blank line), lowercase `subject:`,
    /// a subject value containing a colon, and a body with INTERNAL blank lines + trailing newline
    /// (the properties the header/body slice could silently regress).
    @Test func parsesOracleWrittenFiles() {
        let (s1, b1) = TemplateStore.parse("\nJust the body")
        #expect(s1 == nil && b1 == "Just the body")
        let (s2, b2) = TemplateStore.parse("subject: Re: Q3\n\nDear {name},\nregards")
        #expect(s2 == "Re: Q3" && b2 == "Dear {name},\nregards")
        let (s3, b3) = TemplateStore.parse("subject: X\n\npara1\n\npara2\n")
        #expect(s3 == "X" && b3 == "para1\n\npara2\n")     // internal blanks + trailing newline kept
        let (s4, b4) = TemplateStore.parse("\nbody\n")
        #expect(s4 == nil && b4 == "body\n")
    }

    /// A multi-paragraph body must survive a full save→parse round-trip — the parser keys on the
    /// FIRST blank line, and a real email template is multi-paragraph.
    @Test func multiParagraphBodyRoundTrips() throws {
        let store = tempStore()
        let body = "Para 1 line 1\nPara 1 line 2\n\nPara 2\n\nPara 3\n"
        try store.save(name: "multi", body: body, subject: "Subj")
        let got = try store.get("multi")
        #expect(got.subject == "Subj")
        #expect(got.body == body)
    }

    @Test func bodyOnlyRoundTrips() throws {
        let store = tempStore()
        try store.save(name: "bo", body: "Line 1\nLine 2", subject: nil)
        let got = try store.get("bo")
        #expect(got.subject == nil)
        #expect(got.body == "Line 1\nLine 2\n")
    }

    // MARK: parse leniency must never LOSE content

    /// A file with no valid header block is read as ALL BODY. Losing the leading lines here would
    /// silently drop content into outgoing mail, so the fallback is non-lossy by construction.
    @Test func invalidHeaderBlockFallsBackToAllBodyWithoutLoss() {
        // No blank line at all (the oracle rejects this file outright).
        let (s0, b0) = TemplateStore.parse("Just a body\nno header")
        #expect(s0 == nil && b0 == "Just a body\nno header")
        // First line is prose, not a header — must NOT lose "Para 1".
        let (s1, b1) = TemplateStore.parse("Para 1\n\nPara 2")
        #expect(s1 == nil && b1 == "Para 1\n\nPara 2")
        // First line merely CONTAINS a colon — must NOT lose it.
        let (s2, b2) = TemplateStore.parse("Note: read this\n\nrest of body")
        #expect(s2 == nil && b2 == "Note: read this\n\nrest of body")
        // Unknown header key → not a header block; parsed-and-discarded would drop semantics.
        let (s3, b3) = TemplateStore.parse("from: a@b\n\nHello\n")
        #expect(s3 == nil && b3 == "from: a@b\n\nHello\n")
    }

    /// CRLF files are hand-editable reality; the oracle handles CR deliberately, so we must too —
    /// and its body keeps the original CRLF bytes (only header lines are \r-stripped).
    @Test func crlfInputParsesLikeTheOracle() {
        let (s, b) = TemplateStore.parse("subject: S\r\n\r\nHello\r\n")
        #expect(s == "S")               // no stray \r on the subject
        #expect(b == "Hello\r\n")       // body preserved byte-for-byte, not discarded or rewritten
    }

    /// A CRLF-terminated body must NOT gain a second newline. `hasSuffix("\n")` is grapheme-based
    /// and "\r\n" is ONE cluster, so the byte test is load-bearing here.
    @Test func crlfBodyIsNotDoubleNewlined() throws {
        let store = tempStore()
        try store.save(name: "crlf", body: "Hello\r\n", subject: nil)
        #expect(try rawFile(store, "crlf") == "\nHello\r\n")
        #expect(try store.get("crlf").body == "Hello\r\n")
    }

    @Test func emptyAndDegenerateInputDoNotCrash() {
        let (s0, b0) = TemplateStore.parse("")
        #expect(s0 == nil && b0 == "")
        let (s1, b1) = TemplateStore.parse("\n")
        #expect(s1 == nil && b1 == "")
    }

    /// `nil` vs `""` is the real subject distinction (the oracle branches on `is not None`).
    @Test func emptySubjectRoundTripsAsEmptyNotNil() throws {
        let store = tempStore()
        try store.save(name: "es", body: "Body", subject: "")
        #expect(try rawFile(store, "es") == "subject: \n\nBody\n")
        #expect(try store.get("es").subject == "")
        let (s, _) = TemplateStore.parse("subject: \n\nHello\n")
        #expect(s == "")
    }

    /// Last-wins on duplicate headers, matching the oracle's dict semantics.
    @Test func duplicateSubjectHeaderLastWins() {
        let (s, b) = TemplateStore.parse("subject: first\nsubject: second\n\nBody\n")
        #expect(s == "second" && b == "Body\n")
    }

    // MARK: save-side validation (mirrors the oracle's save_template)

    /// Writing a file the oracle can never read back would poison the SHARED store, so the
    /// invariant is: `parse(save(s, b)) == (s, b)`, or `save` throws.
    @Test func saveRefusesInputsTheOracleWouldReject() {
        let store = tempStore()
        // Empty / whitespace-only body → oracle raises validation_error.
        #expect(throws: Error.self) { try store.save(name: "x", body: "", subject: "S") }
        #expect(throws: Error.self) { try store.save(name: "x", body: "   \n ", subject: "S") }
        // A newline in the subject would smuggle an extra header line into the file.
        #expect(throws: Error.self) { try store.save(name: "x", body: "B", subject: "A\nbcc: evil@x.io") }
        #expect(throws: Error.self) { try store.save(name: "x", body: "B", subject: "A\rB") }
    }

    /// `save` must report what was STORED, not the caller's raw input.
    @Test func saveReportsStoredValuesAndCreatedFlag() throws {
        let store = tempStore()
        let first = try store.save(name: "rep", body: "Body", subject: "  Padded  ")
        #expect(first.created == true)
        #expect(first.subject == "Padded")            // as stored (trimmed), not the raw input
        #expect(first.body == "Body\n")               // as stored (normalized)
        let second = try store.save(name: "rep", body: "Body", subject: "Padded")
        #expect(second.created == false)              // overwrite, not create
    }

    // MARK: placeholders (oracle get_template field) + deterministic fill

    @Test func placeholdersMatchOracleExtraction() throws {
        // Sorted, deduped, across subject + body; `{{escaped}}` yields no match.
        #expect(TemplateStore.placeholders(subject: "Re: {original_subject}",
                                           body: "Hi {name}, {name} — {{not_a_token}} {today}")
                == ["name", "original_subject", "today"])
        #expect(TemplateStore.placeholders(subject: nil, body: "no tokens here").isEmpty)
        // Not valid identifiers → not placeholders (oracle regex is [a-zA-Z_][a-zA-Z0-9_]*).
        #expect(TemplateStore.placeholders(subject: nil, body: "{1bad} {with space} {}").isEmpty)
        // Order of operations matters: the oracle STRIPS `{{`/`}}` before scanning, so `{token}}`
        // collapses to `{token` and yields NOTHING. Skipping escapes mid-scan would wrongly find it.
        #expect(TemplateStore.placeholders(subject: nil, body: "{token}}").isEmpty)
        let store = tempStore()
        try store.save(name: "ph", body: "Hi {name}", subject: "Re: {topic}")
        #expect(try store.get("ph").placeholders == ["name", "topic"])
    }

    /// A substituted VALUE must never be re-scanned — otherwise the render depends on dictionary
    /// iteration order and differs run-to-run for attacker-influenced input.
    @Test func fillIsSinglePassAndDeterministic() {
        // `original_subject`'s value is itself a token; a re-scanning fill would sometimes expand it.
        let vars = ["original_subject": "{recipient_email}", "recipient_email": "me@example.com"]
        for _ in 0..<50 {
            var miss = Set<String>()
            #expect(TemplateStore.fill("Re: {original_subject}", vars: vars, missing: &miss) == "Re: {recipient_email}")
            // The re-emitted `{recipient_email}` is a VALUE, not a placeholder that was scanned —
            // so it must NOT be reported missing (it was never a token in the template text).
            #expect(miss.isEmpty)
        }
        // `{{`/`}}` are literal braces (Python str.format semantics), not a corrupted third thing.
        var m1 = Set<String>()
        #expect(TemplateStore.fill("{{name}} literal", vars: ["name": "X"], missing: &m1) == "{name} literal")
        #expect(m1.isEmpty)   // an escaped brace pair is not a placeholder
        // An unknown token is left verbatim in the string but IS reported, so `render` can raise
        // oracle A's `missing_template_variable` instead of shipping `{unknown}` in real mail.
        var m2 = Set<String>()
        #expect(TemplateStore.fill("Hi {unknown}", vars: [:], missing: &m2) == "Hi {unknown}")
        #expect(m2 == ["unknown"])
        // A lone brace passes through untouched and is not a placeholder.
        var m3 = Set<String>()
        #expect(TemplateStore.fill("100% { of it", vars: [:], missing: &m3) == "100% { of it")
        #expect(m3.isEmpty)
    }

    /// Oracle A's `_substitute` collects EVERY unresolved placeholder and raises with them
    /// sorted; the CLI must do the same rather than shipping a literal `{token}` in outbound mail.
    @Test func renderRaisesMissingTemplateVariableNamingAllUnresolvedSorted() throws {
        let store = tempStore()
        _ = try store.save(name: "greet", body: "Hi {zeta}, re {alpha} and {alpha}.", subject: "{mid}")
        do {
            _ = try store.render(name: "greet", autoVars: [:], userVars: [:])
            Issue.record("render should have thrown on unresolved placeholders")
        } catch let e as AppleError {
            #expect(e.type == "missing_template_variable")
            // Sorted, de-duplicated, and spanning BOTH subject and body.
            #expect(e.message.contains("alpha, mid, zeta"))
        }
        // Fully-supplied vars render clean.
        let ok = try store.render(name: "greet", autoVars: ["mid": "M"],
                                  userVars: ["zeta": "Z", "alpha": "A"])
        #expect(ok.body == "Hi Z, re A and A.\n")   // save normalizes the body to end with \n
        #expect(ok.subject == "M")
    }

    /// `today` must be the LOCAL calendar date (Python `date.today()`), not UTC — a UTC `today`
    /// substitutes TOMORROW's date for any render made in the local-evening offset window.
    @Test func todayIsTheLocalCalendarDate() {
        // 2026-03-01T04:30Z is still 2026-02-28 in America/New_York (UTC-5).
        let instant = Date(timeIntervalSince1970: 1772339400)   // 2026-03-01T04:30:00Z
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(TemplateStore.todayString(now: instant, calendar: cal) == "2026-02-28")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(TemplateStore.todayString(now: instant, calendar: utc) == "2026-03-01")
    }

    // MARK: names

    @Test func nameValidation() {
        #expect(throws: Error.self) { try TemplateStore.validateName("has spaces") }
        #expect(throws: Error.self) { try TemplateStore.validateName("") }
        #expect(throws: Error.self) { try TemplateStore.validateName(String(repeating: "a", count: 65)) }
        #expect(throws: Never.self) { try TemplateStore.validateName("ok_name-1") }
        // ASCII-only, matching the oracle — a Unicode name would be unreachable by MCP A.
        #expect(throws: Error.self) { try TemplateStore.validateName("café") }
        #expect(throws: Error.self) { try TemplateStore.validateName("日本語") }
        // Traversal payloads stay rejected.
        #expect(throws: Error.self) { try TemplateStore.validateName("../../.ssh/authorized_keys") }
        #expect(throws: Error.self) { try TemplateStore.validateName("..") }
    }

    /// `list()` must only advertise names the other verbs can actually address.
    @Test func listSkipsNamesGetWouldReject() throws {
        let store = tempStore()
        try store.save(name: "good", body: "B", subject: nil)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try "\nB\n".write(to: store.root.appendingPathComponent("bad name.md"), atomically: true, encoding: .utf8)
        let names = try store.list().map(\.name)
        #expect(names == ["good"])
    }

    @Test func getMissingThrowsNotFound() {
        let store = tempStore()
        #expect(throws: Error.self) { _ = try store.get("nope") }
    }

    /// `validateSave` is the PURE half `save` runs and the `--dry-run` path now runs too, so a
    /// preview cannot name a save `--execute` would refuse (write-model v2 preview honesty;
    /// review-caught after the willExecute branch landed). Pinning it here keeps the two paths
    /// provably on the same rules.
    @Test("validateSave enforces every save rule without touching the filesystem")
    func validateSaveIsThePureSharedCheck() throws {
        try TemplateStore.validateSave(name: "good-name_1", body: "hi", subject: "S")
        try TemplateStore.validateSave(name: "n", body: "hi", subject: nil)
        for bad in ["../evil", "has space", "", String(repeating: "a", count: 65), "unicodé"] {
            #expect(throws: AppleError.self) {
                try TemplateStore.validateSave(name: bad, body: "hi", subject: nil)
            }
        }
        #expect(throws: AppleError.self) { try TemplateStore.validateSave(name: "n", body: "   ", subject: nil) }
        #expect(throws: AppleError.self) { try TemplateStore.validateSave(name: "n", body: "b", subject: "a\nb") }
    }
}
